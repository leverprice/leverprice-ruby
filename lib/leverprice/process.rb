# frozen_string_literal: true

module Leverprice
  # Pre-forking servers copy clients into children: reset their threads, locks and queues there.
  # @api private
  module ForkTracker
    @clients = ObjectSpace::WeakMap.new
    @registry_lock = Mutex.new
    @lock = Mutex.new
    @count = 0

    class << self
      attr_reader :lock

      def register(client)
        @registry_lock.synchronize do
          @clients[client] = true
          @count += 1
        end
      end

      def after_fork
        @registry_lock = Mutex.new
        @lock = Mutex.new
        @clients.each_key(&:after_fork)
      rescue StandardError
        nil
      end
    end

    # @api private
    module Hook
      def _fork
        pid = super
        ForkTracker.after_fork if pid.zero?
        pid
      end
    end

    Process.singleton_class.prepend(Hook) if Process.respond_to?(:_fork)
  end
end
