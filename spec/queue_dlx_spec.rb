# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Queue DLX consolidation' do
  # Use allocate to test instance methods without triggering AMQP initialization
  let(:queue_class) do
    Class.new(Legion::Transport::Queue) do
      def self.ancestors
        # Simulate a queue under Legion::Extensions::Knowledge::Queues::Chunker
        [self, Legion::Transport::Queue]
      end

      def self.to_s
        'Legion::Extensions::Knowledge::Queues::Chunker'
      end
    end
  end

  describe '#dlx_enabled' do
    it 'returns true by default' do
      instance = Legion::Transport::Queue.allocate
      expect(instance.dlx_enabled).to be true
    end
  end

  describe '#dlx_exchange_name' do
    it 'derives the DLX exchange name from the LEX segment' do
      instance = queue_class.allocate
      expect(instance.dlx_exchange_name).to eq('knowledge.dlx')
    end
  end

  describe 'dlx opt-out' do
    let(:no_dlx_class) do
      Class.new(Legion::Transport::Queue) do
        def dlx_enabled
          false
        end
      end
    end

    it 'omits x-dead-letter-exchange when dlx_enabled is false' do
      instance = no_dlx_class.allocate
      opts = instance.default_options
      expect(opts[:arguments]).not_to have_key(:'x-dead-letter-exchange')
    end
  end
end
