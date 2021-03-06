require 'rubygems'

require 'rest_client'
require 'json'
require 'net/http/post/multipart'

module KenaiTools
  class KenaiClient
    DEFAULT_HOST = 'https://kenai.com/'

    RestClient.proxy = ENV['http_proxy'] if ENV['http_proxy']

    attr_reader :host, :user, :password

    def initialize(host = nil, opts = {})
      RestClient.log = opts[:log] if opts[:log]
      @host = host || DEFAULT_HOST
      @opts = opts
    end

    # check credentials using the login/authenticate method; if successful,
    # cache the credentials for future calls
    def authenticate(user, password)
      @user = user
      @password = password
      begin
        client = self['login/authenticate']
        client["?username=#{@user}&password=#{@password}"].get
        @auth = true
      rescue RestClient::Unauthorized, RestClient::RequestFailed
        @auth = false
        @user = @password = nil
      end

      return @auth
    end

    def authenticated?
      @auth
    end

    def project(proj_name)
      begin
        JSON.parse(self["projects/#{proj_name}"].get)
      rescue RestClient::ResourceNotFound
        nil
      end
    end

    def project_features(proj_name)
      begin
        fetch_all("projects/#{proj_name}/features", 'features')
      rescue RestClient::ResourceNotFound
        nil
      end
    end

    def project_feature(proj_name, feature_name)
      begin
        JSON.parse(project_feature_client(proj_name, feature_name).get)
      rescue RestClient::ResourceNotFound
        nil
      end
    end

    def create_project_feature(proj_name, feature_json)
      self["projects/#{proj_name}/features"].post(feature_json, :content_type => :json, :accept => :json)
    end

    def delete_project_feature(proj_name, feature_name)
      project_feature_client(proj_name, feature_name).delete
    end

    # collect all project hashes (scope may be :all, or all projects, or
    # :mine, for projects in which the current user has some role)
    def projects(params = {})
      fetch_all('projects', 'projects', params)
    end

    def my_projects
      fetch_all('projects/mine', 'projects')
    end

    # get wiki images for a project
    def wiki_images(project, on_page = nil)
      opts = {}
      opts[:page] = on_page if on_page
      fetch_all("projects/#{project}/features/wiki/images", 'images', opts)
    end

    # get the wiki raw image data for an image
    def wiki_image_data(image)
      RestClient.get(image['image_url'], :accept => image['image_content_type'])
    end

    # opts has the following keys
    # +:image_data+ = raw image data, required only if creating a new image
    # +:content_type+ = image_data content-type
    # +:filename+ = filename for multipart
    #
    # +:comments+ = optional comments for the image
    # throws IOError unless create or update was successful
    def create_or_update_wiki_image(proj_name, opts)
      req_params = {}
      if data = opts[:image_data]
        content_type = opts[:content_type]
        filename = opts[:filename]
        req_params["image[uploaded_data]"] = UploadIO.new(StringIO.new(data), content_type, filename)
      end
      if comments = opts[:comments]
        req_params["image[comments]"] = comments
      end
      return false if req_params.empty?

      self["projects/#{proj_name}/features/wiki/images/#{filename}"].put(req_params)
    end

    # get wiki pages for a project
    def wiki_pages(project, on_page = nil)
      opts = {}
      opts[:page] = on_page if on_page
      fetch_all("projects/#{project}/features/wiki/pages", 'pages', opts)
    end

    def wiki_page(proj_name, page_name)
      page = wiki_page_client(proj_name, page_name)
      JSON.parse(page.get)
    end

    # edit a single wiki page -- yields the current page contents, and
    # saves them back if the result of the block is different
    def edit_wiki_page(proj_name, page_name)
      # fetch current page contents
      page = wiki_page_client(proj_name, page_name)
      begin
        page_data = JSON.parse(page.get)
        current_src = page_data['text']
      rescue RestClient::ResourceNotFound
        page_data = {}
        current_src = ''
      end

      new_src = yield(current_src)

      changed = !(new_src.nil? || new_src == current_src)

      if changed
        new_data = {
          'page' => {
            'text' => new_src,
            'description' => 'edited with kenai-client',
            'number' => page_data['number']
          }
        }
        page.put(JSON.dump(new_data), :content_type => 'application/json')
      end

      return changed
    end

    def api_client(fragment='')
      params = {:headers => {:accept => 'application/json'}}
      if @auth
        params[:user] = @user
        params[:password] = @password
      end
      params.merge!(@opts)

      if fragment =~ %r{^https://}
        RestClient::Resource.new(fragment, params)
      else
        RestClient::Resource.new(@host, params)['api'][fragment]
      end
    end

    alias :[] :api_client

    private

    # +opts+ are translated to URL params (see API docs):
    # :page => on_page, means only on that particular page or all pages if nil
    # :filter => 'all', means to also include private projects
    def fetch_all(initial_url, item_key, opts = {})
      params = query_params(opts)
      url = initial_url + params

      unless opts[:page]
        next_page = url
        results = []

        loop do
          curr_page = JSON.parse(self[next_page].get)
          results += curr_page[item_key]
          break unless curr_page['next']
          next_page = curr_page['next'] + params
        end

        results
      else
        JSON.parse(self[url].get)[item_key]
      end
    end

    def query_params(opts)
      params = opts.map { |k, v| "#{k}=#{v}" }
      query = params.empty? ? "" : "?#{params.join('&')}"
      query
    end

    def wiki_page_client(project, page)
      self["projects/#{project}/features/wiki/pages/#{page}"]
    end

    def project_feature_client(proj_name, feature_name)
      self["projects/#{proj_name}/features/#{feature_name}"]
    end
  end
end
