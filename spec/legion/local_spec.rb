# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/local'

RSpec.describe Legion::Transport::Local do
  before do
    described_class.reset!
    @workers = []
  end

  after do
    @workers.each do |worker|
      worker.kill if worker.alive?
      worker.join
    end
    described_class.reset!
  end

  def start_worker(&)
    Thread.new(&).tap { |worker| @workers << worker }
  end

  it 'isolates direct subscriptions sharing a routing key on different exchanges' do
    first = []
    second = []
    described_class.subscribe('work', exchange_name: 'ex.one') { |payload| first << payload }
    described_class.subscribe('work', exchange_name: 'ex.two') { |payload| second << payload }
    described_class.publish('ex.two', 'work', 'second')
    described_class.publish('ex.one', 'work', 'first')

    expect(first).to eq(['first'])
    expect(second).to eq(['second'])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  it 'keeps pre-subscription buffers separate for the same key on different exchanges' do
    described_class.publish('ex.one', 'work', 'first')
    described_class.publish('ex.two', 'work', 'second')
    first = []
    second = []
    described_class.subscribe('work', exchange_name: 'ex.one') { |payload| first << payload }
    expect(first).to eq(['first'])
    expect(described_class.queue_depth('work')).to eq(1)

    described_class.publish('ex.two', 'work', 'later')
    expect(first).to eq(['first'])
    described_class.subscribe('work', exchange_name: 'ex.two') { |payload| second << payload }
    expect(second).to eq(%w[second later])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  it 'limits subscriptions without an exchange name to the default exchange' do
    received = []
    described_class.subscribe('work') { |payload| received << payload }
    described_class.publish('tasks', 'work', 'other')
    described_class.publish('', 'work', 'default')

    expect(received).to eq(['default'])
    expect(described_class.queue_depth('work')).to eq(1)
  end

  it 'retains only pending messages and never replays completed delivery history' do
    received = []
    described_class.subscribe('work', exchange_name: 'tasks') { |payload| received << payload }
    3.times { |index| described_class.publish('tasks', 'work', index) }

    later = []
    described_class.subscribe('work', exchange_name: 'tasks') { |payload| later << payload }
    expect(received).to eq([0, 1, 2])
    expect(described_class.queue_depth('work')).to eq(0)
    expect(later).to be_empty
  end

  it 'delivers pre-subscription backlog in order and removes it from pending storage' do
    described_class.publish('tasks', 'work', 'first')
    described_class.publish('tasks', 'work', 'second')
    expect(described_class.queue_depth('work')).to eq(2)

    received = []
    described_class.subscribe('work', exchange_name: 'tasks') { |payload| received << payload }
    expect(received).to eq(%w[first second])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  it 'allows callbacks to inspect depth and publish recursively to their own queue' do
    received = []
    depths = []
    described_class.subscribe('work', exchange_name: 'tasks') do |payload|
      received << payload
      depths << described_class.queue_depth('work')
      described_class.publish('tasks', 'work', 'second') if payload == 'first'
    end

    described_class.publish('tasks', 'work', 'first')
    expect(received).to eq(%w[first second])
    expect(depths).to eq([0, 0])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  it 'allows backlog callbacks to inspect depth and publish without reordering the backlog' do
    described_class.publish('tasks', 'work', 'first')
    described_class.publish('tasks', 'work', 'second')
    received = []
    depths = []
    described_class.subscribe('work', exchange_name: 'tasks') do |payload|
      received << payload
      depths << described_class.queue_depth('work')
      described_class.publish('tasks', 'work', 'third') if payload == 'first'
    end

    expect(received).to eq(%w[first second third])
    expect(depths).to eq([1, 1, 0])
  end

  it 'keeps concurrent live publications behind the backlog currently being delivered' do
    described_class.publish('tasks', 'work', 'first')
    described_class.publish('tasks', 'work', 'second')
    entered = Thread::Queue.new
    release = Thread::Queue.new
    received = []
    worker = start_worker do
      described_class.subscribe('work', exchange_name: 'tasks') do |payload|
        received << payload
        next unless payload == 'first'

        entered << :entered
        release.pop
      end
    end
    expect(entered.pop(timeout: 2)).to eq(:entered)

    publisher = start_worker { described_class.publish('tasks', 'work', 'third') }
    expect(publisher.join(2)).to eq(publisher)
    expect(described_class.queue_depth('work')).to eq(2)
    release << :continue
    expect(worker.join(2)).to eq(worker)
    expect(received).to eq(%w[first second third])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  %i[live backlog].each do |delivery_mode|
    it "allows unrelated queue progress while a #{delivery_mode} callback blocks" do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      callback = proc do |_payload|
        entered << :entered
        release.pop
      end
      if delivery_mode == :backlog
        described_class.publish('tasks', 'slow', 'blocked')
        worker = start_worker { described_class.subscribe('slow', exchange_name: 'tasks', &callback) }
      else
        described_class.subscribe('slow', exchange_name: 'tasks', &callback)
        worker = start_worker { described_class.publish('tasks', 'slow', 'blocked') }
      end
      expect(entered.pop(timeout: 2)).to eq(:entered)

      received = []
      independent = start_worker do
        described_class.subscribe('fast', exchange_name: 'tasks') { |payload| received << payload }
        described_class.publish('tasks', 'fast', 'independent')
      end
      expect(independent.join(2)).to eq(independent)
      expect(received).to eq(['independent'])
      expect(described_class.queue_depth('fast')).to eq(0)
      release << :continue
      expect(worker.join(2)).to eq(worker)
    end
  end

  it 'retains a failed callback delivery for a replacement subscriber' do
    failed = described_class.subscribe('work', exchange_name: 'tasks') { |_payload| raise IOError, 'consumer failed' }
    expect { described_class.publish('tasks', 'work', 'retry') }.to raise_error(IOError, 'consumer failed')
    described_class.cancel(subscription: failed.fetch(:subscription))
    received = []
    described_class.subscribe('work', exchange_name: 'tasks') { |payload| received << payload }

    expect(received).to eq(['retry'])
    expect(described_class.queue_depth('work')).to eq(0)
  end

  it 'reset removes callbacks as well as pending messages' do
    received = []
    subscription = described_class.subscribe('work', exchange_name: 'tasks') { |payload| received << payload }
    described_class.publish('tasks', 'pending', 'old')
    described_class.reset!
    described_class.publish('tasks', 'work', 'new')

    expect(received).to be_empty
    expect(described_class.cancelled?(subscription: subscription.fetch(:subscription))).to be true
    expect(described_class.queue_depth('pending')).to eq(0)
  end
end
