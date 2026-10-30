# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Transport::Helpers::Pool do
  let(:session) { instance_double('Bunny::Session', open?: true, closed?: false, close: nil) }
  let(:second_session) { instance_double('Bunny::Session', open?: true, closed?: false, close: nil) }
  let(:threads) { [] }

  after do
    threads.each do |thread|
      next unless thread.alive?

      thread.kill
      thread.join
    end
  end

  def start_thread(&block)
    threads << Thread.new do
      Thread.current.report_on_exception = false
      block.call
    end
    threads.last
  end

  def thread_result(thread:)
    expect(thread.join(2)).to eq(thread)
    thread.value
  end

  def wait_until_sleeping(thread:)
    Timeout.timeout(2) { Thread.pass until thread.status == 'sleep' }
  end

  describe '#checkout' do
    it 'allows checkin and reuse while another connection is being created' do
      pending = Queue.new([session, second_session])
      entered = Queue.new
      release = Queue.new
      pool = described_class.new(size: 2, timeout: 5) do
        connection = pending.pop
        if connection.equal?(second_session)
          entered << :creating
          release.pop
        end
        connection
      end
      first = pool.checkout
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(:creating)

      returning = start_thread { pool.checkin(connection: first) }
      thread_result(thread: returning)
      reusing = start_thread { pool.checkout }
      expect(thread_result(thread: reusing)).to eq(first)
      expect(creating).to be_alive

      release << true
      expect(thread_result(thread: creating)).to eq(second_session)
    end

    it 'reserves capacity before starting a factory outside the lock' do
      entered = Queue.new
      release = Queue.new
      waiting = Queue.new
      pool = described_class.new(size: 1, timeout: 5) do
        entered << :creating
        release.pop
        session
      end
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(:creating)
      waiter = start_thread do
        waiting << :started
        pool.checkout
      end
      expect(waiting.pop(timeout: 2)).to eq(:started)
      wait_until_sleeping(thread: waiter)
      expect(entered).to be_empty

      release << true
      first = thread_result(thread: creating)
      pool.checkin(connection: first)
      expect(thread_result(thread: waiter)).to eq(first)
      expect(entered).to be_empty
    end

    it 'bounds a slow factory in the checkout thread and releases its reservation' do
      entered = Queue.new
      release = Queue.new
      cleaned = Queue.new
      attempts = 0
      pool = described_class.new(size: 1, timeout: 0.1) do
        attempts += 1
        if attempts == 1
          entered << Thread.current
          begin
            release.pop
          ensure
            cleaned << :finished
          end
        end
        session
      end
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(creating)

      expect { thread_result(thread: creating) }.to raise_error(Legion::Transport::PoolTimeout)
      expect(cleaned.pop(timeout: 2)).to eq(:finished)
      expect(pool.checkout).to eq(session)
    end

    it 'wakes a capacity waiter when a reserved factory raises' do
      entered = Queue.new
      release = Queue.new
      waiting = Queue.new
      attempts = 0
      pool = described_class.new(size: 1, timeout: 5) do
        attempts += 1
        if attempts == 1
          entered << :creating
          release.pop
          raise IOError, 'connection refused'
        end
        session
      end
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(:creating)
      waiter = start_thread do
        waiting << :started
        pool.checkout
      end
      expect(waiting.pop(timeout: 2)).to eq(:started)
      wait_until_sleeping(thread: waiter)

      release << true
      expect { thread_result(thread: creating) }.to raise_error(IOError, 'connection refused')
      expect(thread_result(thread: waiter)).to eq(session)
    end

    it 'uses the original deadline when waiting is followed by connection creation' do
      offset = 0
      allow(Process).to receive(:clock_gettime).and_wrap_original do |original, *arguments|
        current = original.call(*arguments)
        arguments == [Process::CLOCK_MONOTONIC] ? current + offset : current
      end
      pending = Queue.new([session, second_session])
      entered = Queue.new
      release = Queue.new
      waiting = Queue.new
      pool = described_class.new(size: 1, timeout: 100) do
        connection = pending.pop
        if connection.equal?(second_session)
          entered << :creating
          release.pop
        end
        connection
      end
      first = pool.checkout
      waiter = start_thread do
        waiting << :started
        pool.checkout
      end
      expect(waiting.pop(timeout: 2)).to eq(:started)
      wait_until_sleeping(thread: waiter)
      allow(first).to receive_messages(open?: false, closed?: true)

      offset = 99
      pool.checkin(connection: first)
      expect(entered.pop(timeout: 2)).to eq(:creating)
      expect { thread_result(thread: waiter) }.to raise_error(Legion::Transport::PoolTimeout)
    end

    it 'does not extend an exhausted checkout when the wall clock moves backwards' do
      pool = described_class.new(size: 1, timeout: 0.1) { session }
      pool.checkout
      allow(Time).to receive(:now).and_return(Time.at(2_000_000_000), Time.at(1_000_000_000))
      waiter = start_thread { pool.checkout }

      expect { thread_result(thread: waiter) }.to raise_error(Legion::Transport::PoolTimeout)
    end

    it 'replaces a connection that closes after being checked in' do
      pending = Queue.new([session, second_session])
      pool = described_class.new(size: 1, timeout: 0.1) { pending.pop }
      first = pool.checkout
      pool.checkin(connection: first)
      allow(first).to receive_messages(open?: false, closed?: true)

      expect(pool.checkout).to eq(second_session)
      expect(pool.sessions).to eq([second_session])
    end
  end

  describe '#checkin' do
    it 'does not create duplicate leases from repeated or foreign checkins' do
      pool = described_class.new(size: 1, timeout: 0.1) { session }
      first = pool.checkout
      pool.checkin(connection: second_session)
      pool.checkin(connection: first)
      pool.checkin(connection: first)
      expect(pool.checkout).to eq(first)
      waiter = start_thread { pool.checkout }

      expect { thread_result(thread: waiter) }.to raise_error(Legion::Transport::PoolTimeout)
      expect(pool.sessions).to eq([first])
    end
  end

  describe '#sessions' do
    it 'returns a detached snapshot of available and checked-out sessions' do
      pending = Queue.new([session, second_session])
      pool = described_class.new(size: 2, timeout: 0.1) { pending.pop }
      first = pool.checkout
      second = pool.checkout
      pool.checkin(connection: first)
      snapshot = pool.sessions
      expect(snapshot).to contain_exactly(first, second)
      snapshot.clear

      expect(pool.size).to eq(2)
      expect(first).to receive(:close).once
      expect(second).to receive(:close).once
      pool.shutdown
    end
  end

  describe '#shutdown' do
    it 'detaches sessions and wakes every waiter before closing outside the lock' do
      waiting = Queue.new
      closing = Queue.new
      release = Queue.new
      pool = described_class.new(size: 1, timeout: 5) { session }
      first = pool.checkout
      waiters = Array.new(2) do
        start_thread do
          waiting << :started
          pool.checkout
        end
      end
      waiters.each do |waiter|
        expect(waiting.pop(timeout: 2)).to eq(:started)
        wait_until_sleeping(thread: waiter)
      end
      closer = start_thread do
        pool.shutdown do |connection|
          closing << [connection, pool.sessions]
          release.pop
          connection.close
        end
      end
      expect(closing.pop(timeout: 2)).to eq([first, []])

      waiters.each do |waiter|
        expect { thread_result(thread: waiter) }.to raise_error(Legion::Transport::PoolClosed)
      end
      expect(closer).to be_alive
      pool.checkin(connection: first)
      expect(pool.size).to eq(0)
      expect { pool.checkout }.to raise_error(Legion::Transport::PoolClosed)

      release << true
      thread_result(thread: closer)
    end

    it 'closes a creation that loses the shutdown race with the retained callback' do
      entered = Queue.new
      release = Queue.new
      closed = Queue.new
      pool = described_class.new(size: 1, timeout: 5) do
        entered << :creating
        release.pop
        session
      end
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(:creating)
      expect(session).to receive(:close).once
      pool.shutdown do |connection|
        closed << [connection, pool.sessions]
        connection.close
      end
      pool.shutdown { raise 'a repeated shutdown must not replace the first teardown callback' }

      release << true
      expect { thread_result(thread: creating) }.to raise_error(Legion::Transport::PoolClosed)
      expect(closed.pop(timeout: 2)).to eq([session, []])
      expect(pool.sessions).to be_empty
      expect { pool.checkout }.to raise_error(Legion::Transport::PoolClosed)
    end

    it 'attempts every detached session before propagating a teardown failure' do
      pending = Queue.new([session, second_session])
      pool = described_class.new(size: 2, timeout: 0.1) { pending.pop }
      pool.checkout
      pool.checkout
      allow(session).to receive(:close).and_raise(IOError, 'close failed')
      expect(second_session).to receive(:close).once

      expect { pool.shutdown(&:close) }.to raise_error(IOError, 'close failed')
      expect(pool.sessions).to be_empty
      expect { pool.checkout }.to raise_error(Legion::Transport::PoolClosed)
    end

    it 'bounds the default close without leaving a background close worker' do
      stub_const('Legion::Transport::Helpers::Pool::CLOSE_TIMEOUT', 0.1)
      entered = Queue.new
      release = Queue.new
      cleaned = Queue.new
      allow(session).to receive(:close) do
        entered << Thread.current
        begin
          release.pop
        ensure
          cleaned << :finished
        end
      end
      pool = described_class.new(size: 1, timeout: 0.1) { session }
      pool.checkout
      closer = start_thread { pool.shutdown }
      expect(entered.pop(timeout: 2)).to eq(closer)

      expect { thread_result(thread: closer) }.to raise_error(Timeout::Error)
      expect(cleaned.pop(timeout: 2)).to eq(:finished)
      expect(pool.sessions).to be_empty
      expect { pool.checkout }.to raise_error(Legion::Transport::PoolClosed)
    end

    it 'preserves PoolClosed when cleanup of a late creation also fails' do
      entered = Queue.new
      release = Queue.new
      pool = described_class.new(size: 1, timeout: 5) do
        entered << :creating
        release.pop
        session
      end
      creating = start_thread { pool.checkout }
      expect(entered.pop(timeout: 2)).to eq(:creating)
      pool.shutdown { raise IOError, 'late close failed' }

      release << true
      expect { thread_result(thread: creating) }.to raise_error(Legion::Transport::PoolClosed)
      expect(pool.sessions).to be_empty
    end
  end

  describe '#connected?' do
    it 'reports live owned sessions rather than just occupied slots' do
      pool = described_class.new(size: 1, timeout: 0.1) { session }
      pool.checkout
      expect(pool).to be_connected
      allow(session).to receive(:open?).and_return(false)
      expect(pool).not_to be_connected
      pool.shutdown
      expect(pool).not_to be_connected
    end
  end
end
