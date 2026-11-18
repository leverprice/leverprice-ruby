# frozen_string_literal: true

class Signer
  FAR_FUTURE = 4_102_444_800_000
  ASSIGNMENT_KEY = Leverprice::Util.b64url_encode("k" * 32)

  attr_reader :root_keys

  def initialize
    @root = OpenSSL::PKey.generate_key("ED25519")
    @signing = OpenSSL::PKey.generate_key("ED25519")
    @root_keys = { "r1" => raw_public(@root) }
  end

  def keyset(version: 1)
    payload = b64(JSON.generate(schema: 1, version: version, issuedAt: 0, expiresAt: nil,
                                keys: [{ id: "k1", publicKey: raw_public(@signing) }]))
    { "payload" => payload, "signature" => b64(@root.sign(nil, payload)), "rootKeyId" => "r1" }
  end

  def envelope(version: 1, products: self.class.products, secret_key: TestHelpers::SECRET_KEY, **fields)
    config = {
      schema: 2,
      projectId: "proj_test",
      version: version,
      issuedAt: 0,
      expiresAt: FAR_FUTURE,
      assignmentKey: ASSIGNMENT_KEY,
      keyFingerprints: [OpenSSL::Digest::SHA256.hexdigest(secret_key)[0, 16]],
      products: products
    }.merge(fields)
    payload = b64(JSON.generate(config))
    { "payload" => payload, "signature" => b64(@signing.sign(nil, payload)), "keyId" => "k1", "keyset" => keyset }
  end

  def self.products(price: 900)
    {
      "pro" => {
        "id" => "prod_pro", "currency" => "usd", "price" => 2400, "minPrice" => 1000, "maxPrice" => 5000,
        "experiment" => {
          "id" => "exp_A", "salt" => "a",
          "variants" => [{ "id" => "var_1", "price" => 1900, "weight" => 5000 },
                         { "id" => "var_2", "price" => 2900, "weight" => 5000 }]
        }
      },
      "team" => {
        "id" => "prod_team", "currency" => "usd", "price" => 4900, "minPrice" => 1000, "maxPrice" => 9000,
        "experiment" => {
          "id" => "exp_B", "salt" => "b",
          "variants" => [{ "id" => "var_x", "price" => 4900, "weight" => 5000 },
                         { "id" => "var_y", "price" => 5900, "weight" => 5000 }]
        }
      },
      "basic" => { "id" => "prod_basic", "currency" => "usd", "price" => price, "minPrice" => 100, "maxPrice" => 5000 }
    }
  end

  def self.regional_products
    regions = [{ "countries" => %w[IN], "currency" => "inr", "price" => 99_900 },
               { "countries" => %w[BR MX], "currency" => "usd", "price" => 1500 }]
    base = products
    variants = base["pro"]["experiment"]["variants"]
    base["pro"]["regions"] = regions
    base["basic"]["regions"] = regions
    variants[0]["regional"] = [64_900, 1300]
    variants[1]["regional"] = [129_900, 2100]
    base
  end

  private

  def raw_public(key)
    b64(key.public_to_der[-32..])
  end

  def b64(bytes)
    Leverprice::Util.b64url_encode(bytes)
  end
end
