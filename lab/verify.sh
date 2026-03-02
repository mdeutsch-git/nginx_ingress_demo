#!/usr/bin/env bash
# verify.sh — run after each stage of the demo to confirm traffic is flowing correctly
# Usage: bash verify.sh <stage>
#   Stages: nginx | istio-proprietary | istio-gateway-api | envoy-gateway
#
# What it tests:
#   1. Basic HTTP 200 response
#   2. XFF header is present and populated
#   3. Large header (>1k) is accepted
#   4. Response is gzip-compressed for application/json
#   5. Large body (1MB) is accepted (body limit is 300MB)

set -euo pipefail

STAGE="${1:-nginx}"
HOST="myapp.example.com"

# Resolve the correct gateway IP for the stage
case "$STAGE" in
  nginx)
    GW_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
      kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    ;;
  istio-proprietary|istio-gateway-api)
    GW_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
      kubectl get svc istio-ingressgateway -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    ;;
  envoy-gateway)
    GW_IP=$(kubectl get gateway demo-gateway-eg -n default \
      -o jsonpath='{.status.addresses[0].value}')
    ;;
  *)
    echo "Unknown stage: $STAGE"
    echo "Valid stages: nginx | istio-proprietary | istio-gateway-api | envoy-gateway"
    exit 1
    ;;
esac

BASE_URL="http://${GW_IP}"
HEADERS=(-H "Host: ${HOST}")

echo "========================================"
echo " Verifying stage: ${STAGE}"
echo " Gateway IP:      ${GW_IP}"
echo " Host header:     ${HOST}"
echo "========================================"
echo ""

# Test 1: Basic connectivity
echo "[1/5] Basic HTTP connectivity..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${HEADERS[@]}" "${BASE_URL}/status/200")
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ HTTP 200 OK"
else
  echo "  ❌ Expected 200, got ${STATUS}"
fi

# Test 2: XFF header propagation
echo "[2/5] XFF header propagation..."
XFF=$(curl -s "${HEADERS[@]}" -H "X-Forwarded-For: 1.2.3.4" "${BASE_URL}/headers" | \
  jq -r '.headers["X-Forwarded-For"] // empty' 2>/dev/null || echo "")
if [[ -n "$XFF" ]]; then
  echo "  ✅ X-Forwarded-For present: ${XFF}"
else
  echo "  ⚠️  X-Forwarded-For not found in response headers"
fi

# Test 3: Large request header (100k limit configured)
echo "[3/5] Large request header (10k test header)..."
LARGE_HEADER=$(python3 -c "print('A' * 10240)")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${HEADERS[@]}" \
  -H "X-Large-Header: ${LARGE_HEADER}" \
  "${BASE_URL}/status/200")
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ Large header accepted (200 OK)"
else
  echo "  ❌ Large header rejected (got ${STATUS}) — check buffer config"
fi

# Test 4: Gzip compression
echo "[4/5] Gzip compression for application/json..."
ENCODING=$(curl -s -D - \
  "${HEADERS[@]}" \
  -H "Accept-Encoding: gzip" \
  "${BASE_URL}/gzip" | grep -i "content-encoding" | tr -d '\r' || echo "")
if echo "$ENCODING" | grep -qi "gzip"; then
  echo "  ✅ Gzip encoding confirmed: ${ENCODING}"
else
  echo "  ⚠️  No gzip encoding detected — check compressor EnvoyFilter/PatchPolicy"
fi

# Test 5: Request body acceptance (1MB — well under 300MB limit)
echo "[5/5] Large request body (1MB POST)..."
BODY=$(python3 -c "print('x' * 1048576)")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${HEADERS[@]}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"${BODY}\"}" \
  "${BASE_URL}/post")
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ 1MB body accepted (200 OK)"
else
  echo "  ❌ Body rejected (got ${STATUS}) — check body size limit config"
fi

echo ""
echo "========================================"
echo " Stage ${STAGE} verification complete"
echo "========================================"
