# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"
require "socket"

class TransportTest < Minitest::Test
  include TestHelpers

  def serve_once(status:, headers:, body:)
    server = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    thread = Thread.new do
      socket = server.accept
      head = +""
      head << socket.readpartial(65_536) until head.include?("\r\n\r\n")
      received << head
      socket.write("HTTP/1.1 #{status} OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n")
      headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
      socket.write("\r\n#{body}")
      socket.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}", received
  ensure
    thread&.join(2)
    server&.close
  end

  def test_net_http_transport_round_trip
    serve_once(status: 200, headers: { "ETag" => '"v1"', "Leverprice-Config-Version" => "7" },
               body: '{"ok":true}') do |url, received|
      response = Leverprice::NetHTTPTransport.new.call(
        method: "GET", url: "#{url}/v1/config", headers: { "Authorization" => "Bearer x", "User-Agent" => "ua" },
        timeout: 2
      )

      assert_equal 200, response.status
      assert_equal '"v1"', response.header("etag")
      assert_equal "7", response.header("Leverprice-Config-Version")
      assert_equal '{"ok":true}', response.body
      head = received.pop

      assert_match(%r{\AGET /v1/config HTTP/1\.1\r\n}, head)
      assert_match(/^Authorization: Bearer x\r$/i, head)
      refute_match(/^Origin:/i, head)
    end
  end

  def test_client_over_net_http_reports_http_errors
    serve_once(status: 503, headers: {}, body: '{"error":{"code":"maintenance"}}') do |url, _received|
      client = Leverprice::Client.new(secret_key: SECRET_KEY, products: PRODUCTS, api_url: url,
                                      on_error: ->(e) { errors << e.message })

      assert_equal "no_config", client.get_price("pro").reason
      assert_includes errors, "Leverprice config: HTTP 503 (maintenance)"
    end
  end

  def test_background_threads_do_not_keep_the_process_alive
    script = <<~RUBY
      require "leverprice"
      hang = ->(**) { sleep }
      client = Leverprice::Client.new(secret_key: "#{SECRET_KEY}", products: { "pro" => { currency: "usd", fallback_price: 1 } },
                                      transport: hang, timeout_ms: 50, on_error: ->(_) {})
      client.get_price("pro")
      Thread.new { client.track_refund(provider: "stripe", order_id: "x", currency: "usd", refunded_total: 1) }
      sleep 0.1
      puts "done"
    RUBY
    lib = File.expand_path("../lib", __dir__)
    started = monotonic
    output = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: File::NULL, &:read)

    assert_equal "done\n", output
    assert_operator monotonic - started, :<, 5
  end
end
