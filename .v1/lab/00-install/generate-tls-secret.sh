#!/usr/bin/env bash
# 00-install/generate-tls-secret.sh
# Generates a self-signed cert and patches tls-secrets.yaml with real values
# Run this instead of manually editing tls-secrets.yaml
#
# Usage: bash generate-tls-secret.sh

set -euo pipefail

DOMAIN="myapp.example.com"
CERT_FILE="tls.crt"
KEY_FILE="tls.key"

echo "==> Generating self-signed certificate for ${DOMAIN}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${KEY_FILE}" \
  -out "${CERT_FILE}" \
  -subj "/CN=${DOMAIN}/O=lab-demo" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:*.example.com" 2>/dev/null

TLS_CRT=$(cat "${CERT_FILE}" | base64 | tr -d '\n')
TLS_KEY=$(cat "${KEY_FILE}" | base64 | tr -d '\n')

echo "==> Creating TLS secrets in istio-system and envoy-gateway-system"

kubectl create secret tls demo-tls-cert \
  --cert="${CERT_FILE}" \
  --key="${KEY_FILE}" \
  -n istio-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls demo-tls-cert \
  --cert="${CERT_FILE}" \
  --key="${KEY_FILE}" \
  -n envoy-gateway-system \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Cleaning up temp files"
rm -f "${CERT_FILE}" "${KEY_FILE}"

echo "✅ TLS secrets created in istio-system and envoy-gateway-system"
