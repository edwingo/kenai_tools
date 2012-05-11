# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "kenai_tools/version"

Gem::Specification.new do |s|
  s.name        = "kenai_tools"
  s.version     = KenaiTools::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Edwin Goei", "Project Kenai Team"]
  s.email       = ["edwin.goei@oracle.com"]
  s.homepage    = "http://kenai.com/projects/kenaiapis"
  s.summary     = %q{Tools for sites hosted on the Kenai platform. Use dlutil to manage downloads and wiki-copy to copy wikis.}
  s.description = %q{Tools for sites such as java.net that are hosted on the Kenai platform. Use dlutil to upload and download files.
Use wiki-copy to copy wiki contents and images from one project to another across sites.}
  s.post_install_message = %q{
==============================================================================

Thanks for installing kenai_tools. Run the following command for what to do
next:

  dlutil --help

Warning: this tool is not yet supported on Windows. Please use a unix-based
OS. For more info, see http://kenai.com/jira/browse/KENAI-2853.

==============================================================================


}

  s.rubyforge_project = "kenai_tools"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_development_dependency("rspec", "~> 2.5")
  s.add_development_dependency("bundler", "~> 1.0")
  s.add_development_dependency("gemcutter")
  s.add_dependency("rest-client", "~> 1.6")
  s.add_dependency("json", "~> 1.5")
  s.add_dependency("highline", "~> 1.6")
  s.add_dependency("multipart-post", "~> 1.1")
end
