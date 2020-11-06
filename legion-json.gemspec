lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'legion/json/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-json'
  spec.version       = Legion::Json::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'Legion JSON'
  spec.description   = 'A gem used to load and use JSON objects inside the Legion framework'
  spec.homepage      = 'https://bitbucket.org/legion-io/legion-json'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 2.5'
  spec.metadata = {
    'bug_tracker_uri'   => 'https://legionio.atlassian.net/projects/JSON/issues',
    'changelog_uri'     => 'https://legionio.atlassian.net/wiki/spaces/LEGION/pages/24674324/JSON',
    'documentation_uri' => 'https://legionio.atlassian.net/wiki/spaces/LEGION/pages/24674324/JSON',
    'homepage_uri'      => 'https://legionio.atlassian.net/wiki/spaces/LEGION',
    'source_code_uri'   => 'https://bitbucket.org/legion-io/legion-json',
    'wiki_uri'          => 'https://legionio.atlassian.net/wiki/spaces/LEGION/pages/24674324/JSON'
  }

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '>= 2'
  spec.add_development_dependency 'jrjackson' if RUBY_ENGINE == 'jruby'
  spec.add_development_dependency 'oj' unless RUBY_ENGINE == 'jruby'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'rspec_junit_formatter'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-performance'
  spec.add_development_dependency 'simplecov', '< 0.18.0'
  spec.add_development_dependency 'simplecov_json_formatter'

  spec.add_dependency 'json_pure'
  spec.add_dependency 'multi_json'
end
