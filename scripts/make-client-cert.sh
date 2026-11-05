#!/usr/bin/env bash
# Make a client CA (once) and one device certificate as .p12, for mutual TLS at Caddy (D-003, PLAN 1.10).
# Usage: scripts/make-client-cert.sh [--dry-run] [--out DIR] <device-name>
#   --out DIR   output folder (default: secrets/client-ca, which git ignores)
#   --dry-run   print the OpenSSL commands and do nothing
# The CA key stays in DIR. The .p12 passphrase is random, printed once to stderr, and not stored.
# Keys are EC P-256 with named-curve encoding and SHA-256 signatures; Apple platforms reject
# explicit curve parameters and SHA-1. The .p12 uses PBE-SHA1-3DES for import on iOS (verify on
# each iOS release).
set -euo pipefail

DRY=0
OUT="secrets/client-ca"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n 2,10p "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
DEVICE="${1:-}"
if ! [[ "$DEVICE" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
  echo "device name must be lowercase letters, digits and dashes, at most 63 characters" >&2
  exit 2
fi

run() {
  if [ "$DRY" = 1 ]; then printf '%q ' "$@"; printf '\n'; else "$@"; fi
}

umask 077
if [ "$DRY" = 0 ]; then mkdir -p "$OUT"; fi
CNF="$OUT/openssl.cnf"
if [ "$DRY" = 0 ]; then
  cat > "$CNF" <<'CNF'
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[client]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
CNF
fi

if [ "$DRY" = 1 ] || [ ! -f "$OUT/ca.pem" ]; then
  run openssl ecparam -name prime256v1 -genkey -param_enc named_curve -noout -out "$OUT/ca.key"
  run openssl req -new -x509 -sha256 -key "$OUT/ca.key" -out "$OUT/ca.pem" -days 3650 \
    -subj "/CN=Agmente client CA" -config "$CNF" -extensions ca
fi

run openssl ecparam -name prime256v1 -genkey -param_enc named_curve -noout -out "$OUT/$DEVICE.key"
run openssl req -new -sha256 -key "$OUT/$DEVICE.key" -out "$OUT/$DEVICE.csr" -subj "/CN=$DEVICE" -config "$CNF"
run openssl x509 -req -sha256 -in "$OUT/$DEVICE.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/$DEVICE.pem" -days 730 -extfile "$CNF" -extensions client

if [ "$DRY" = 1 ]; then
  echo "openssl pkcs12 -export -inkey $OUT/$DEVICE.key -in $OUT/$DEVICE.pem -certfile $OUT/ca.pem -name $DEVICE -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:P12_PASS -out $OUT/$DEVICE.p12"
  echo "openssl verify -CAfile $OUT/ca.pem $OUT/$DEVICE.pem"
  exit 0
fi

P12_PASS="$(openssl rand -base64 18)"
export P12_PASS
openssl pkcs12 -export -inkey "$OUT/$DEVICE.key" -in "$OUT/$DEVICE.pem" -certfile "$OUT/ca.pem" -name "$DEVICE" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:P12_PASS -out "$OUT/$DEVICE.p12" </dev/null
openssl verify -CAfile "$OUT/ca.pem" "$OUT/$DEVICE.pem"
rm -f "$OUT/$DEVICE.csr"
echo "Wrote $OUT/$DEVICE.p12. Import it in the app with this passphrase (shown once, not stored):" >&2
echo "$P12_PASS" >&2
echo "Caddy client CA: $OUT/ca.pem" >&2
