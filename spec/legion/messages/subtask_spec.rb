# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/messages/subtask'

RSpec.describe Legion::Transport::Messages::SubTask do
  describe '#routing_key' do
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

    it 'returns nil when no routing conditions match' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { conditions: ' ', transformation: '' })
      expect(instance.routing_key).to be_nil
    end
  end

  describe '#validate' do
    it 'raises TypeError when function is not a String' do
      instance = described_class.allocate
      instance.instance_variable_set(:@options, { function: 123 })
      expect { instance.validate }.to raise_error(TypeError)
    end
  end
end
