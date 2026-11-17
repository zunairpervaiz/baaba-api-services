# Test-only TLS material

A throwaway CA and a `localhost`/`127.0.0.1` server certificate signed by it,
used by the pinning and proxy tests to run a real TLS handshake. The CA's
private key was discarded after signing. `other_ca.pem` is an unrelated CA, for
the "does not chain to the pinned roots" cases. Never trust any of these
outside the tests.

Regenerate with openssl (100-year validity) if they are ever lost.
