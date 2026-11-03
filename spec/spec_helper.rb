# frozen_string_literal: true

begin
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
    add_group 'Messages', 'lib/legion/transport/messages'
    add_group 'Exchanges', 'lib/legion/transport/exchanges'
    add_group 'Queues', 'lib/legion/transport/queues'
    add_group 'Connections', 'lib/legion/transport/connections'
    project_name 'Legion::Transport'
  end
rescue LoadError
  puts 'Failed to load file for coverage reports, continuing without it'
end

require 'bundler/setup'
require 'tmpdir'
require 'fileutils'
require 'uri'

require 'legion/settings'
ENV['LEGION_DNS_BOOTSTRAP'] = 'false'
Legion::Settings.load
require 'legion/transport'

RSpec.configure do |config|
  config.before(:suite) do
    @transport_spool_directory = Dir.mktmpdir('legion-transport-spec-spool')
    Legion::Settings[:transport][:spool] = { directory: @transport_spool_directory }
  end

  config.around(:each, :rabbitmq) do |example|
    original = Legion::Settings[:transport][:connection]
    if ENV['RABBITMQ_URL']
      endpoint = URI.parse(ENV.fetch('RABBITMQ_URL'))
      port = endpoint.port || original.fetch(:port)
      connection = original.except(:hosts, :servers, :server).merge(host: endpoint.host, port: port,
                                                                    resolved_hosts: ["#{endpoint.host}:#{port}"])
      connection[:user] = URI.decode_www_form_component(endpoint.user) if endpoint.user
      connection[:password] = URI.decode_www_form_component(endpoint.password) if endpoint.password
      connection[:vhost] = URI.decode_www_form_component(endpoint.path.delete_prefix('/')) unless endpoint.path.to_s.empty?
      Legion::Settings[:transport][:connection] = connection
    end
    example.run
  ensure
    Legion::Settings[:transport][:connection] = original
  end

  config.after(:suite) do
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    Legion::Transport::Spool.stop_replay(deadline: deadline)
    FileUtils.remove_entry_secure(@transport_spool_directory) if @transport_spool_directory
  end

  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.filter_run_excluding rabbitmq: true if ENV['LEGION_MODE'] == 'lite'
end
