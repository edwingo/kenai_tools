require 'rubygems'
require 'bundler/setup'

require 'forwardable'
require 'rest_client'
require 'mechanize'
require 'logger'

module KenaiTools
  class DomainAdminClient
    BEGIN_DATA = :begin_data
    MAX_TRIES = 3
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
      $stdout.sync = true
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

    def filter_empty_and_created_before(created_before, filepath)
      created_before = parse_iso_date(created_before)
      comment = "filter_empty_and_created_before #{created_before} #{filepath}"
      filter_lists(filepath, comment) { |l| l[:empty] && l[:created_at] && parse_iso_date(l[:created_at]) < created_before }
    end

    def filter_archive_last_updated_before(updated_before, filepath)
      updated_before = parse_iso_date(updated_before)
      comment = "filter_archive_last_updated_before #{updated_before} #{filepath}"
      filter_lists(filepath, comment) { |l| l[:archive_updated] && parse_iso_date(l[:archive_updated]) < updated_before }
    end

    def filter_missing_from_mlm(filepath)
      comment = "filter_missing_from_mlm #{filepath}"
      filter_lists(filepath, comment) { |l| l[:missing_from_mlm] }
    end

    def filter_not_named(name, filepath)
      comment = "filter_not_named #{name} #{filepath}"
      filter_lists(filepath, comment) { |l| l[:name] != "#{name}" }
    end

    def filter_out_issues(filepath)
      comment = "filter_out_issues #{filepath}"
      filter_projects(filepath, comment) do |pr, lists|
        out = pr.clone
        out[:lists] = lists.reject { |l| l[:name] == 'issues' } unless pr[:issues].empty?
        out
      end
    end

    # Use this filter to create a missing 'issues' list for projects with issue trackers
    def filter_in_issues(filepath)
      comment = "filter_in_issues #{filepath}"
      filter_projects(filepath, comment) do |pr, lists|
        out = pr.clone
        out[:lists] = if !pr[:issues].empty? and !lists.detect { |l| l[:name] == 'issues' }
                        [{:name => 'issues'}]
                      else
                        []
                      end
        out
      end
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

    def process_command_header(in_file, comment)
      input = read_input(in_file)
      output = []
      parse_command_header(input, output)
      emit_yaml(output)

      filter_header = [{:comment => comment}]
      emit_yaml(filter_header)
      input
    end

    def filter_projects(in_file, comment)
      input = process_command_header(in_file, comment)

      projects = parse_project_data(input)
      results = [begin_data]
      projects.each do |proj|
        out_proj = yield proj, proj[:lists]
        unless out_proj[:lists].empty?
          results << project_data(out_proj[:project], out_proj[:parent], out_proj[:lists], out_proj[:issues], out_proj[:has_scm])
        end
      end
      emit_yaml(results)
    end

    def filter_lists(in_file, comment, &block)
      input = process_command_header(in_file, comment)

      projects = parse_project_data(input)
      results = [begin_data]
      projects.each do |proj|
        lists = proj[:lists]
        filtered = lists.select &block
        results << project_data(proj[:project], proj[:parent], filtered, proj[:issues], proj[:has_scm]) unless filtered.empty?
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
          raise ArgumentError, "Bad command header yaml syntax: missing hash array element with key '#{BEGIN_DATA.inspect}'"
        end

        args = input.slice!(0)
        unless args && Hash === args
          raise ArgumentError, "Bad command header yaml syntax: expected hash array element but got: #{args.inspect}"
        end

        if args.has_key?(:comment)
          # No-op
        elsif args.has_key?(BEGIN_DATA)
          return command, command_args
        elsif args.has_key?(:command)
          command, command_args = args.delete(:command), args
        else
          raise ArgumentError, "Bad command header yaml syntax: unexpected hash array element: #{args.inspect}"
        end
        output << args
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
            if !list_name
              next
            elsif feature = features.detect { |f| f['name'] == list_name }
              puts "Feature with name='#{list_name}', service='#{feature['service']}' already exists for project='#{proj_name}'. Skipping."
            elsif !create_list(proj_name, list_name, MAX_TRIES)
              puts "Failed to create mailing list with name='#{list_name}' for project='#{proj_name}' after #{MAX_TRIES} attempts."
            end
          end
        else
          puts "Project '#{proj_name}' is not found. Skipping."
        end
      end
    end

    def create_list(proj_name, list_name, tries_remaining = 1)
      return false if tries_remaining < 1

      print "Creating list for project='#{proj_name}' list='#{list_name}' tries_remaining=#{tries_remaining}... "
      if dry_run
        print "done"
        return true
      end

      json = {:feature => {
        :name => "#{list_name}",
        :service => "lists",
        :display_name => "#{list_name.capitalize} Mailing List"}
      }.to_json
      begin
        response = @kc.create_project_feature(proj_name, json)
      rescue RestClient::Exception => ex
        puts "failed, caught exception http_code=#{ex.http_code}, message=#{ex.message}"
        return create_list(proj_name, list_name, tries_remaining - 1)
      end

      if response.code == 201 # Created
        print "created_201, verifying MLM archive... "
        if feature = @kc.project_feature(proj_name, list_name)
          if list_archive_info(feature) == :missing_from_mlm
            puts "missing from MLM, cleaning up before retrying..."
            delete_list(proj_name, list_name)
            return create_list(proj_name, list_name, tries_remaining - 1)
          else
            puts "done"
            return true
          end
        else
          puts "failed, API returned 201 but mailing list feature does not exist, aborting!"
          return false
        end
      else
        puts "failed, API returned code=#{response.code}, aborting!"
        return false
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
      @kc.delete_project_feature(project, list) unless dry_run
      puts "done"
    end

    def project_data(name, parent, lists, issues, has_scm)
      [{:project => name}, {:parent => parent}, {:lists => lists}, {:issues => issues}, {:has_scm => has_scm}]
    end

    def projects_lists_on_page(page, per_page = nil)
      result = []
      params = {:filter => 'domain_admin', :full => true, :page => page}
      params.merge!(:size => per_page) if per_page
      projects = @kc.projects(params)
      return nil if projects.empty?
      projects.each do |proj|
        out_lists = []
        out_issues = []
        has_scm = false
        proj['features'].each do |f|
          out_hash = {:name => f['name'], :created_at => f['created_at']}
          case f['type']
          when 'lists'
            case info = list_archive_info(f)
            when Date
              out_hash[:archive_updated] = info.to_s
            when :missing_from_mlm
              out_hash[:missing_from_mlm] = true
            when :empty
              out_hash[:empty] = true
            end
            out_lists << out_hash
          when 'issues'
            out_issues << out_hash
          when 'scm'
            has_scm = true
          end
        end
        result << project_data(proj['name'], proj['parent'], out_lists, out_issues, has_scm) unless out_lists.empty?
      end
      result
    end

    def projects_lists(start, length = nil, per_page = nil)
      emit_yaml [begin_data]
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

    def begin_data
      {BEGIN_DATA => nil}
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
      emit_yaml header
    end

    def emit_yaml(val)
      puts val.to_yaml
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
