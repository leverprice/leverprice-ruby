# frozen_string_literal: true

module Leverprice
  # User-agent detection of crawlers, link previewers, headless browsers, monitors and HTTP tools.
  module Bots
    PATTERNS = [
      "(?<!cu)bot(?![a-z])",
      "crawl",
      "spider",
      "scrap",
      "slurp",
      "archiver",
      "fetcher",
      "\\+https?:",
      "facebookexternalhit",
      "facebookcatalog",
      "meta-external",
      "whatsapp/",
      "skypeuripreview",
      "bingpreview",
      "microsoftpreview",
      "link ?preview",
      "url preview",
      "web preview",
      "slack-imgproxy",
      "vkshare",
      "embedly",
      "iframely",
      "cardyb",
      "outbrain",
      "flipboardproxy",
      "mediapartners-google",
      "apis-google",
      "duplexweb-google",
      "google-(?:inspectiontool|site-verification|read-aloud|pagerenderer|structured-data|safety)",
      "googleother",
      "googleproducer",
      "google favicon",
      "chatgpt-user",
      "claude-user",
      "perplexity-user",
      "mistralai-user",
      "anthropic-ai",
      "cohere-ai",
      "daumoa",
      "ahrefs",
      "sitebulb",
      "siteimprove",
      "barkrowler",
      "botify",
      "seokicks",
      "validator",
      "checklink",
      "heritrix",
      "headless",
      "phantomjs",
      "slimerjs",
      "htmlunit",
      "jsdom",
      "cypress",
      "lighthouse",
      "page ?speed",
      "gtmetrix",
      "ptst/",
      "pingdom",
      "uptime",
      "statuscake",
      "site24x7",
      "newrelicpinger",
      "synthetic",
      "checkly",
      "health-?check",
      "googlehc",
      "kube-probe",
      "nagios",
      "zabbix",
      "catchpoint",
      "freshping",
      "hetrixtools",
      "ohdear",
      "monitoring",
      "curl",
      "wget",
      "httpie",
      "python-requests",
      "python-urllib",
      "python-httpx",
      "aiohttp",
      "go-http-client",
      "\\Ajava/",
      "apache-httpclient",
      "libwww-perl",
      "lwp::",
      "guzzlehttp",
      "postmanruntime",
      "insomnia",
      "axios/",
      "node-fetch",
      "undici"
    ].freeze

    # Matched against the ASCII-lowercased user agent: case folding is ASCII-only on every platform.
    PATTERN = Regexp.new(PATTERNS.join("|"))

    module_function

    # @param user_agent [String, nil]
    # @return [Boolean] true for known bots; an empty or missing user agent is a person.
    def bot?(user_agent)
      return false unless user_agent.is_a?(String)

      agent = Util.trim(user_agent)
      !agent.empty? && PATTERN.match?(agent.downcase(:ascii))
    end
  end
end
