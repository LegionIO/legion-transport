# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/messages/task'

RSpec.describe Legion::Transport::Messages::Task do
  describe '#routing_key' do
    it 'returns the explicit routing_key option when present' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { routing_key: 'custom.key', function: 'fn' })
      expect(instance.routing_key).to eq 'custom.key'
    end

    it 'returns conditioner routing key when conditions string is present' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { conditions: '{"foo":"bar"}' })
      expect(instance.routing_key).to eq 'task.subtask.conditioner'
    end

    it 'returns transform routing key when transformation string is present' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { conditions: nil, transformation: '{"key":"val"}' })
      expect(instance.routing_key).to eq 'task.subtask.transform'
    end

    it 'returns queue.function routing key when both are present' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { queue: 'myqueue', function: 'myfunc' })
      expect(instance.routing_key).to eq 'myqueue.myfunc'
    end
  end

  describe '#validate' do
    it 'raises TypeError when function is not a String' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { function: 42 })
      expect { instance.validate }.to raise_error(TypeError)
    end
  end
end
