# frozen_string_literal: true

module Leverprice
  # @api private
  class TrustChain
    ROOT_KEY_PLACEHOLDER = "REPLACE_WITH_ROOT_PUBLIC_KEY"
    MAX_CACHED_KEYSETS = 8

    SigningKey = Struct.new(:id, :public_key)
    Keyset = Struct.new(:version, :issued_at, :expires_at, :keys, keyword_init: true)
    Verified = Struct.new(:config, :signing_key, :dropped)

    def initialize(root_keys, min_keyset_version)
      @root_keys = root_keys.to_h.transform_keys(&:to_s).freeze
      @min_keyset_version = min_keyset_version
      @newest = nil
      @verified = {}
    end

    def keyset_version
      @newest ? @newest.version : 0
    end

    def trusted?(signing_key)
      newest = @newest
      newest.nil? || newest.keys.any? { |k| k.id == signing_key.id && k.public_key == signing_key.public_key }
    end

    def verify(envelope, now)
      unless envelope.is_a?(Hash) && envelope["payload"].is_a?(String) && envelope["signature"].is_a?(String) &&
             envelope["keyId"].is_a?(String)
        raise ConfigError.new("malformed", "Leverprice config: response is not a signed config")
      end

      keyset = coded("untrusted") { verify_keyset(envelope["keyset"], now) }
      key_id = envelope["keyId"]
      key = keyset.keys.find { |k| k.id == key_id }
      unless key
        raise ConfigError.new("bad_signature",
                              %(Leverprice config: signing key "#{key_id}" is not in keyset v#{keyset.version}))
      end
      unless Util.ed25519_verify(key.public_key, envelope["signature"], envelope["payload"])
        raise ConfigError.new("bad_signature", %(Leverprice config: bad signature (key "#{key_id}")))
      end

      config, dropped = coded("malformed") { Wire.parse_config(envelope["payload"]) }
      if now >= config.expires_at
        raise ConfigError.new("expired",
                              "Leverprice config v#{config.version}: expired at #{Util.iso_time(config.expires_at)}")
      end

      Verified.new(config, SigningKey.new(key.id, key.public_key), dropped)
    end

    private

    def coded(code)
      yield
    rescue ConfigError
      raise
    rescue StandardError => e
      raise ConfigError.new(code, e.message)
    end

    def verify_keyset(signed, now)
      unless signed.is_a?(Hash) && signed["payload"].is_a?(String) && signed["signature"].is_a?(String) &&
             signed["rootKeyId"].is_a?(String)
        raise Error, "Leverprice keyset: missing or malformed"
      end

      keyset = @verified[signed["payload"]] || load_keyset(signed)
      check_keyset(keyset, now)
      @newest = keyset if @newest.nil? || keyset.version > @newest.version
      keyset
    end

    def load_keyset(signed)
      root_key_id = signed["rootKeyId"]
      root = @root_keys[root_key_id]
      if root.nil? || root == false || root == ""
        raise Error, %(Leverprice keyset: root key "#{root_key_id}" is not trusted by this SDK)
      end
      if root == ROOT_KEY_PLACEHOLDER
        raise Error, "Leverprice: this SDK build has no root public key (ROOT_PUBLIC_KEYS is a placeholder); " \
                     "pass trusted_root_keys"
      end
      unless Util.ed25519_verify(root, signed["signature"], signed["payload"])
        raise Error, %(Leverprice keyset: signature does not match root key "#{root_key_id}")
      end

      keyset = parse_keyset(signed["payload"])
      @verified.clear if @verified.size >= MAX_CACHED_KEYSETS
      @verified[signed["payload"]] = keyset
    end

    def check_keyset(keyset, now)
      raise Error, "Leverprice keyset v#{keyset.version}: expired" if keyset.expires_at && now >= keyset.expires_at
      if keyset.version < @min_keyset_version
        raise Error, "Leverprice keyset v#{keyset.version}: below the minimum version #{@min_keyset_version}"
      end
      return unless @newest && keyset.version < @newest.version

      raise Error, "Leverprice keyset v#{keyset.version}: older than v#{@newest.version} already seen " \
                   "(revoked keys cannot come back)"
    end

    def parse_keyset(payload)
      raw = begin
        Util.decode_json_b64(payload)
      rescue StandardError
        raise Error, "Leverprice keyset: payload is not base64url JSON"
      end
      version = raw.is_a?(Hash) ? Util.safe_int(raw["version"]) : nil
      unless raw.is_a?(Hash) && raw["schema"] == 1 && version && raw["keys"].is_a?(Array)
        raise Error, "Leverprice keyset: unsupported schema"
      end

      keys = raw["keys"].filter_map do |k|
        if k.is_a?(Hash) && k["id"].is_a?(String) && k["publicKey"].is_a?(String)
          SigningKey.new(k["id"],
                         k["publicKey"])
        end
      end
      Keyset.new(
        version: version,
        issued_at: Util.number?(raw["issuedAt"]) ? raw["issuedAt"] : 0,
        expires_at: Util.number?(raw["expiresAt"]) ? raw["expiresAt"] : nil,
        keys: keys
      )
    end
  end

  # @api private
  class Acceptance
    Loaded = Struct.new(:config, :signing_key)
    Result = Struct.new(:config, :dropped, :warning)

    attr_reader :loaded

    def initialize(trust, secret_key)
      @trust = trust
      @fingerprint = OpenSSL::Digest::SHA256.hexdigest(secret_key.to_s)[0, 16]
      @loaded = nil
    end

    def config
      @loaded&.config
    end

    def accept(envelope, now)
      verified = @trust.verify(envelope, now)
      config = verified.config
      # A validly signed config of another project (e.g. from a compromised cache) is refused even on first load.
      unless config.key_fingerprints.include?(@fingerprint)
        raise ConfigError.new("wrong_key", "Leverprice config: not issued for this API key; refusing")
      end

      current = self.config
      if current && config.project_id != current.project_id
        raise ConfigError.new("wrong_project", "Leverprice config: project changed from #{current.project_id} " \
                                               "to #{config.project_id}; refusing")
      end
      if current && config.version < current.version
        raise ConfigError.new("rollback", "Leverprice config: refusing to roll back from version " \
                                          "#{current.version} to #{config.version}")
      end

      warning = nil
      if verified.dropped.any? && config.version != current&.version
        warning = "Leverprice config v#{config.version}: ignored malformed products #{verified.dropped.join(", ")}"
      end
      @loaded = Loaded.new(config, verified.signing_key)
      Result.new(config, verified.dropped, warning)
    end
  end
end
