# Demo Script: ingress-nginx → Istio / Envoy Gateway

> **Format:** Verbal walkthrough for a technical audience.
> **Estimated time:** 25–30 minutes.
> **Working directory:** `v3/lab/` for all commands.

---

## Pre-Demo Setup

Run this before the session. All steps are idempotent.

```bash
cd v3/lab/

# Install everything (Istio 1.29.0, EG 1.7.0, Gateway API v1.5.0, ingress-nginx, TLS certs, sample app)
bash lab-setup.sh

# Deploy the "before" state
kubectl apply -f 02-ingress-nginx/

# Verify baseline passes all 6 checks before starting the demo
bash verify.sh nginx
```

**Pre-flight checks:**
```bash
kubectl get pods -n istio-system
kubectl get pods -n ingress-nginx
kubectl get pods -n envoy-gateway-system
kubectl get pods -n nginx-demo
kubectl get svc -A | grep LoadBalancer
```

**Set the baseline IP — use this throughout Section 1:**
```bash
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "nginx: ${NGINX_IP}"
```

---

## Opening (2 min)

> "Today we're going to walk through what it looks like to migrate off ingress-nginx when you already have Istio in place. This isn't a theoretical discussion — we'll look at real configs and run a live migration.
>
> The question we're answering isn't 'should we use Envoy' — you already are. Every time a request hits your ingress-nginx controller, Envoy sidecars are handling the internal traffic. What we're doing today is extending that same data plane to the edge, and deciding how we want to manage it."

---

## Section 1: What's wrong with the current state (4 min)

Show the live ingress-nginx ConfigMap:

```bash
kubectl get configmap ingress-nginx-controller -n ingress-nginx -o yaml
```

> "`annotations-risk-level: Critical` — any team with Ingress create access can inject raw nginx config. `http-snippet` writes directly into `nginx.conf` — no validation, no schema. `client-header-buffer-size: 100k` — changed from the 1k default because something was breaking. This is what 'it works' looks like before it doesn't."

Show the current routing in action:

```bash
# Basic connectivity — the starting state
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" http://${NGINX_IP}/status/200
# → HTTP 200

# Show what headers the upstream application actually receives
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${NGINX_IP}/headers | jq '.headers | {
    xff:      .["X-Forwarded-For"],
    orig_xff: .["X-Original-Forwarded-For"]
  }'
# Expected:
# {
#   "xff":      "<nginx-pod-IP>",         ← nginx replaced it with its own outbound IP
#   "orig_xff": "1.2.3.4"                 ← original renamed by use-forwarded-headers
# }
```

> "nginx renames the incoming `X-Forwarded-For` to `X-Original-Forwarded-For` and sets its own XFF to the outbound pod IP. Any application reading XFF for the client IP is reading the nginx pod IP, not the user. `X-Original-Forwarded-For` is a nginx-specific header — nothing else uses that name."

Show that gzip is active:

```bash
# Gzip — nginx use-gzip: true is working
curl -s -I -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${NGINX_IP}/get | grep -i "content-encoding"
# → content-encoding: gzip
```

Show that large headers pass through:

```bash
# Large header — client-header-buffer-size 100k is active
python3 -c "print('X-Large-Token: ' + 'A'*81920)" > /tmp/hdr.txt
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -H "@/tmp/hdr.txt" \
  http://${NGINX_IP}/echo
rm /tmp/hdr.txt
# → HTTP 200  (would be 431 without the buffer config)
```

> "These three behaviors — XFF handling, gzip, header buffer size — are what we need to preserve across the migration. Watch what changes as we move to each option."

---

## Section 2: Option A — Istio Proprietary API (6 min)

> "Because you already have Istio, the fastest path is Option A — replacing the Ingress resource with an Istio Gateway and VirtualService."

```bash
kubectl apply -f 03-istio-proprietary/
kubectl get gateway -n istio-system
kubectl get virtualservice -n nginx-demo
```

**Set the IP:**
```bash
ISTIO_A_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "istio-a: ${ISTIO_A_IP}"
```

**Test 1 — Routing works, different gateway same app:**
```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" http://${ISTIO_A_IP}/status/200
# → HTTP 200

# Both routes resolve correctly
curl -s -o /dev/null -w "/status: HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" http://${ISTIO_A_IP}/status/200
curl -s -o /dev/null -w "/echo:   HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" http://${ISTIO_A_IP}/echo
```

**Test 2 — XFF behavior has changed:**
```bash
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_A_IP}/headers | jq '.headers | {
    xff:              .["X-Forwarded-For"],
    envoy_ext_addr:   .["X-Envoy-External-Address"],
    orig_xff:         .["X-Original-Forwarded-For"]
  }'
# Expected:
# {
#   "xff":            null,      ← Istio strips raw XFF on internal mesh hops
#   "envoy_ext_addr": "1.2.3.4", ← trusted client IP extracted here instead
#   "orig_xff":       null       ← nginx-specific header gone
# }
```

> "This is the first application impact to flag. Istio extracts the trusted client IP from XFF and exposes it as `X-Envoy-External-Address`. The raw XFF header is deliberately stripped on internal mesh hops as a security property — Envoy won't let a downstream fabricate trusted forwarding headers. Any application reading `X-Forwarded-For` for the original client IP needs to read `X-Envoy-External-Address` instead."

**Test 3 — Gzip preserved (via EnvoyFilter):**
```bash
curl -s -I -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${ISTIO_A_IP}/get | grep -i "content-encoding"
# → content-encoding: gzip
```

**Test 4 — Large headers preserved (via EnvoyFilter):**
```bash
python3 -c "print('X-Large-Token: ' + 'A'*81920)" > /tmp/hdr.txt
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -H "@/tmp/hdr.txt" \
  http://${ISTIO_A_IP}/echo
rm /tmp/hdr.txt
# → HTTP 200
```

**Test 5 — Body size limit preserved (via EnvoyFilter):**
```bash
# 1MB POST — well under the 300MB limit, confirms the buffer filter is active
python3 -c "import json; print(json.dumps({'data': 'x'*1048576}))" > /tmp/body.json
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -X POST -H "Content-Type: application/json" \
  --data-binary "@/tmp/body.json" \
  http://${ISTIO_A_IP}/post
rm /tmp/body.json
# → HTTP 200
```

**Test 6 — Access log format (open a second terminal):**
```bash
# Run this in a second terminal, then make a request
kubectl logs -n istio-system -l istio=ingressgateway -f --tail=0

# The log line should match the nginx-equivalent format:
# 1.2.3.4 (xff) - 10.x.x.x (client) - [timestamp] "GET /headers HTTP/1.1" 200 ...
```

Show the EnvoyFilter that enables all of this:
```bash
kubectl get envoyfilter -n istio-system
cat 03-istio-proprietary/envoyfilters.yaml | head -40
```

> "All five behaviors are preserved. The cost is these EnvoyFilters — raw xDS config, no validation. A wrong path or field name silently breaks the gateway. This is the honest tradeoff of Option A."

```bash
bash verify.sh istio-proprietary
```

---

## Section 2a: Dedicated gateway (1 min — show if audience has production concerns)

> "One question always comes up: 'What about our existing production traffic through `istio-ingressgateway`?' The EnvoyFilters above target `istio: ingressgateway` — they apply to everything running through the shared gateway."

```bash
kubectl apply -f 03-istio-proprietary/dedicated-gateway/
kubectl get pods -n istio-system -l ingress=nginx-migration

# Confirm scoping — dedicated filters don't touch the shared gateway
kubectl get envoyfilter -n istio-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{" → workloadSelector: "}{.spec.workloadSelector.labels}{"\n"}{end}'
# nginx-migration-* filters → workloadSelector: {"ingress":"nginx-migration"}
# gateway-* filters         → workloadSelector: {"istio":"ingressgateway"}
```

> "Two separate label selectors. The shared gateway is untouched. Test the migration path independently — cutover is a DNS change, not a config change."

---

## Section 3: Option B — Istio with Gateway API (5 min)

> "Option B: same Istio control plane, same Envoy data plane, Gateway API instead of proprietary resources."

```bash
kubectl apply -f 04-istio-gateway-api/

# Istio auto-provisioned a new pod — did not touch istio-ingressgateway
kubectl get pods -n istio-system -l gateway.networking.k8s.io/gateway-name=demo-gateway
kubectl get svc demo-gateway-istio -n istio-system
```

**Set the IP:**
```bash
ISTIO_B_IP=$(kubectl get svc demo-gateway-istio -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "istio-b: ${ISTIO_B_IP}"
```

**Test 1 — Identical behavior to Option A:**
```bash
# XFF: same Istio behavior — X-Envoy-External-Address, raw XFF stripped
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/headers | jq '.headers["X-Envoy-External-Address"]'
# → "1.2.3.4"
```

**Test 2 — HTTPRoute portability (the key demo point for Option B):**
```bash
# Show the HTTPRoute that routes to nginx-demo namespace
kubectl get httproute -n nginx-demo -o yaml | grep -A 10 "spec:"

# This exact YAML will work unchanged against Envoy Gateway in Section 4
# The only thing that changes is the parentRef pointing to a different Gateway
```

**Test 3 — Multi-tenancy: show route attachment is controlled:**
```bash
kubectl get gateway demo-gateway -n istio-system -o jsonpath='{.spec.listeners[*].allowedRoutes}' | jq .
# → {"namespaces":{"from":"All"}}

# The platform team (istio-system Gateway) controls who can attach routes
# Application team (nginx-demo HTTPRoute) attaches independently — no shared config file
kubectl get httproute -A
```

> "Platform team owns the Gateway in `istio-system`. Application team owns the HTTPRoute in `nginx-demo`. They are independent resources owned by different teams in different namespaces. ingress-nginx has no equivalent — there's one Ingress controller and everyone goes through it."

```bash
bash verify.sh istio-gateway-api
```

---

## Section 4: Option C — Envoy Gateway (6 min)

> "Envoy Gateway is a separate controller — not Istio. No mesh, no sidecars. Same Gateway API. The extension model is the reason to look at it."

Show the key comparison:
```bash
# Istio: raw xDS to set header buffer limits
grep -A 12 "max_request_headers_kb" 03-istio-proprietary/envoyfilters.yaml

# Envoy Gateway: typed CRD
kubectl explain clienttrafficpolicy.spec.clientIPDetection
```

Apply:
```bash
kubectl apply -f 05-envoy-gateway/envoy-gateway.yaml
kubectl wait --for=condition=Programmed gateway demo-gateway-eg -n nginx-demo --timeout=60s
kubectl apply -f 05-envoy-gateway/envoy-patch-policies.yaml
```

**Set the IP:**
```bash
EG_IP=$(kubectl get gateway demo-gateway-eg -n nginx-demo \
  -o jsonpath='{.status.addresses[0].value}')
echo "envoy-gw: ${EG_IP}"
```

**Test 1 — XFF behavior is DIFFERENT from Istio:**
```bash
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/headers | jq '.headers | {
    xff:            .["X-Forwarded-For"],
    envoy_ext_addr: .["X-Envoy-External-Address"]
  }'
# Expected:
# {
#   "xff":            "1.2.3.4, <gateway-IP>", ← EG appends and forwards — traditional behavior
#   "envoy_ext_addr": null                      ← not set by EG
# }
```

> "This is a meaningful difference. Envoy Gateway appends to `X-Forwarded-For` and passes it to the upstream — traditional proxy behavior. Istio strips it on mesh hops. Applications reading `X-Forwarded-For` directly will work as-is with Envoy Gateway. Applications migrating from Istio to Envoy Gateway need to change back from `X-Envoy-External-Address` to `X-Forwarded-For`."

**Test 2 — Same routing, different controller (portability):**
```bash
# Option B HTTPRoute vs Option C HTTPRoute — structurally identical
diff \
  <(kubectl get httproute httpbin -n nginx-demo -o jsonpath='{.spec}' | jq .) \
  <(grep -A 30 "kind: HTTPRoute" 05-envoy-gateway/envoy-gateway.yaml | \
    grep -v "^#" | python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(sys.stdin)['spec'], indent=2))")
# → no diff on the spec — same parentRefs, hostnames, rules
```

> "Identical spec. The `parentRef` points at a different Gateway name, but the route rules are the same. That's the portability guarantee of the Gateway API."

**Test 3 — Gzip working (via EnvoyPatchPolicy — the remaining 20%):**
```bash
curl -s -I -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${EG_IP}/get | grep -i "content-encoding"
# → content-encoding: gzip
```

**Test 4 — Large headers working (max_request_headers_kb via EnvoyPatchPolicy):**
```bash
python3 -c "print('X-Large-Token: ' + 'A'*81920)" > /tmp/hdr.txt
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -H "@/tmp/hdr.txt" \
  http://${EG_IP}/echo
rm /tmp/hdr.txt
# → HTTP 200
```

**Test 5 — BackendTrafficPolicy circuit breaker and retry in effect:**
```bash
# httpbin /status/503 returns 503 — triggers the 5xx retry rule
# With retry.numRetries: 3, Envoy retries 3 times before returning to the client
# Watch the gateway logs to see retries:
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=demo-gateway-eg \
  -f --tail=0 &
LOG_PID=$!

curl -s -o /dev/null -w "HTTP %{http_code} (retried 3x upstream)\n" \
  -H "Host: myapp.example.com" \
  http://${EG_IP}/status/503

kill $LOG_PID 2>/dev/null
```

```bash
bash verify.sh envoy-gateway
```

---

## Section 5: Side-by-side XFF comparison (2 min)

> "Let me show the single biggest operational difference between all three options in one block."

```bash
echo "=== nginx (X-Original-Forwarded-For) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${NGINX_IP}/headers \
  | jq -r '(.headers["X-Original-Forwarded-For"] // "(not set)") | "  \(.)"'

echo "=== Istio — Options A and B (X-Envoy-External-Address) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/headers \
  | jq -r '(.headers["X-Envoy-External-Address"] // "(not set)") | "  \(.)"'

echo "=== Envoy Gateway — Option C (X-Forwarded-For) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/headers \
  | jq -r '(.headers["X-Forwarded-For"] // "(not set)") | "  \(.)"'

# Expected output:
# === nginx (X-Original-Forwarded-For) ===
#   1.2.3.4
# === Istio — Options A and B (X-Envoy-External-Address) ===
#   1.2.3.4
# === Envoy Gateway — Option C (X-Forwarded-For) ===
#   1.2.3.4, <gateway-ip>
```

> "All three correctly identify the client IP. The header name is what changes. This is a migration checklist item, not a blocking issue — but every application that reads the client IP header needs to know which header to read. Document the header name per option before cutting over."

---

## Section 6: Parallel operation and cutover (3 min)

> "All three options have been running simultaneously against the same backend. No maintenance window was needed to reach this point."

```bash
# All four gateway sets running in parallel
kubectl get pods -n istio-system | grep -E "ingressgateway|demo-gateway"
kubectl get pods -n envoy-gateway-system
kubectl get pods -n ingress-nginx

# All four IPs — same app, four different ingress paths
echo "nginx:            ${NGINX_IP}"
echo "istio (Option A): ${ISTIO_A_IP}"
echo "istio (Option B): ${ISTIO_B_IP}"
echo "envoy-gw (Opt C): ${EG_IP}"
```

Validate before DNS change:
```bash
# Pick the target option. Using Option B here:
NEW_IP=${ISTIO_B_IP}

# Run the full verification suite against the chosen IP
# This is what you'd run in production before changing DNS
bash verify.sh istio-gateway-api
```

Cutover:
```bash
# Remove nginx Ingress resources — controller is now idle
kubectl delete -f 02-ingress-nginx/

kubectl get ingress -A   # should return empty

# When ready to remove the controller entirely:
helm uninstall ingress-nginx -n ingress-nginx
```

---

## Close (1 min)

> "Three options, one data plane.
>
> Option A is the fastest path — an afternoon migration if your team knows Istio. Not the final state, but it removes the nginx dependency immediately and gets you to Envoy everywhere.
>
> Option B is the right foundation. Gateway API portability means the HTTPRoute you write today works if you change controllers later. The multi-tenancy model scales as more teams adopt it.
>
> Option C is worth the conversation if your team spends real time on EnvoyFilters. The typed policy CRDs are a meaningfully better operational model for the 80% of common cases — at the cost of a second controller to operate.
>
> All configs are in the lab package. Start with Option B."

---

## Appendix: Commands for Q&A

```bash
# ── XFF / headers ─────────────────────────────────────────────────────────────
# Show full header picture from upstream for any gateway IP
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${GW_IP}/headers | jq '.headers | with_entries(
    select(.key | test("(?i)forward|envoy-external|real-ip|remote"))
  )'

# ── Gzip ──────────────────────────────────────────────────────────────────────
# Confirm gzip is proxy-applied (not httpbin's built-in /gzip endpoint)
curl -sv -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${GW_IP}/get 2>&1 | grep -iE "content-encoding|< HTTP"

# ── Header size ───────────────────────────────────────────────────────────────
# Single 80k header — within one buffer
python3 -c "print('X-Token: ' + 'A'*81920)" > /tmp/hdr1.txt
curl -s -o /dev/null -w "single 80k header: HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" -H "@/tmp/hdr1.txt" http://${GW_IP}/echo
rm /tmp/hdr1.txt

# Four 80k headers — exercises the full pool
python3 -c "
for i in range(1,5):
    print(f'X-Token-{i}: ' + 'A'*81920)
" > /tmp/hdr4.txt
curl -s -o /dev/null -w "4x 80k headers: HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" -H "@/tmp/hdr4.txt" http://${GW_IP}/echo
rm /tmp/hdr4.txt

# ── Body size ─────────────────────────────────────────────────────────────────
python3 -c "import json; print(json.dumps({'data': 'x'*1048576}))" > /tmp/body.json
curl -s -o /dev/null -w "1MB body: HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -X POST -H "Content-Type: application/json" \
  --data-binary "@/tmp/body.json" http://${GW_IP}/post
rm /tmp/body.json

# ── Live access logs ──────────────────────────────────────────────────────────
kubectl logs -n istio-system -l istio=ingressgateway -f --tail=0
# Option B auto-provisioned pod:
kubectl logs -n istio-system \
  -l gateway.networking.k8s.io/gateway-name=demo-gateway -f --tail=0
# Option C:
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=demo-gateway-eg -f --tail=0

# ── Retry / resilience (Option C BackendTrafficPolicy) ─────────────────────────
# 503 triggers retry — watch logs for upstream retry attempts
curl -v -H "Host: myapp.example.com" http://${EG_IP}/status/503 2>&1 | grep "< HTTP"
# Client sees one 503; gateway made 3 upstream attempts (check access log upstream_host field)

# ── Full verification suite ───────────────────────────────────────────────────
bash verify.sh nginx
bash verify.sh istio-proprietary
bash verify.sh istio-gateway-api
bash verify.sh envoy-gateway

# ── Check EnvoyPatchPolicy status (Option C) ─────────────────────────────────
kubectl get envoypatchpolicy -n nginx-demo
kubectl describe envoypatchpolicy gateway-gzip -n nginx-demo
# Status should show: Programmed: True
```
