#!/usr/bin/env bash
# verify.sh — run after each stage of the demo to confirm traffic is flowing correctly
# Usage: bash verify.sh <stage>
#   Stages: nginx | istio-proprietary | istio-gateway-api | envoy-gateway
#
# What it tests:
#   1. Basic HTTP 200 response
#   2. XFF header propagation (header name differs between nginx and Envoy-based stages)
#   3. Large single header (80k — under the 100k per-buffer nginx ceiling)
#   4. Multiple large headers (4 x 80k — exercises the 4-buffer pool on nginx)
#   5. Proxy gzip compression via /get (not /gzip — see note in test)
#   6. Large body (1MB POST — confirms buffer filter is not over-rejecting)

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

# ── Config verification (nginx only) ─────────────────────────────────────────
# Verify the nginx ConfigMap values are live in the running nginx process
# before running header size tests. If this fails, the header tests are
# meaningless — the config was never applied.
if [[ "$STAGE" == "nginx" ]]; then
  echo "[pre-check] Verifying nginx buffer config is live..."
  NGINX_POD=$(kubectl get pod -n ingress-nginx     -l app.kubernetes.io/name=ingress-nginx     -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$NGINX_POD" ]]; then
    LARGE_BUF=$(kubectl exec -n ingress-nginx "$NGINX_POD" -- nginx -T 2>/dev/null | grep "large_client_header_buffers" | head -1 | tr -d ' ')
    CLIENT_BUF=$(kubectl exec -n ingress-nginx "$NGINX_POD" -- nginx -T 2>/dev/null | grep "client_header_buffer_size" | head -1 | tr -d ' ')
    echo "  Running config: ${CLIENT_BUF:-NOT FOUND}"
    echo "  Running config: ${LARGE_BUF:-NOT FOUND}"
    if ! echo "$LARGE_BUF" | grep -q "4 100k\|4100k"; then
      echo "  ⚠️  large_client_header_buffers not showing 4 100k in running nginx"
      echo "     Header size tests may fail. Check ConfigMap and force a reload:"
      echo "     kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx"
    fi
  else
    echo "  ⚠️  Could not find ingress-nginx pod — skipping config pre-check"
  fi
  echo ""
fi

echo ""

PASS=0
FAIL=0

# ── Test 1: Basic connectivity ────────────────────────────────────────────────
echo "[1/6] Basic HTTP connectivity..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${HEADERS[@]}" "${BASE_URL}/status/200")
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ HTTP 200 OK"
  ((PASS++))
else
  echo "  ❌ Expected 200, got ${STATUS}"
  ((FAIL++))
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
echo "[2/6] XFF header propagation..."
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
  ((PASS++))
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
  ((FAIL++))
fi

# ── Test 3: Single large header (within one buffer) ───────────────────────────
# nginx large-client-header-buffers: 4 100k means:
#   - Each INDIVIDUAL header line must fit in ONE buffer (max 100k per header)
#   - Up to 4 such buffers can be active simultaneously
#   - A single header cannot span multiple buffers
#
# 80k sits safely under the 100k single-buffer ceiling.
# This tests that the large buffer pool is active at all.
echo "[3/6] Single large header (80k — within one 100k buffer)..."
python3 -c "import sys; sys.stdout.write('X-Large-Header-1: ' + 'A' * 81920)" \
  > /tmp/large-header-single.txt
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${HEADERS[@]}" \
  -H "@/tmp/large-header-single.txt" \
  "${BASE_URL}/echo")  # /echo uses echoserver — no Werkzeug header size limit
rm -f /tmp/large-header-single.txt
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ 80k single header accepted (200 OK)"
  ((PASS++))
else
  echo "  ❌ 80k header rejected (got ${STATUS})"
  echo "     Check large-client-header-buffers / max_request_headers_kb config"
  ((FAIL++))
fi

# ── Test 4: Multiple large headers (exercises the 4-buffer pool) ─────────────
# To exercise the "4 buffers" aspect of large-client-header-buffers, send
# 4 separate headers each around 80k. This confirms the pool size, not just
# the per-header limit.
echo "[4/6] Multiple large headers (4 x 80k — exercises the full buffer pool)..."
python3 -c "
import sys
for i in range(1, 5):
    sys.stdout.write(f'X-Large-Header-{i}: ' + 'A' * 81920 + '\n')
" > /tmp/large-headers-multi.txt
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${HEADERS[@]}" \
  -H "@/tmp/large-headers-multi.txt" \
  "${BASE_URL}/echo")  # /echo uses echoserver — no Werkzeug header size limit
rm -f /tmp/large-headers-multi.txt
if [[ "$STATUS" == "200" ]]; then
  echo "  ✅ 4 x 80k headers accepted (200 OK)"
  ((PASS++))
else
  echo "  ❌ Multiple large headers rejected (got ${STATUS})"
  echo "     Check large-client-header-buffers count (must be >= 4)"
  ((FAIL++))
fi

# ── Test 5: Proxy gzip compression ───────────────────────────────────────────
# Tests against /get (plain JSON) NOT /gzip.
# The httpbin /gzip endpoint always returns Content-Encoding: gzip regardless of
# proxy config — it's a built-in httpbin feature, not proxy behaviour.
# /get returns uncompressed application/json — any gzip here came from the proxy.
#
# The compressor filter has min_content_length: 1024 — a bare /get response in a
# minimal lab environment is ~557 bytes and will NOT be compressed. We pad the
# request with a large header so httpbin echoes it back, inflating the response
# body well past the 1024 byte threshold.
echo "[5/6] Proxy gzip compression (application/json via /get with padded response)..."
PAD=$(python3 -c "import sys; sys.stdout.write('A' * 1200)")
ENCODING=$(curl -s -D - \
  "${HEADERS[@]}" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: ${PAD}" \
  --compressed \
  "${BASE_URL}/get" | grep -i "^content-encoding:" | tr -d '\r' || echo "")
if echo "$ENCODING" | grep -qi "gzip"; then
  echo "  ✅ Gzip compression confirmed: ${ENCODING}"
  ((PASS++))
else
  echo "  ❌ No gzip encoding on /get response"
  echo "     Got: '${ENCODING}'"
  echo "     Check: (1) gzip-types includes application/json"
  echo "            (2) min_content_length is not higher than the response body size"
  echo "            (3) EnvoyFilter workloadSelector labels match the gateway pod"
  ((FAIL++))
fi

# ── Test 6: Request body acceptance ──────────────────────────────────────────
# Posts a 1MB body — well under the 300MB limit.
# Confirms the buffer/body-size config is not over-rejecting.
echo "[6/6] Large request body (1MB POST)..."
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
  ((PASS++))
else
  echo "  ❌ Body rejected (got ${STATUS})"
  echo "     Check body size limit — proxy-body-size / max_request_bytes"
  ((FAIL++))
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
