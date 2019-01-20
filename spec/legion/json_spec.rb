require 'spec_helper'
require 'legion/json'

SimpleCov.command_name 'lib/legion/json'

RSpec.describe Legion::Json do
  it 'has a version number' do
    expect(Legion::Json::VERSION).not_to be nil
  end

  it 'can load a parser for current platform' do
    hash = Legion::JSON.load('{"foo":"bar"}')
    expect(hash).to eq(foo: 'bar')
    string = Legion::JSON.dump(baz: 'qux')
    expect(string).to eq('{"baz":"qux"}')
  end

  it 'can load json correctly' do
    hash = Legion::JSON.load('{"foo":"bar"}')
    string = Legion::JSON.dump(hash)
    expect(string).to eq('{"foo":"bar"}')
  end

  it 'can handle large json objects' do
    hash = Legion::JSON.load('{"foo":"bar", "cake": "sugar", "test":{"ruby":"gem", "java": "jar"}}')
    expect(hash[:foo]).to eq('bar')
    expect(hash[:cake]).to eq('sugar')
    expect(hash[:test]).not_to be_empty
    expect(hash[:test][:ruby]).to eq('gem')
    expect(hash[:test][:java]).to eq('jar')
    expect(hash[:test][:thing]).to be_nil
    expect(hash[:nil]).to be_nil
  end

  it 'matches when switched back to json' do
    json = '{"foo":"bar"}'
    hash = Legion::JSON.load(json)
    return_json = Legion::JSON.dump(hash)
    expect(return_json).to eq(json)
  end

  it 'will not sq' do
    hash = Legion::JSON.load('{"foo":"bar"}')
    expect(hash).not_to eq(foo: 'baz')
    expect(hash).not_to eq(bar: 'foo')
  end

  it 'will throw exception' do
    expect { Legion::JSON.load('{"foo":"bar}') }.to raise_error(Legion::JSON::ParseError)
    expect { Legion::JSON.load('{"foo":"bar"') }.to raise_error(Legion::JSON::ParseError)
    expect { Legion::JSON.load('{foo:"bar}') }.to raise_error(Legion::JSON::ParseError)
    expect { Legion::JSON.load('{') }.to raise_error(Legion::JSON::ParseError)
  end
end
