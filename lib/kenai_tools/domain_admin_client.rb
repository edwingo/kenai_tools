require 'rubygems'
require 'bundler/setup'

require 'forwardable'
require 'rest_client'
require 'mechanize'
require 'logger'

module KenaiTools
  # Path arguments to public methods of this API work with Pathname objects as well as Strings
  class DomainAdminClient
    CREATE_LISTS = 'domain_admin_create_lists'
    DELETE_LISTS = 'domain_admin_delete_lists'

    extend Forwardable
    def_delegators :@kc, :authenticate, :authenticated?

    attr_accessor :dry_run, :log

    def initialize(site, opts = {})
      @site = site
      @dry_run = opts.delete(:dry_run)
      @insecure = opts.delete(:insecure)
      RestClient.log = opts[:log]
      @kc = KenaiClient.new(site, opts)

      @user, @password = opts[:user], opts[:password]
      @agent = Mechanize.new
      @agent.log = logger(opts[:log])
    end

    def ping
      @kc[].get
    end

    def find_missing_lists(start = 1, length = nil, per_page = nil)
      start, length, per_page = parse_find_args(start, length, per_page)
      emit_header(start, length, per_page)
      projects_lists(start, length, per_page) { |proj_name, list_feature| list_archive_missing?(list_feature) }
    end

    def find_empty_lists(start = 1, length = nil, per_page = nil)
      start, length, per_page = parse_find_args(start, length, per_page)
      emit_header(start, length, per_page)
      projects_lists(start, length, per_page) { |proj_name, list_feature| list_archive_empty?(proj_name, list_feature) }
    end

    def execute(filepath, force = false)
      puts "Dry_run: no destructive operations will be executed..." if dry_run
      input = read_input(filepath)
      command, @opts = parse_command(input)
      data = parse_data(input)
      case command
      when DELETE_LISTS
        delete_lists(data)
      when CREATE_LISTS
        create_lists(data)
      else
        puts "Command '#{command}' is not valid"
      end
    end

    private

    def read_input(filepath)
      result = []
      File.open(filepath) do |yf|
        YAML.each_document(yf) do |ydoc|
          result += ydoc
        end
      end
      result
    end

    def parse_command(input)
      command = nil
      loop do
        args = input.slice!(0)
        unless args && Hash === args
          raise ArgumentError, "Bad yaml input: expected hash array element but got: #{args.inspect}"
        end
        next if args.has_key?(:comment)

        unless command = args.delete(:command)
          raise ArgumentError, "Bad yaml input: expected hash array element with key ':command' but got: #{args.inspect}"
        else
          return [command, args]
        end
      end
    end

    def parse_data(input)
      all_features = []
      input.each do |item|
        next if Hash === item && item.has_key?(:comment)

        if Array === item
          merged = {}
          item.map { |e| merged.merge!(e) }
          all_features << merged
        else
          raise ArgumentError, "Bad yaml input reading project data: unexpected object of type #{item.class}: #{item.inspect}"
        end
      end
      all_features
    end

    def create_lists(data)
      data.each do |item|
        project = item[:project]
        if features = @kc.project_features(project)
          item[:lists].each do |list_name|
            if feature = features.detect { |f| f['name'] == list_name}
              puts "Feature with name='#{list_name}', service='#{feature['service']}' already exists for project='#{project}'. Skipping."
            else
              create_list(project, list_name)
            end
          end
        else
          puts "Project '#{project}' is not found. Skipping."
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

    def delete_lists(data)
      data.each do |item|
        project = item[:project]
        if features = @kc.project_features(project)
          item[:lists].each do |list_name|
            if list_feature = features.detect { |f| f['type'] = 'lists' && f['name'] == list_name}
              unless @opts[:force]
                if list_archive_empty?(project, list_feature)
                  delete_list(project, list_name)
                else
                  puts "List for project='#{project}' list='#{list_name}' is not empty. Skipping."
                end
              else
                delete_list(project, list_name)
              end
            else
              puts "List for project='#{project}' list='#{list_name}' does not exist. Ignoring."
            end
          end
        else
          puts "Project '#{project}' is not found. Skipping."
        end
      end
    end

    def ensure_webui_login
      unless @logged_in
        @agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @insecure
        login_uri = "#{@site}/people/login"
        @agent.get(login_uri) do |page|
          resp = page.form_with :action => login_uri do |form|
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

    def list_archive_missing?(list_feature)
      archive_url = list_archive_url(list_feature)
      ensure_webui_login
      begin
        @agent.head(archive_url)
      rescue Mechanize::ResponseCodeError => ex
        return true if ex.response_code == "404"
      end
      false
    end

    def list_archive_empty?(project, list_feature)
      archive_url = list_archive_url(list_feature)
      list_name = list_feature['name']
      ensure_webui_login
      begin
        flash = @agent.get(archive_url).search("div.flash").first
        flash && flash.content =~ /The mailing list #{list_name}@.* does not have any messages/
      rescue Mechanize::ResponseCodeError => ex
        if ex.response_code == "404"
          puts "Warning: list for project='#{project}' list='#{list_name}' is missing from list service, assuming not empty."
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

    def projects_lists_on_page(page, per_page = nil)
      result = []
      params = {:filter => 'domain_admin', :full => true, :page => page}
      params.merge!(:size => per_page) if per_page
      projects = @kc.projects(params)
      return nil if projects.empty?
      projects.each do |proj|
        list_features = proj['features'].select { |f| f['type'] == 'lists' }
        list_names = list_features.select { |l| yield proj['name'], l }.map { |l| l['name'] }
        result << [{:project => proj['name']}, {:parent => proj['parent']}, {:lists => list_names}] unless list_names.empty?
      end
      result
    end

    def projects_lists(start, length = nil, per_page = nil, &filter)
      limit = length ? start + length : nil

      page = start
      loop do
        result = projects_lists_on_page(page, per_page, &filter)
        break unless result
        result.insert(0, {:comment => "Begin page=#{page.inspect}"})
        emit_yaml(result)
        page += 1
        break if limit && page >= limit
      end
    end

    def emit_header(start, length, per_page)
      cmd1 = {:command => "#{DELETE_LISTS}"}.to_yaml[/:command.*/]
      cmd2 = {:command => "#{CREATE_LISTS}"}.to_yaml[/:command.*/]
      header = [{:comment => "This file is machine generated but can be manually edited."},
        {:comment => "Remove quotes and delete prefix up to ':command' on a line to execute."},
        "# #{cmd1}",
        "# #{cmd2}",
        {:comment => nil},
        {:comment => "Find arguments: start=#{start.inspect}, length=#{length.inspect}, per_page=#{per_page.inspect}"},
      ]
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

    def logger(io)
      unless @log
        logger = Logger.new(io)
        logger.level = Logger::INFO
        @log = logger
      end
    end
  end
end
