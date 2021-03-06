require "harness"
require "spec_helper"
require "logs-cf-plugin/plugin"

include BVT::Spec

describe "Tools::Loggregator" do

  before(:all) do
    @session = BVT::Harness::CFSession.new
    @app = create_push_app('node0_6', '', nil, [], true)
  end

  after(:all) do
    @session.cleanup!
  end

  let(:loggregator_io) { StringIO.new }
  let(:loggregator_client) { LogsCfPlugin::LoggregatorClient.new(loggregator_host, cf_client.token.auth_header, loggregator_io, false) }
  let(:cf_client) { @session.client }

  def loggregator_host
    target_base = @session.api_endpoint.sub(/^https?:\/\/([^\.]+\.)?(.+)\/?/, '\2')
    "loggregator.#{target_base}"
  end

  it "can tail app logs" do
    @app.start

    th = Thread.new do
      loggregator_client.listen(:app => @app.guid)
    end

    # It takes couple of seconds for loggregator to send data to client
    Timeout.timeout(10) do
      until loggregator_io.string =~ /STDOUT/
        @app.get('/logs')
        sleep(0.5)
      end
    end

    Thread.kill(th)

    output_lines = loggregator_io.string.split("\n")
    expect(output_lines).to include(match /Connected to server/)
    expect(output_lines).to include(match /(\w+-){4}\w+\s+STDOUT stdout log/)
    expect(output_lines).to include(match /(\w+-){4}\w+\s+STDERR stderr log/)
  end
end