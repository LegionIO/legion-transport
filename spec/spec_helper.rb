begin
  require 'simplecov'

  SimpleCov.profiles.define 'legion-json' do
    add_filter '/spec/'
    add_filter '/config/'
    add_filter '/tmp/'

    add_group 'Java', 'lib/legion/json/jrjackson'
    add_group 'MRI', 'lib/legion/json/oj'
    add_group 'Errors', 'lib/legion/parse_error'
    add_group 'Core', 'lib/legion/json'
  end

  SimpleCov.start do
    formatter SimpleCov::Formatter::SimpleFormatter
  end
  SimpleCov.use_merging(true)
  if ENV.key?('CODECOV_TOKEN')
    require 'codecov'
    SimpleCov.formatter = SimpleCov::Formatter::Codecov
  end
rescue LoadError
  puts 'Failed to load file for coverage reports, continuing without it'
end

require 'bundler/setup'
require 'legion/json'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
