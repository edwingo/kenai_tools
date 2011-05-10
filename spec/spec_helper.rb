require 'rubygems'
require 'bundler/setup'

require "kenai_tools"

RSpec.configure do |c|
  # c.filter = {:focus => true}
  c.exclusion_filter = {:exclude => true}
end
