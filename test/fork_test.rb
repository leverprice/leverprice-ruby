# frozen_string_literal: true

require_relative "test_helper"

class ForkTest < Minitest::Test
  include TestHelpers

  def setup
    skip "fork is not available on this platform" unless Process.respond_to?(:fork)

    @signer = Signer.new
    @envelope = @signer.envelope
  end

  def in_child
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      result = begin
        yield
      rescue StandardError => e
        { "error" => "#{e.class}: #{e.message}" }
      end
      writer.write(JSON.generate(result))
      writer.close
      exit!(0)
    end
    writer.close
    output = reader.read
    Process.wait(pid)
    JSON.parse(output)
  end

  def test_child_never_resends_the_parent_queue
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport)
    client.get_price("pro", request: browser)

    assert_equal 1, client.instance_variable_get(:@queue).size

    child = in_child do
      queued = client.instance_variable_get(:@queue).size
      client.flush
      { "queued" => queued, "sent" => transport.events.size }
    end

    assert_equal({ "queued" => 0, "sent" => 0 }, child)

    client.flush

    assert_equal 1, transport.events.size
  end

  def test_child_does_not_wait_for_the_parents_inflight_fetch
    parent = Process.pid
    release = Queue.new
    envelope = @envelope
    transport = FakeTransport.new(config: lambda { |_call|
      release.pop if Process.pid == parent
      [200, { "ETag" => '"v1"' }, JSON.generate(envelope)]
    })
    client = build_client(transport: transport, timeout_ms: 2_000)
    Thread.new { client.preload }
    wait_until { transport.config_calls.size == 1 }

    child = in_child do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      quote = client.get_price("pro", request: browser)
      { "reason" => quote.reason, "seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    end

    assert_equal "experiment", child["reason"]
    assert_operator child["seconds"], :<, 1.0
  ensure
    release&.close
  end

  def test_background_flush_thread_is_recreated_in_the_child
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport, flush_interval_ms: 20)
    client.get_price("pro", request: browser, user_id: "parent")
    wait_until { transport.events.size == 1 }

    child = in_child do
      client.get_price("pro", request: browser, user_id: "child")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      sleep 0.01 until transport.events.size == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      { "sent" => transport.events.size }
    end

    assert_equal({ "sent" => 2 }, child)
  end

  def test_lazy_pid_check_resets_state_without_the_fork_hook
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport)
    client.get_price("pro", request: browser)
    client.instance_variable_set(:@pid, -1)

    client.flush

    assert_empty transport.event_calls
    assert_equal Process.pid, client.instance_variable_get(:@pid)
  end
end
