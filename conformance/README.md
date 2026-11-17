# Leverprice SDK conformance vectors

`vectors.json` is generated from the Leverprice server's own signing and HMAC code and the
reference JavaScript SDK, with fixed test keys. Every Leverprice SDK (JavaScript, Python, PHP,
Ruby, Go) runs its test suite against this exact file, so they all verify configs, sign cookies,
hash visitors, bucket them, detect bots and validate events identically.

`SPEC.md` describes the protocol and the behaviour every SDK implements, and section 12 explains
each part of the vectors file. Want an SDK for another language? Implement the spec and pass the
vectors.

The keys in this file are test keys. Nothing here is secret.
