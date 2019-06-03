require 'spec_helper'

describe NationBuilder::Client do
  let(:client) do
    NationBuilder::Client.new('organizeralexandreschmitt',
                              '03c22256c06ed11f6bee83673addf26e02a86caa1a5127f4e0815be7223fe4a3',
                              retries: 1)
  end

  describe '#initialize' do
    describe 'with a provided httpclient' do
      let(:httpclient) { double('HTTPClient') }

      subject { described_class.new('slug', 'token', http_client: httpclient) }

      it 'uses the provided client instead of a new one' do
        expect(subject.instance_variable_get(:@http_client)).to be(httpclient)
      end
    end
  end

  describe '#endpoints' do
    it 'should contain all defined endpoints' do
      expect(client.endpoints.sort).to eq(%i[
                                            basic_pages
                                            blog_posts
                                            blogs
                                            calendars
                                            campaign_data
                                            contact_types
                                            contacts
                                            donations
                                            events
                                            exports
                                            imports
                                            lists
                                            memberships
                                            page_attachments
                                            paths
                                            people
                                            people_tags
                                            precincts
                                            sites
                                            survey_responses
                                            surveys
                                            webhooks
                                          ])
    end
  end

  describe '#base_url' do
    it 'should contain the nation slug' do
      expect(client.base_url).to eq('https://organizeralexandreschmitt.nationbuilder.com')
    end
  end

  describe '#call' do
    it 'should handle a parametered GET' do
      VCR.use_cassette('parametered_get') do
        response = client.call(:basic_pages, :index, site_slug: 'organizeralexandreschmitt', limit: 11)
        expect(client.response.status).to eq(200)
        response['results'].each do |result|
          expect(result['site_slug']).to eq('organizeralexandreschmitt')
        end
      end
    end

    it 'should handle a parametered POST' do
      params = {
        person: {
          email: 'bob@example.com',
          last_name: 'Smith',
          first_name: 'Bob'
        }
      }

      response = VCR.use_cassette('parametered_post') do
        client.call(:people, :create, params)
      end

      expect(client.response.status).to eq(201)
      expect(response['person']['first_name']).to eq('Bob')
    end

    context 'errored request' do
      it 'sets the response on the client' do
        VCR.use_cassette('errored_get') do
          expect do
            client.call(:people, :show, id: 0)
          end.to raise_error(NationBuilder::ClientError)
          expect(client.response.status).to eq(404)
        end
      end
    end

    context 'fire_webhooks' do
      it 'should disable webhooks' do
        params = {
          fire_webhooks: false,
          person: {
            email: 'bob@example.com',
            last_name: 'Smith',
            first_name: 'Bob'
          }
        }

        expect(client).to receive(:perform_request_with_retries) do |_, _, request_args|
          expect(request_args[:query][:fire_webhooks]).to be_falsey
        end

        client.call(:people, :create, params)
      end

      it 'should not be included if not specified' do
        params = {
          person: {
            email: 'bob@example.com',
            last_name: 'Smith',
            first_name: 'Bob'
          }
        }

        expect(client).to receive(:perform_request_with_retries) do |_, _, request_args|
          expect(request_args[:query].include?(:fire_webhooks)).to be_falsey
        end

        client.call(:people, :create, params)
      end
    end

    it 'should handle a DELETE' do
      params = {
        id: 278_881
      }

      response = VCR.use_cassette('delete') do
        client.call(:people, :destroy, params)
      end

      expect(response).to eq(true)
    end
  end

  describe '#classify_response_error' do
    it 'should account for rate limits' do
      response = double(code: 429, body: 'rate limiting')
      expect(client.classify_response_error(response).class)
        .to eq(NationBuilder::RateLimitedError)
    end
    it 'should account for client errors' do
      response = double(code: 404, body: '404ing')
      expect(client.classify_response_error(response).class)
        .to eq(NationBuilder::ClientError)
    end
    it 'should account for client errors' do
      response = double(code: 500, body: '500ing')
      expect(client.classify_response_error(response).class)
        .to eq(NationBuilder::ServerError)
    end
  end

  describe '#perform_request_with_retries' do
    let(:httpclient) { double('HTTPClient') }

    before do
      allow(HTTPClient).to receive(:new).and_return(httpclient)
    end

    it 'should reraise non-rate limiting execeptions' do
      expect(httpclient).to receive(:send)
      expect(client).to receive(:parse_response_body) { raise StandardError, 'boom' }
      expect do
        client.perform_request_with_retries(nil, nil, nil)
      end.to raise_error(StandardError)
    end

    it 'should return a response if the rate limit is eventually dropped' do
      expect(httpclient).to receive(:send).twice
      expect(Kernel).to receive(:sleep)

      allow(client).to receive(:parse_response_body) do
        if @count
          @count += 1
        else
          @count ||= 0
        end

        raise NationBuilder::RateLimitedError if @count < 1
      end

      expect do
        client.perform_request_with_retries(nil, nil, nil)
      end.to_not raise_error
    end

    it 'on the last retry, it should reraise the rate limiting exception ' do
      expect(httpclient).to receive(:send).twice
      expect(Kernel).to receive(:sleep).twice

      allow(client).to receive(:parse_response_body) do
        raise NationBuilder::RateLimitedError
      end

      expect do
        client.perform_request_with_retries(nil, nil, nil)
      end.to raise_error(NationBuilder::RateLimitedError)
    end
  end
end
