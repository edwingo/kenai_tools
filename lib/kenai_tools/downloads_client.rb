require 'rubygems'
require 'bundler/setup'

require 'forwardable'
require 'rest_client'

module KenaiTools
  # Path arguments to public methods of this API work with Pathname objects as well as Strings
  class DownloadsClient
    CONTENT_TYPE_KENAI_ENTRIES = "application/vnd.com.kenai.entries+json"

    extend Forwardable
    def_delegators :@kc, :authenticate, :authenticated?

    attr_accessor :project, :cloak_password

    #
    # Local options are :downloads_name, :log, :cloak_password
    # Other options such as :timeout are forwarded
    # DownloadClient.new("https://kenai.com/", "jruby")
    # DownloadClient.new("https://testkenai.com/", "my-project", :downloads_name => 'downloads2', :log => $stderr
    #  :timeout => 36000, :cloak_password => 'a_secret')
    #
    def initialize(site, project, opts = {})
      @site = site
      @project = project
      @specified_downloads_name = opts.delete(:downloads_name)
      @cloak_password = opts.delete(:cloak_password)
      RestClient.log = opts.delete(:log)
      @kc = KenaiClient.new(site, opts)
    end

    def get_or_create
      unless ping
        @specified_downloads_name = "downloads" unless @specified_downloads_name
        params = {:feature => {:name => @specified_downloads_name, :service => "downloads",
          :display_name => @specified_downloads_name.capitalize}}
        @kc["projects/#{project}/features"].post(params, :content_type => 'application/json')
      end
      downloads_name
    end

    def delete_feature(confirm = nil)
      unless confirm == 'yes'
        fail "Confirm delete project downloads feature with an argument of 'yes'"
      else
        # Flush cache
        orig_downloads_name = downloads_name
        @downloads_feature = @downloads_name = nil
        @kc["projects/#{project}/features/#{orig_downloads_name}"].delete
      end
    end

    #
    # Returns the specified downloads feature if found, or a discovered one
    # if the project only has one
    #
    def downloads_feature
      @downloads_feature ||= begin
        project = @kc.project(@project)
        features = project && project['features']
        if downloads_features = features && features.select { |f| f['type'] == 'downloads' }
          if @specified_downloads_name
            downloads_features.detect { |f| f['name'] == @specified_downloads_name }
          elsif downloads_features.size == 1
            downloads_features.first
          else
            nil
          end
        else
          nil
        end
      end
    end

    def downloads_name
      @downloads_name ||= downloads_feature && downloads_feature['name']
    end

    alias_method :ping, :downloads_name

    def ls(path = '/')
      entry(path)
    end

    def exist?(path = '/')
      !!entry(path)
    end

    def entry_type(path)
      if h = entry(path)
        h['entry_type']
      end
    end

    #
    # Pull a remote file or directory hierarchy to the local host. Use
    # +remote_path+ to specify the remote file or directory hierarchy to
    # download. If +remote_path+ is '/', download all content. Use
    # +local_dest_dir+ to specify the target location for the content which
    # defaults to the current directory.
    #
    # For example:
    #   dlclient.pull('version-1.9')
    #   dlclient.pull('version-1.9', '/tmp/project_downloads')
    #
    def pull(remote_path, local_dest_dir = '.')
      dest = Pathname(local_dest_dir)
      fail "Destination must be a directory" unless dest.directory?
      remote_pn = clean_id_pn(remote_path)
      if ent = entry(remote_pn)
        display_name = ent['display_name']
        basename = display_name == '/' ? '.' : display_name
        local_path = dest + basename
        case ent['entry_type']
        when 'directory'
          local_path.mkdir unless local_path.exist?
          ent['children'].each do |ch|
            remote_child = remote_pn + ch['display_name']
            pull(remote_child, local_path)
          end
        when 'file'
          content = get_cloaked_url(ent['content_url'])
          local_path.open("w") { |f| f.write(content) }
        else
          puts "Warning: skipping unsupported entry type"
        end
      else
        puts "Unknown downloads entry: #{remote_pn}"
      end
    end

    #
    # Push a local file or directory hierarchy to the server. Use
    # +local_path+ path to specify the local file or directory to upload. If
    # +local_path+ is a directory that ends in '/', upload the contents of
    # that directory instead of the directory and its contents. Use
    # +remote_dir+ to specify the remote directory to upload to.
    #
    # For example:
    #   dlclient.push('version-1.9')
    #   dlclient.push('dist', '/version-1.9')
    #
    def push(local_path, remote_dir = '/', opts = {})
      src = Pathname(local_path)
      if src.directory?
        if src.to_s.end_with?('/')
          target_dir = remote_dir
        else
          target_dir = Pathname(remote_dir) + src.basename
          mkdir(target_dir)
        end
        src.children.each do |ch|
          push(ch, target_dir)
        end
      else
        remote_id = Pathname(remote_dir) + src.basename
        entry = {:content_data => File.new(src)}.merge(opts)
        @kc[entry_api_path(remote_id)].put(:entry => entry)
      end
    end

    def mkdir(dir, opts = {})
      path = Pathname(dir)
      entry = {:display_name => path.basename}
      entry.merge(opts)
      @kc[entry_api_path(path)].put(:entry => entry)
    end

    def rm_r(path)
      @kc[entry_api_path(path)].delete
    end

    def rm(path)
      if entry_type(path) == 'directory'
        fail "Entry is a directory: #{path}"
      else
        @kc[entry_api_path(path)].delete
      end
    end

    def rmdir(path)
      entry = entry(path)
      if entry['entry_type'] == 'directory'
        if entry['children'].size == 0
          @kc[entry_api_path(path)].delete
        else
          fail "Directory not empty: #{path}"
        end
      else
        fail "Not a directory: #{path}"
      end
    end

    private

    # Canonicalize an entry id and return a relative Pathname or root Pathname
    def clean_id_pn(remote_path)
      remote_pn = Pathname(remote_path)
      root = Pathname('/')
      if remote_pn.absolute? && remote_pn != root
        remote_pn.relative_path_from(root)
      else
        remote_pn
      end
    end

    def entry_api_path(id)
      fail "Downloads feature not found" unless downloads_name
      escaped_id = URI.escape(clean_id_pn(id).to_s)
      "projects/#{@project}/features/#{downloads_name}/entries/#{escaped_id}"
    end

    def entry(path)
      begin
        resource = @kc[entry_api_path(path)].get
      rescue RestClient::ResourceNotFound => err
        return nil
      end
      JSON.parse(resource)
    end

    def get_cloaked_url(url)
      opts = @cloak_password ? {:user => "dont_care", :password => @cloak_password} : {}
      RestClient::Resource.new(url, opts).get
    end
  end
end
