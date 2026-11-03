# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

dependency_root = if File.directory?(File.expand_path('.ci-dependencies',
                                                      __dir__))
                    File.expand_path('.ci-dependencies', __dir__)
                  else
                    File.expand_path('..', __dir__)
                  end
settings_path = File.join(dependency_root, 'legion-settings')
gem 'legion-settings', path: settings_path if File.directory?(settings_path)

group :test do
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop'
  gem 'rubocop-legion'
  gem 'simplecov'
  gem 'sinatra', '>= 4.0'
end
