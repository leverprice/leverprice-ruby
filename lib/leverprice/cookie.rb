# frozen_string_literal: true

module Leverprice
  # @api private
  module Cookie
    MAX_EXPERIMENTS = 10
    MAX_LENGTH = 4096
    VISITOR_KEY_RE = /\A[0-9a-f]{32}\z/
    BODY_RE = /\A[A-Za-z0-9_-]+\z/
    SIG_RE = /\A[A-Za-z0-9_-]{22}\z/

    State = Struct.new(:v, :a, :x)

    module_function

    def new_state(visitor_key)
      State.new(visitor_key, {}, [])
    end

    def clone_state(state)
      State.new(state.v, state.a.dup, state.x.dup)
    end

    def assign(state, experiment_id, variant_id)
      rest = state.a.reject { |id, _| id == experiment_id }
      state.a = { experiment_id => variant_id }.merge(rest).first(MAX_EXPERIMENTS).to_h
      state.x = state.x.select { |id| state.a.key?(id) }
    end

    def mark_exposed(state, experiment_id)
      return false if state.x.include?(experiment_id)

      state.x = [experiment_id, *state.x].select { |id| state.a.key?(id) }.first(MAX_EXPERIMENTS)
      true
    end

    def serialize(state)
      JSON.generate({ "v" => state.v, "a" => state.a, "x" => state.x })
    end

    def sign(key, state)
      body = Util.b64url_encode(serialize(state))
      "#{body}.#{Util.b64url_encode(Util.hmac(key, "pp:cookie:v1:#{body}")[0, 16])}"
    end

    def verify(key, raw)
      return nil unless raw.is_a?(String)

      raw = Util.utf8(raw)
      return nil if raw.length > MAX_LENGTH

      dot = raw.index(".")
      return nil if dot.nil? || dot.zero?

      body = raw[0, dot]
      sig = raw[(dot + 1)..]
      return nil unless BODY_RE.match?(body) && SIG_RE.match?(sig)
      return nil unless Util.secure_equal?(Util.hmac(key, "pp:cookie:v1:#{body}")[0, 16], Util.b64url_decode(sig))

      normalize(Util.decode_json_b64(body))
    rescue StandardError
      nil
    end

    def normalize(raw)
      return nil unless raw.is_a?(Hash) && Util.str_match?(VISITOR_KEY_RE, raw["v"]) && raw["a"].is_a?(Hash)

      assignments = {}
      raw["a"].first(MAX_EXPERIMENTS).each do |experiment_id, variant_id|
        assignments[experiment_id] = variant_id if Util.id?(experiment_id) && Util.id?(variant_id)
      end
      exposed = raw["x"].is_a?(Array) ? raw["x"].select { |id| id.is_a?(String) && assignments.key?(id) } : []
      State.new(raw["v"], assignments, exposed.first(MAX_EXPERIMENTS))
    end

    def header(name, value, max_age, secure:, domain:)
      parts = ["#{name}=#{value}", "Path=/", "Max-Age=#{max_age}", "SameSite=Lax", "HttpOnly"]
      parts << "Secure" if secure
      parts << "Domain=#{domain}" if domain && !domain.to_s.empty?
      parts.join("; ")
    end
  end
end
