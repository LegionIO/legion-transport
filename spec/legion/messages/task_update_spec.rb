# frozen_string_literal: true

require 'spec_helper'
require 'legion/transport/messages/task_update'

RSpec.describe Legion::Transport::Messages::TaskUpdate do
  it 'rejects a missing or invalid logical task identifier before publication' do
    expect { described_class.new(task_id: nil, status: 'task.completed') }.to raise_error(Legion::Exception::InvalidTaskId)
    expect { described_class.new(task_id: 0, status: 'task.completed') }.to raise_error(Legion::Exception::InvalidTaskId)
  end

  it 'rejects an unconfigured status instead of publishing an unknown transition' do
    expect { described_class.new(task_id: 9, status: 'invalid.transition') }.to raise_error(Legion::Exception::InvalidTaskStatus)
  end
end
