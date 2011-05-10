require 'rubygems'
require "bundler/setup"

require 'rest_client'
require 'json'

module KenaiDlutil
  class KenaiClient
    DEFAULT_HOST = 'https://kenai.com/'

    RestClient.proxy = ENV['http_proxy'] if ENV['http_proxy']

    attr_reader :host, :user, :password

    def initialize(host = nil, opts = {})
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

    # collect all project hashes (scope may be :all, or all projects, or
    # :mine, for projects in which the current user has some role)
    def projects(scope=:all)
      fetch_all('projects', 'projects')
    end

    def my_projects
      fetch_all('projects/mine', 'projects')
    end

    # get wiki images for a project
    def wiki_images(project, on_page = nil)
      fetch_all("projects/#{project}/features/wiki/images", 'images', on_page)
    end

    # get the wiki raw image data for an image
    def wiki_image_data(image)
      RestClient.get(image['image_url'], :accept => image['image_content_type'])
    end

    # hash has the following keys
    # +:uploaded_data+ = raw image data, required only if creating a new image
    # +:comments+ = optional comments for the image
    # throws IOError unless create or update was successful
    def create_or_update_wiki_image(proj_name, image_filename, hash)
      req_params = {}
      if data = hash[:uploaded_data]
        upload_io = UploadIO.new(StringIO.new(data), "image/png", image_filename)
        req_params["image[uploaded_data]"] = upload_io
      end
      if comments = hash[:comments]
        req_params["image[comments]"] = comments
      end
      return false if req_params.empty?
    end

    # get wiki pages for a project
    def wiki_pages(project, on_page = nil)
      fetch_all("projects/#{project}/features/wiki/pages", 'pages', on_page)
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

    # +on_page+ means only on that particular page or all pages if nil
    def fetch_all(initial_url, item_key, on_page = nil)
      unless on_page
        next_page = initial_url
        results = []

        begin
          curr_page = JSON.parse(self[next_page].get)
          results += curr_page[item_key]
          next_page = curr_page['next']
        end until next_page.nil?

        results
      else
        url = on_page ? initial_url + "?page=#{on_page}" : initial_url
        JSON.parse(self[url].get)[item_key]
      end
    end

    def wiki_page_client(project, page)
      self["projects/#{project}/features/wiki/pages/#{page}"]
    end
  end
end
