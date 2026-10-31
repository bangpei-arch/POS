#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-./dev-secrets}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out "$OUT_DIR/cloud-jwt-private.pem"
openssl pkey -in "$OUT_DIR/cloud-jwt-private.pem" -pubout \
  -out "$OUT_DIR/cloud-jwt-public.pem"

chmod 600 "$OUT_DIR/cloud-jwt-private.pem"
chmod 644 "$OUT_DIR/cloud-jwt-public.pem"

echo "Development RS256 keys created in $OUT_DIR"
echo "Never commit these keys or use them in production."
