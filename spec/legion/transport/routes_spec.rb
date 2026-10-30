# frozen_string_literal: true

require 'spec_helper'
require 'sinatra/base'
require 'rack/mock'

RSpec.describe Legion::Transport::Routes do
  let(:app) do
    Class.new(Sinatra::Base) do
      set :environment, :test
      set :host_authorization, permitted: :any
      register Legion::Transport::Routes
    end
  end
  let(:publisher) { instance_double(Legion::Transport::Messages::Direct, publish: outcome) }
  let(:request_body) { Legion::JSON.dump({ exchange: 'task', routing_key: 'worker.run', payload: { value: 1 } }) }

  before do
    allow(Legion::Transport::Messages::Direct).to receive(:new).and_return(publisher)
  end

  [
    [:accepted, true, 201],
    [:spooled, false, 202],
    [:unroutable, false, 422],
    [:confirm_timeout, false, 504],
    [:failed, false, 503]
  ].each do |publish_status, accepted, http_status|
    context "when publication is #{publish_status}" do
      let(:outcome) { { status: publish_status, accepted: accepted } }

      it 'reports the actual delivery outcome to the client' do
        response = Rack::MockRequest.new(app).post('/api/transport/publish',
                                                   'CONTENT_TYPE' => 'application/json', input: request_body)
        expect(response.status).to eq(http_status)
        expect(Legion::JSON.load(response.body).fetch(:data)).to include(
          status: publish_status.to_s, published: accepted, accepted: accepted,
          exchange: 'task', routing_key: 'worker.run'
        )
      end
    end
  end

  context 'when the publisher returns no delivery result' do
    let(:outcome) { nil }

    it 'does not acknowledge an unknown outcome as published' do
      response = Rack::MockRequest.new(app).post('/api/transport/publish',
                                                 'CONTENT_TYPE' => 'application/json', input: request_body)
      expect(response.status).to eq(500)
      expect(Legion::JSON.load(response.body)).to include(error: include(code: 'publish_error'))
    end
  end
end
