# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Message settings and publish contract (#20)' do
  describe 'Message#expiration TTL fallback' do
    it 'reads :ttl from transport message settings when :expiration is not set' do
      Legion::Settings[:transport][:messages][:ttl] = '5000'
      msg = Legion::Transport::Message.new(function: 'test')
      expect(msg.expiration).to eq('5000')
    ensure
      Legion::Settings[:transport][:messages].delete(:ttl)
    end

    it 'prefers explicit :expiration over :ttl' do
      Legion::Settings[:transport][:messages][:ttl] = '5000'
      msg = Legion::Transport::Message.new(function: 'test', expiration: '1000')
      expect(msg.expiration).to eq('1000')
    ensure
      Legion::Settings[:transport][:messages].delete(:ttl)
    end
  end

  describe 'Message#persistent override' do
    it 'retains explicit false when persistence is enabled in settings' do
      Legion::Settings.with_overlay(transport: { messages: { persistent: true } }) do
        expect(Legion::Transport::Message.new(persistent: false).persistent).to be false
      end
    end
  end

  describe 'Messages::SubTask#validate' do
    it 'passes validation when function_id is an Integer (no function string required)' do
      instance = Legion::Transport::Messages::SubTask.allocate
      instance.instance_variable_set(:@options, { function_id: 42 })
      expect { instance.validate }.not_to raise_error
    end

    it 'passes validation when function is a String' do
      instance = Legion::Transport::Messages::SubTask.allocate
      instance.instance_variable_set(:@options, { function: 'my_func' })
      expect { instance.validate }.not_to raise_error
    end

    it 'raises TypeError when neither function string nor function_id is present' do
      instance = Legion::Transport::Messages::SubTask.allocate
      instance.instance_variable_set(:@options, {})
      expect { instance.validate }.to raise_error(TypeError)
    end
  end

  describe 'Messages::TaskUpdate#validate' do
    it 'raises InvalidTaskStatus for an unknown status' do
      instance = Legion::Transport::Messages::TaskUpdate.allocate
      instance.instance_variable_set(:@options, { status: 'bogus.status', task_id: 1 })
      expect { instance.validate }.to raise_error(Legion::Exception::InvalidTaskStatus)
    end

    it 'raises InvalidTaskId when task_id is missing' do
      instance = Legion::Transport::Messages::TaskUpdate.allocate
      instance.instance_variable_set(:@options, { status: 'task.completed' })
      expect { instance.validate }.to raise_error(Legion::Exception::InvalidTaskId)
    end

    it 'sets @valid when status and task_id are valid' do
      instance = Legion::Transport::Messages::TaskUpdate.allocate
      instance.instance_variable_set(:@options, { status: 'task.completed', task_id: 99 })
      instance.validate
      expect(instance.instance_variable_get(:@valid)).to be true
    end
  end
end
