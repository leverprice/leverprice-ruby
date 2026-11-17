# frozen_string_literal: true

require_relative "lib/leverprice/version"

Gem::Specification.new do |spec|
  spec.name = "leverprice"
  spec.version = Leverprice::VERSION
  spec.authors = ["Leverprice"]
  spec.summary = "Server-side SDK for Leverprice price experiments"
  spec.description = "Signed, fail-safe price experiments for SaaS checkouts: verified configs, sticky assignments, " \
                     "exposure logging and purchase attribution. Zero runtime dependencies."
  spec.homepage = "https://leverprice.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => "https://leverprice.com",
    "source_code_uri" => "https://github.com/leverprice/leverprice-ruby",
    "documentation_uri" => "https://leverprice.com/docs",
    "changelog_uri" => "https://github.com/leverprice/leverprice-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/leverprice/leverprice-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob("lib/**/*.rb", base: __dir__).sort + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
