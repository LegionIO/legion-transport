# frozen_string_literal: true

require_relative 'lib/legion/transport/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-transport'
  spec.version       = Legion::Transport::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'Manages the connection to the transport tier(RabbitMQ)'
  spec.description   = 'The Gem to connect LegionIO and it\'s extensions to the transport tier'
  spec.homepage      = 'https://github.com/LegionIO/legion-transport'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-transport/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-transport/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/LegionIO/legion-transport',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-transport',
    'wiki_uri'              => 'https://github.com/LegionIO/legion-transport/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'base64'
  spec.add_dependency 'bunny', '>= 2.23'
  spec.add_dependency 'concurrent-ruby', '>= 1.2'
  spec.add_dependency 'legion-json', '>= 1.2.0'
  spec.add_dependency 'legion-logging', '>= 1.5.0'
  spec.add_dependency 'legion-settings', '>= 1.5.0'
  spec.add_dependency 'logger'
end
