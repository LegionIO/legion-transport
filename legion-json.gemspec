lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'legion/json/version'

Gem::Specification.new do |spec|
  spec.name = (RUBY_ENGINE == 'jruby' ? 'legion-json-java' : 'legion-json')
  spec.version       = Legion::Json::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'Legion JSON'
  spec.description   = 'A gem used to load and use JSON objects inside the Legion framework'
  spec.homepage      = 'https://bitbucket.org/legion-io/legion-json'
  spec.license       = 'MIT'
  spec.required_ruby_version = '~> 2.2'

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1'
  spec.add_development_dependency 'codecov', '~> 0'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rspec_junit_formatter', '~> 0'
  spec.add_development_dependency 'rubocop', '~> 0'
  spec.add_dependency 'json', '~> 2.1'
  if RUBY_ENGINE == 'jruby'
    spec.add_dependency('jrjackson', '~> 0.4')
  else
    spec.add_dependency('oj', '~> 2.18')
  end
end
