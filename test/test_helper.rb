# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "leverprice"
require "minitest/autorun"
require_relative "support/fake_transport"
require_relative "support/signer"

module Vectors
  module_function

  def path
    dir = __dir__
    loop do
      candidate = File.join(dir, "conformance", "vectors.json")
      return candidate if File.file?(candidate)

      parent = File.dirname(dir)
      raise "conformance/vectors.json not found above #{__dir__}" if parent == dir

      dir = parent
    end
  end

  def data
    @data ||= JSON.parse(File.read(path, encoding: "UTF-8"))
  end
end

class TestClock
  attr_reader :now

  def initialize(now = 1_800_000_000_000)
    @now = now
  end

  def call
    @now
  end

  def advance(millis)
    @now += millis
  end
end

module TestHelpers
  SECRET_KEY = "pp_sk_test_0123456789abcdefghijABCDEFGHIJ0123456789"
  CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " \
           "Chrome/142.0.0.0 Safari/537.36"
  PIN = "__pp_f=1; Path=/; Max-Age=1800; SameSite=Lax; HttpOnly; Secure"
  PRODUCTS = {
    "pro" => { currency: "usd", fallback_price: 1900, min_price: 1000, max_price: 5000 },
    "team" => { currency: "usd", fallback_price: 4900, min_price: 1000, max_price: 9000 },
    "basic" => { currency: "usd", fallback_price: 1000 }
  }.freeze

  def errors
    @errors ||= []
  end

  def build_client(transport:, signer: nil, **options)
    Leverprice::Client.new(
      secret_key: SECRET_KEY,
      products: PRODUCTS,
      trusted_root_keys: (signer || @signer).root_keys,
      transport: transport,
      on_error: ->(e) { errors << e.message },
      sleeper: ->(_seconds) {},
      flush_interval_ms: 60_000,
      **options
    )
  end

  def browser(extra = {})
    { "user-agent" => CHROME }.merge(extra)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def cookie_state(set_cookie)
    value = set_cookie.split(";").first.split("=", 2).last
    JSON.parse(Leverprice::Util.text(Leverprice::Util.b64url_decode(value.split(".").first)))
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise Minitest::Assertion,
              "condition not met within #{timeout}s"
      end

      sleep 0.005
    end
  end

  def wait_idle(client)
    wait_until { client.instance_variable_get(:@inflight).nil? }
  end

  def with_env(name, value)
    previous = ENV.fetch(name, nil)
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    previous.nil? ? ENV.delete(name) : ENV[name] = previous
  end
end
