#!/usr/bin/env bash
# verify.sh — run after each stage of the demo to confirm traffic is flowing correctly
# Usage: bash verify.sh <stage>
#   Stages: nginx | istio-proprietary | istio-gateway-api | envoy-gateway
#
# What it tests:
#   1. Basic HTTP 200 response
#   2. XFF header propagation (header name differs between nginx and Envoy-based stages)
#   3. Proxy gzip compression via /get (not /gzip — see note in test)
#   4. Large body (1MB POST — confirms buffer filter is not over-rejecting)

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
  istio-proprietary)
    GW_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
      kubectl get svc istio-ingressgateway -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    ;;
  istio-gateway-api)
    # Option B: Istio auto-provisions a Deployment+Service named <gateway-name>-istio
    # when gatewayClassName: istio is used. Gateway name is "demo-gateway" → service is "demo-gateway-istio"
    GW_IP=$(kubectl get svc demo-gateway-istio -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
      kubectl get svc demo-gateway-istio -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    ;;
  envoy-gateway)
    GW_IP=$(kubectl get gateway demo-gateway-eg -n nginx-demo \
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

PASS=0
FAIL=0

# ── Test 1: Basic connectivity ────────────────────────────────────────────────
echo "[1/4] Basic HTTP connectivity..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${HEADERS[@]}" "${BASE_URL}/status/200")
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ HTTP 200 OK"
  PASS=$((PASS+1))
else
  echo "  ❌ Expected 200, got ${STATUS}"
  FAIL=$((FAIL+1))
fi

# ── Test 2: XFF header propagation ───────────────────────────────────────────
# Each stage surfaces the trusted client IP differently:
#
#   nginx (use-forwarded-headers: true):
#     Renames incoming X-Forwarded-For → X-Original-Forwarded-For
#     Sets its own X-Forwarded-For to the pod-network connecting IP
#     Check: X-Original-Forwarded-For contains injected IP
#
#   Istio (numTrustedProxies: 1) — proprietary and Gateway API:
#     Consumes incoming XFF at the edge, extracts trusted client IP
#     Does NOT forward raw XFF header into the mesh (internal hop strips it)
#     Exposes the trusted client IP via X-Envoy-External-Address instead
#     Check: X-Envoy-External-Address equals injected IP
#
#   Envoy Gateway (numTrustedHops: 1):
#     Appends to X-Forwarded-For and forwards it to the upstream
#     Check: X-Forwarded-For contains injected IP
echo "[2/4] XFF header propagation..."
RESPONSE=$(curl -s "${HEADERS[@]}" -H "X-Forwarded-For: 1.2.3.4" "${BASE_URL}/headers")

case "$STAGE" in
  nginx)
    # nginx renames incoming XFF to X-Original-Forwarded-For
    XFF=$(echo "$RESPONSE" | \
      jq -r '(.headers | to_entries[] |
        select(.key | ascii_downcase == "x-original-forwarded-for") | .value) // empty' \
      2>/dev/null || echo "")
    HEADER_LABEL="X-Original-Forwarded-For"
    ;;
  istio-proprietary|istio-gateway-api)
    # Istio consumes XFF at the gateway edge and exposes the trusted client IP
    # via X-Envoy-External-Address. Raw XFF is not forwarded into the mesh.
    XFF=$(echo "$RESPONSE" | \
      jq -r '(.headers | to_entries[] |
        select(.key | ascii_downcase == "x-envoy-external-address") | .value) // empty' \
      2>/dev/null || echo "")
    HEADER_LABEL="X-Envoy-External-Address"
    ;;
  envoy-gateway)
    # Envoy Gateway appends to X-Forwarded-For and passes it to the upstream
    XFF=$(echo "$RESPONSE" | \
      jq -r '(.headers | to_entries[] |
        select(.key | ascii_downcase == "x-forwarded-for") | .value) // empty' \
      2>/dev/null || echo "")
    HEADER_LABEL="X-Forwarded-For"
    ;;
esac

if [[ "$XFF" == *"1.2.3.4"* ]]; then
  echo "  ✅ ${HEADER_LABEL} correctly set: ${XFF}"
  PASS=$((PASS+1))
else
  echo "  ❌ ${HEADER_LABEL} missing or injected IP not found"
  echo "     Got: '${XFF}'"
  echo "     Expected value containing: 1.2.3.4"
  case "$STAGE" in
    nginx)
      echo "     Note: nginx with use-forwarded-headers renames XFF to X-Original-Forwarded-For" ;;
    istio-proprietary|istio-gateway-api)
      echo "     Note: Istio extracts trusted client IP from XFF into X-Envoy-External-Address"
      echo "     Raw X-Forwarded-For is not forwarded into the mesh on internal hops" ;;
    envoy-gateway)
      echo "     Note: Envoy Gateway should append to X-Forwarded-For — check numTrustedHops config" ;;
  esac
  FAIL=$((FAIL+1))
fi

# ── Test 3: Proxy gzip compression ───────────────────────────────────────────
# Tests against /get (plain JSON) NOT /gzip.
# The httpbin /gzip endpoint always returns Content-Encoding: gzip regardless of
# proxy config — it's a built-in httpbin feature, not proxy behaviour.
# /get returns uncompressed application/json — any gzip here came from the proxy.
#
# The compressor filter has min_content_length: 1024 — a bare /get response in a
# minimal lab environment is ~557 bytes and will NOT be compressed. We pad the
# request with a large header so httpbin echoes it back, inflating the response
# body well past the 1024 byte threshold.
echo "[3/4] Proxy gzip compression (application/json via /get with padded response)..."
PAD=$(python3 -c "import sys; sys.stdout.write('A' * 1200)")
ENCODING=$(curl -s -D - \
  "${HEADERS[@]}" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: ${PAD}" \
  --compressed \
  "${BASE_URL}/get" | grep -i "^content-encoding:" | tr -d '\r' || echo "")
if echo "$ENCODING" | grep -qi "gzip"; then
  echo "  ✅ Gzip compression confirmed: ${ENCODING}"
  PASS=$((PASS+1))
else
  echo "  ❌ No gzip encoding on /get response"
  echo "     Got: '${ENCODING}'"
  echo "     Check: (1) gzip-types includes application/json"
  echo "            (2) min_content_length is not higher than the response body size"
  echo "            (3) EnvoyFilter workloadSelector labels match the gateway pod"
  FAIL=$((FAIL+1))
fi

# ── Test 4: Request body acceptance ──────────────────────────────────────────
# Posts a 1MB body — well under the 300MB limit.
# Confirms the buffer/body-size config is not over-rejecting.
echo "[4/4] Large request body (1MB POST)..."
python3 -c "
import sys, json
body = json.dumps({'data': 'x' * 1048576})
sys.stdout.write(body)
" > /tmp/large-body.json
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${HEADERS[@]}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "@/tmp/large-body.json" \
  "${BASE_URL}/post")
rm -f /tmp/large-body.json
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ 1MB body accepted (200 OK)"
  PASS=$((PASS+1))
else
  echo "  ❌ Body rejected (got ${STATUS})"
  echo "     Check body size limit — proxy-body-size / max_request_bytes"
  FAIL=$((FAIL+1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " Stage: ${STAGE}"
printf " Results: %d passed, %d failed\n" "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo " ✅ All checks passed"
else
  echo " ❌ ${FAIL} check(s) failed — review output above"
fi
echo "========================================"
