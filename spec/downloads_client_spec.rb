require 'spec_helper'
require "open-uri"

# This rspec test assumes that a development kenai/junction2 server is running
SITE = "http://localhost:3000"
begin
  RestClient::Resource.new(SITE).get
rescue
  fail("Check that a Rails kenai/junction2 development mode server is running at #{SITE}")
end

describe KenaiTools::DownloadsClient do
  before :all do
    # Init downloads feature for test project oasis
    dlclient = KenaiTools::DownloadsClient.new(SITE, "oasis", :downloads_name => "downloads")
    dlclient.authenticate("mehdi", "mehdi") unless dlclient.authenticated?
    dlclient.delete_feature('yes') if dlclient.ping
    dlclient.get_or_create
  end

  # Larger timeout used here to debug server-side code or handling a large amount of data
  let(:dlclient) { KenaiTools::DownloadsClient.new(SITE, "oasis", :timeout => 36000) }
  let(:data) { Pathname.new(File.dirname(__FILE__) + '/fixtures/data') }
  let(:file1) { data + "text1.txt" }

  def ensure_write_permission
    dlclient.authenticate("mehdi", "mehdi") unless dlclient.authenticated?
  end

  def ensure_remote_dir(remote_dir)
    unless dlclient.entry_type(remote_dir) == 'directory'
      ensure_write_permission
      dlclient.rm_r(remote_dir) if dlclient.exist?(remote_dir)
      dlclient.mkdir(remote_dir)
    end
  end

  def ensure_remote_sample_data(rel_path)
    ensure_write_permission
    pn = data + rel_path
    dlclient.push(pn) unless dlclient.exist?(rel_path)
  end

  describe "authentication" do
    it "should authenticate with valid credentials" do
      dlclient.authenticate("mehdi", "mehdi").should be_true
      dlclient.authenticated?.should be_true
    end

    it "should fail to authenticate with invalid credentials" do
      dlclient.authenticate("mehdi", "xmehdi").should be_false
      dlclient.authenticated?.should be_false
    end
  end

  describe "bootstrap" do
    context "basic" do
      # Note: this test depend upon sample downloads data in the development DB
      it "should detect existence of a file" do
        dlclient = KenaiTools::DownloadsClient.new(SITE, "glassfish")
        dlclient.exist?("glassfishv4solaris.zip").should be_true
      end

      it "should detect non-existence of a file" do
        dlclient = KenaiTools::DownloadsClient.new(SITE, "glassfish")
        dlclient.exist?("non-existent-download.zip").should be_false
      end

      it "should return the entry_type of an entry" do
        dlclient = KenaiTools::DownloadsClient.new(SITE, "glassfish")
        dlclient.entry_type("glassfishv4solaris.zip").should == 'file'
      end
    end

    context "authenticated" do
      before :each do
        dlclient.authenticate("mehdi", "mehdi")
      end

      it "should upload a single file to the top level" do
        dlclient.rm_r(file1.basename) if dlclient.exist?(file1.basename)

        dlclient.push(file1)
        dlclient.exist?(file1.basename).should be_true
      end

      it "should destroy a single file at the top level" do
        ensure_remote_sample_data(file1.basename)

        dlclient.rm(file1.basename).should be_true
      end

      it "should make a directory" do
        dirname = "x11r5"
        dlclient.rm_r(dirname) if dlclient.exist?(dirname)

        dlclient.mkdir(dirname)
        dlclient.entry_type(dirname).should == 'directory'
      end

      it "should delete a directory" do
        dirname = "x11r5"
        dlclient.rm_r(dirname) if dlclient.exist?(dirname)
        dlclient.mkdir(dirname)

        dlclient.exist?(dirname).should be_true
        dlclient.rm_r(dirname)
        dlclient.exist?(dirname).should be_false
      end
    end
  end

  describe "listing" do
    before :each do
      dlclient.authenticate("mehdi", "mehdi")
      @dir19 = 'version-1.9'
      ensure_remote_dir(@dir19)
      ensure_remote_sample_data(file1.basename)
      dlclient.authenticate("mehdi", "wrong-password").should be_false
    end

    it "should list the top level downloads of a project as a directory named '/'" do
      dlclient.ls.keys.should =~ ['href', 'display_name', 'entry_type', 'description', 'tags', 'children',
        'created_at', 'updated_at', 'content_type']
      dlclient.ls['entry_type'].should == 'directory'
      dlclient.ls['display_name'].should == '/'
      dlclient.ls['children'].map { |ch| ch['display_name'] }.should include(file1.basename.to_s, @dir19)
    end

    it "should list a file" do
      entry = dlclient.ls(file1.basename)
      entry['entry_type'].should == 'file'
      entry['entry_content_type'].should == 'text/plain'
      open(entry['content_url']).read == file1.open.read
      entry.keys.should =~ ['href', 'display_name', 'entry_type', 'description', 'tags', 'size',
        'created_at', 'updated_at', 'content_url', 'entry_content_type', 'content_type']
    end

    it "should list a subdirectory" do
      entry = dlclient.ls(@dir19)
      entry['entry_type'].should == 'directory'
      entry.keys.should =~ ['href', 'display_name', 'entry_type', 'description', 'tags', 'children',
        'created_at', 'updated_at', 'content_type']
    end
  end

  describe "push" do
    before :each do
      dlclient.authenticate("mehdi", "mehdi")
    end

    it "should upload a single file to a remote directory specified with a relative path" do
      target_dir = "version-1.9"
      ensure_remote_dir(target_dir)

      dlclient.push(file1, target_dir)
      target_file = File.join(target_dir, file1.basename)
      dlclient.exist?(target_file).should be_true
    end

    it "should upload a single file to a remote directory specified with an absolute path" do
      target_dir = "/version-1.9"
      ensure_remote_dir(target_dir)

      dlclient.push(file1, target_dir)
      target_file = File.join(target_dir, file1.basename)
      dlclient.exist?(target_file).should be_true
    end

    it "should recursively upload a directory into a new target directory" do
      target_dir = "tax_year_2010"
      ensure_remote_dir(target_dir)
      src_dir = data + "irs_docs"

      dlclient.push(src_dir, target_dir)
      target_subdir = File.join(target_dir, src_dir.basename)
      dlclient.entry_type(target_subdir).should == 'directory'
      expected_names = src_dir.children.map { |ch| ch.basename.to_s }
      actual_names = dlclient.ls(target_subdir)['children'].map { |ch| ch['display_name'] }
      actual_names.should =~ expected_names
    end

    it "should recursively upload source directory contents if the source argument ends with a '/'" do
      target_dir = "sax2r2"
      ensure_remote_dir(target_dir)
      src_dir = data + "sax2/"

      dlclient.push(src_dir, target_dir)
      expected_names = src_dir.children.map { |ch| ch.basename.to_s }
      actual_names = dlclient.ls(target_dir)['children'].map { |ch| ch['display_name'] }
      actual_names.should =~ expected_names
    end
  end

  describe "remove files" do
    before :each do
      dlclient.authenticate("mehdi", "mehdi")
    end

    it "should remove a directory and its contents" do
      dir = "irs_docs"
      ensure_remote_sample_data(dir)

      dlclient.rm_r(dir)
      dlclient.exist?(dir).should be_false
    end

    it "should not remove a directory and its contents for rmdir" do
      dir = "irs_docs"
      ensure_remote_sample_data(dir)

      lambda { dlclient.rmdir(dir) }.should raise_error(/not empty/)
      dlclient.exist?(dir).should be_true
    end
  end

  describe "miscellaneous" do
    it "should ping a working service" do
      dlclient.ping.should be_true
    end

    it "should fail to ping a non-working service" do
      down_dlclient = KenaiTools::DownloadsClient.new(SITE, "bad-project")
      down_dlclient.ping.should be_false
    end

    it "should discover the name of a downloads feature if a project only has one" do
      dlclient2 = KenaiTools::DownloadsClient.new(SITE, "oasis")
      dlclient2.downloads_name.should == 'downloads'
    end

    it "should discover the downloads feature if a project only has one" do
      dlclient2 = KenaiTools::DownloadsClient.new(SITE, "oasis")
      dlclient2.downloads_feature['type'].should == 'downloads'
    end

    it "should delete a downloads feature" do
      dlclient2 = KenaiTools::DownloadsClient.new(SITE, "openjdk")
      dlclient2.authenticate("craigmcc", "craigmcc") unless dlclient2.authenticated?
      dlclient2.get_or_create

      dlclient2.ping.should be_true
      lambda { dlclient2.delete_feature }.should raise_error(/[Cc]onfirm/)
      dlclient2.delete_feature('yes').should be_true
      dlclient2.ping.should be_false
    end

    it "should create a downloads feature" do
      dlclient2 = KenaiTools::DownloadsClient.new(SITE, "openjdk")
      dlclient2.authenticate("craigmcc", "craigmcc") unless dlclient2.authenticated?
      dlclient2.delete_feature('yes') if dlclient2.ping

      dlclient2.ping.should be_false
      dlclient2.get_or_create.should == 'downloads'
      dlclient2.ping.should be_true
    end

    it "should make a directory with a name that needs to be encoded" do
      dirname = "Web 2.0"
      ensure_write_permission
      dlclient.rm_r(dirname) if dlclient.exist?(dirname)

      dlclient.mkdir(dirname)
      dlclient.entry_type(dirname).should == 'directory'

      dlclient.push(file1, dirname).should be_true
    end
  end

  describe "pull" do
    it "should download a single file to a local directory" do
      ensure_remote_sample_data(file1.basename)

      Dir.mktmpdir do |dir|
        dlclient.pull(file1.basename, dir)
        (Pathname(dir) + file1.basename).read.should == file1.read
      end
    end

    it "should recursively download a remote subdirectory to a local directory" do
      sample_dir = "irs_docs"
      ensure_remote_sample_data(sample_dir)

      Dir.mktmpdir do |dir|
        dlclient.pull(sample_dir, dir)
        dest_dir = Pathname(dir) + sample_dir
        system("diff -r #{data + sample_dir} #{dest_dir}").should be_true
      end
    end

    it "should recursively download all entries to a local directory" do
      sample_dir = "irs_docs"
      ensure_remote_sample_data(sample_dir)

      Dir.mktmpdir do |dir|
        dlclient.pull('/', dir)
        dest_dir = Pathname(dir) + sample_dir
        dest_dir.should be_exist
      end
    end
  end
end
