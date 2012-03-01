require 'rubygems'
require 'bundler/setup'

require 'forwardable'
require 'rest_client'
require 'mechanize'
require 'logger'

module KenaiTools
  class DomainAdminClient
    SEPARATOR = :separator
    CREATE_LISTS = 'domain_admin_create_lists'
    DELETE_LISTS = 'domain_admin_delete_lists'

    extend Forwardable
    def_delegators :@kc, :authenticate, :authenticated?

    attr_accessor :dry_run, :log, :site

    def initialize(site, opts = {})
      @site = site
      @dry_run = opts.delete(:dry_run)
      @insecure = opts.delete(:insecure)
      RestClient.log = opts[:log]
      @kc = KenaiClient.new(site, opts)

      @user, @password = opts[:user], opts[:password]
      @agent = Mechanize.new
      @agent.log = logger(opts[:log])
      if @cloak_password = opts.delete(:cloak_password)
        @agent.auth("", @cloak_password)
      end
    end

    def ping
      @kc[].get
    end

    def find_lists(start = 1, length = nil, per_page = nil)
      comments = ["Remote site: #{site}", "find_lists #{start} #{length} #{per_page}".strip]
      start, length, per_page = parse_find_args(start, length, per_page)
      emit_command_header(comments)
      projects_lists(start, length, per_page)
    end

    def filter_empty_and_created_before(filepath, created_before)
      created_before = parse_iso_date(created_before)
      comment = "filter_empty_and_created_before #{filepath} #{created_before}"
      filter(filepath, comment) { |l| l[:empty] && l[:created_at] && parse_iso_date(l[:created_at]) < created_before }
    end

    def filter_archive_last_updated_before(filepath, updated_before)
      updated_before = parse_iso_date(updated_before)
      comment = "filter_archive_last_updated_before #{filepath} #{updated_before}"
      filter(filepath, comment) { |l| l[:archive_updated] && parse_iso_date(l[:archive_updated]) < updated_before }
    end

    def filter_missing_from_mlm(filepath)
      comment = "filter_missing_from_mlm #{filepath}"
      filter(filepath, comment) { |l| l[:missing_from_mlm] }
    end

    def execute(filepath, force = false)
      puts "Dry_run: no destructive operations will be executed..." if dry_run
      input = read_input(filepath)
      command, @opts = parse_command_header(input, [])
      projects = parse_project_data(input)
      case command
      when DELETE_LISTS
        delete_lists(projects)
      when CREATE_LISTS
        create_lists(projects)
      when nil
        $stderr.puts "No command found in: #{filepath}"
      else
        puts "Command is not valid: #{command.inspect}"
      end
    end

    private

    def filter(in_file, comment, &block)
      input = read_input(in_file)
      output = []
      parse_command_header(input, output)
      emit_yaml(output)

      filter_header = [{:comment => comment}]
      emit_yaml(filter_header)

      projects = parse_project_data(input)
      results = []
      projects.each do |proj|
        lists = proj[:lists]
        filtered = lists.select &block
        results << project_data(proj[:project], proj[:parent], filtered) unless filtered.empty?
      end
      emit_yaml(results)
    end

    def read_input(filepath)
      result = []
      File.open(filepath) do |yf|
        YAML.load_documents(yf) do |ydoc|
          result += ydoc
        end
      end
      result
    end

    def parse_command_header(input, output)
      command, command_args = nil
      loop do
        if input.empty?
          raise ArgumentError, "Bad command header yaml syntax: expected hash array element with key '#{SEPARATOR.inspect}'"
        end

        args = input.slice!(0)
        output << args

        unless args && Hash === args
          raise ArgumentError, "Bad command header yaml syntax: expected hash array element but got: #{args.inspect}"
        end

        if args.has_key?(:comment)
          next
        elsif args.has_key?(SEPARATOR)
          return command, command_args
        elsif args.has_key?(:command)
          command, command_args = args.delete(:command), args
        else
          raise ArgumentError, "Bad command header yaml syntax: unexpected hash array element: #{args.inspect}"
        end
      end
    end

    def parse_project_data(input)
      all = []
      input.each do |item|
        next if Hash === item && item.has_key?(:comment)

        if Array === item
          # Assume that +item+ corresponds to a project array of hashes to be merged
          all << item.inject { |h, e| h.merge!(e) }
        else
          raise ArgumentError, "Bad yaml input reading project data: unexpected object of type #{item.class}: #{item.inspect}"
        end
      end
      all
    end

    def create_lists(projects)
      projects.each do |proj|
        proj_name = proj[:project]
        if features = @kc.project_features(proj_name)
          proj[:lists].each do |list|
            list_name = list[:name]
            if ! list_name
              next
            elsif feature = features.detect { |f| f['name'] == list_name}
              puts "Feature with name='#{list_name}', service='#{feature['service']}' already exists for project='#{proj_name}'. Skipping."
            else
              create_list(proj_name, list_name)
            end
          end
        else
          puts "Project '#{proj_name}' is not found. Skipping."
        end
      end
    end

    def create_list(project, list)
      print "Creating list for project='#{project}' list='#{list}'... "
      json = {:feature => {
        :name => "#{list}",
        :service => "lists",
        :display_name => "#{list.capitalize}",
        :description => "#{list.capitalize}"}
      }.to_json
      unless dry_run
        response = @kc["projects/#{project}/features"].post(json, :content_type => :json, :accept => :json)
        puts response.code == 201 ? "done" : "failed"
      else
        puts "done"
      end
    end

    def delete_lists(projects)
      projects.each do |proj|
        proj_name = proj[:project]
        if features = @kc.project_features(proj_name)
          proj[:lists].each do |list|
            list_name = list[:name]
            if list_feature = features.detect { |f| f['type'] = 'lists' && f['name'] == list_name}
              unless @opts[:force]
                info = list_archive_info(list_feature)
                if [:empty, :missing_from_mlm].include?(info)
                  delete_list(proj_name, list_name)
                else
                  puts "List info for project='#{proj_name}' list='#{list_name}' is unexpected, got '#{info}'. Skipping."
                end
              else
                delete_list(proj_name, list_name)
              end
            else
              puts "List for project='#{proj_name}' list='#{list_name}' does not exist. Ignoring."
            end
          end
        else
          puts "Project '#{proj_name}' is not found. Skipping."
        end
      end
    end

    def ensure_webui_login
      unless @logged_in
        @agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @insecure
        login_uri = "#{@site}/people/login"
        @agent.get(login_uri) do |page|
          resp = page.form_with :action => login_uri, :method => "POST" do |form|
            form['authenticator[username]'] = @user
            form['authenticator[password]'] = @password
          end.click_button
          unless resp.uri.to_s =~ /\/mypage$/
            raise StandardError, "Unable to login to '#{@site}' as '#{@user}'"
          end
        end
        @logged_in = true
      end
    end

    def list_archive_url(list_feature, convert_to_http = true)
      archive_url = list_feature['web_url']
      archive_url.sub!(/^https:/, 'http:') if convert_to_http # Hack to eliminate redirect
    end

    def last_message_date(p1)
      p2 = @agent.click(p1.link_with(:text => 'Chronological'))
      ns = p2.search('div.listsArchive table.dataDisplay tr')
      str = ns[-1].search('td[3]').first.content
      Date.strptime(str, "%m/%d/%Y")
    end

    def list_archive_info(list_feature)
      archive_url = list_archive_url(list_feature)
      list_name = list_feature['name']
      ensure_webui_login
      begin
        @agent.get(archive_url) do |page|
          flash = page.search("div.flash").first
          if flash && flash.content =~ /The mailing list #{list_name}@.* does not have any messages/
            return :empty
          else
            return last_message_date(page)
          end
        end
      rescue Mechanize::ResponseCodeError => ex
        if ex.response_code == "404"
          # 2012-02-23 Assume list is missing from sympa MLM
          # Code is dependent on current junction implementation that essentially forwards the 404 response
          # from sympa to the client.
          return :missing_from_mlm
        else
          raise ex
        end
      end
    end

    def delete_list(project, list)
      print "Deleting list for project='#{project}' list='#{list}'... "
      @kc["projects/#{project}/features/#{list}"].delete unless dry_run
      puts "done"
    end

    def project_data(name, parent, lists)
      [{:project => name}, {:parent => parent}, {:lists => lists}]
    end

    def projects_lists_on_page(page, per_page = nil)
      result = []
      params = {:filter => 'domain_admin', :full => true, :page => page}
      params.merge!(:size => per_page) if per_page
      projects = @kc.projects(params)
      return nil if projects.empty?
      projects.each do |proj|
        lists_out = []
        list_features = proj['features'].select { |f| f['type'] == 'lists' }
        list_features.each do |l|
          list = {:name => l['name'], :created_at => l['created_at'], :updated_at => l['updated_at']}
          case info = list_archive_info(l)
          when Date
            list[:archive_updated] = info.to_s
          when :missing_from_mlm
            list[:missing_from_mlm] = true
          when :empty
            list[:empty] = true
          end
          lists_out << list
        end

        result << project_data(proj['name'], proj['parent'], lists_out) unless lists_out.empty?
      end
      result
    end

    def projects_lists(start, length = nil, per_page = nil)
      limit = length ? start + length : nil

      page = start
      loop do
        result = projects_lists_on_page(page, per_page)
        break unless result
        result.insert(0, {:comment => "Begin page=#{page.inspect}"})
        emit_yaml(result)
        page += 1
        break if limit && page >= limit
      end
    end

    def separator
      {SEPARATOR => nil}
    end

    def emit_command_header(comments)
      header = [
        {:comment => "This file is machine generated and is designed to be manually"},
        {:comment => "edited. The format is a series of YAML documents with array"},
        {:comment => "objects at the root of each document."},
        {:comment => "Change the ':comment' prefix to ':command' on a following"},
        {:comment => "line to execute the command via 'domadmin exec'."},
        {:comment => "#{DELETE_LISTS}"},
        {:comment => "#{CREATE_LISTS}"},
        {:comment => nil},
      ]
      header += comments.map { |str| {:comment => str}}
      header << separator
      emit_yaml header
    end

    def emit_yaml(val)
      puts val.to_yaml
      $stdout.flush
    end

    def to_int(val)
      val ? val.to_i : nil
    end

    def parse_find_args(start, length, per_page)
      return to_int(start), to_int(length), to_int(per_page)
    end

    def parse_iso_date(str)
      date_only = if has_time = str =~ /T/
                    str[0...has_time]
                  else
                    str
                  end
      Date.strptime(date_only, "%Y-%m-%d")
    end

    def logger(io)
      unless @log
        logger = Logger.new(io)
        logger.level = Logger::INFO
        @log = logger
      end
    end
  end
end
