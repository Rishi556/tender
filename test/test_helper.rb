ENV['RAILS_ENV'] ||= 'test'

if !!ENV["HELL_ENABLED"]
  require 'simplecov'
  
  SimpleCov.start
  SimpleCov.merge_timeout 3600
end

require_relative '../config/environment'
require 'rails/test_help'

class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
