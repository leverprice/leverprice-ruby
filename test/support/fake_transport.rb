# frozen_string_literal: true

class FakeTransport
  Call = Struct.new(:http_method, :url, :headers, :body, keyword_init: true)

  attr_accessor :config_handler, :events_handler

  def initialize(config: nil, events: nil)
    @calls = []
    @mutex = Mutex.new
    @config_handler = config || ->(_call) { [503, {}, ""] }
    @events_handler = events || ->(_call) { [202, {}, "{}"] }
  end

  def call(method:, url:, headers:, body:, timeout:)
    raise ArgumentError, "timeout must be positive" unless timeout.positive?

    call = Call.new(http_method: method, url: url, headers: headers, body: body)
    @mutex.synchronize { @calls << call }
    handler = url.end_with?("/v1/config") ? config_handler : events_handler
    handler.call(call)
  end

  def calls
    @mutex.synchronize { @calls.dup }
  end

  def config_calls
    calls.select { |c| c.url.end_with?("/v1/config") }
  end

  def event_calls
    calls.select { |c| c.url.end_with?("/v1/events") }
  end

  def events
    event_calls.flat_map { |c| JSON.parse(c.body)["events"] }
  end

  def self.serving(envelope, etag: '"v1"', headers: {})
    new(config: ->(_call) { [200, { "ETag" => etag }.merge(headers), JSON.generate(envelope)] })
  end
end
