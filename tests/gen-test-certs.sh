#!/usr/bin/env sh
# Generates a throwaway CA and leaf certificates for the transport tests,
# into the directory given as $1. Nothing produced here is ever committed;
# run this at test time, into a gitignored scratch directory.
#
# Produces:
#   ca.pem                        the test CA certificate (no key kept around)
#   server.pem / server-key.pem   SAN=DNS:localhost,DNS:mailbend.test, CA-signed
#   ip-address.pem / -key.pem     SAN=IP:127.0.0.1,IP:::1, CA-signed, valid
#   wronghost.pem / -key.pem      SAN=DNS:not-localhost.invalid, CA-signed, valid
#   expired.pem / -key.pem        SAN=DNS:localhost, CA-signed, validity in the past
#   selfsigned.pem / -key.pem     SAN=DNS:localhost, NOT CA-signed
#   typesafe.pem / -key.pem       SAN=DNS:api.typesafe.ai, CA-signed, for the fake
#                                 TypeSafe service (tests/fake_typesafe.py)
set -eu

outdir="${1:?usage: gen-test-certs.sh OUTDIR}"
mkdir -p "$outdir"
cd "$outdir"

gen_key() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null
}

# --- throwaway CA ---
gen_key ca-key.pem
openssl req -x509 -new -key ca-key.pem -days 2 -out ca.pem \
  -subj "/CN=MailBend Test CA" 2>/dev/null

# CA-signed leaf with the given SAN and validity (in days from now; a
# negative value back-dates notAfter before notBefore, i.e. already expired).
gen_leaf() {
  name="$1"; san="$2"; days="$3"
  gen_key "${name}-key.pem"
  openssl req -new -key "${name}-key.pem" -out "${name}.csr" \
    -subj "/CN=${name}" 2>/dev/null
  printf 'subjectAltName=%s\n' "$san" > "${name}.ext"
  openssl x509 -req -in "${name}.csr" -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
    -days "$days" -out "${name}.pem" \
    -extfile "${name}.ext" 2>/dev/null
  rm -f "${name}.csr" "${name}.ext"
}

gen_leaf server "DNS:localhost,DNS:mailbend.test" 2
gen_leaf ip-address "IP:127.0.0.1,IP:::1" 2
gen_leaf wronghost "DNS:not-localhost.invalid" 2
gen_leaf expired "DNS:localhost" -1
gen_leaf typesafe "DNS:api.typesafe.ai" 2

# self-signed (not CA-signed at all)
gen_key selfsigned-key.pem
openssl req -x509 -new -key selfsigned-key.pem -days 2 -out selfsigned.pem \
  -subj "/CN=selfsigned" -addext "subjectAltName=DNS:localhost" 2>/dev/null

# The CA key is only needed to sign the leaves above.
rm -f ca-key.pem ca.srl
