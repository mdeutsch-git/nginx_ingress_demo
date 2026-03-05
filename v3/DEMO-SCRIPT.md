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
  http://${NGINX_IP}/echo | jq '.request.headers | {
    xff:      .["x-forwarded-for"],
    orig_xff: .["x-original-forwarded-for"]
  }'
# Expected:
# {
#   "xff":      "1.2.3.4, <nginx-pod-IP>",   ← nginx appended its own outbound IP
#   "orig_xff": "1.2.3.4"                     ← original preserved under nginx-specific name
# }
```

> "nginx preserves the original `X-Forwarded-For` as `X-Original-Forwarded-For` and appends its own outbound pod IP to the live `X-Forwarded-For`. Any application reading XFF for the client IP is now reading a chain that ends with the nginx pod IP, not the user. `X-Original-Forwarded-For` is a nginx-specific header — nothing else uses that name."

Show that gzip is active:

```bash
# Gzip — nginx use-gzip: true is working
curl -s -I -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${NGINX_IP}/get | grep -i "content-encoding"
# → content-encoding: gzip
```

> "These two behaviors — XFF handling and gzip — are examples of what we need to preserve across the migration. Watch what changes as we move to each option."

---

## Section 2: Option A — Istio Proprietary API (6 min)

> "Because you already have Istio, the fastest path is Option A — replacing the Ingress resource with an Istio Gateway and VirtualService. We deploy a dedicated gateway pod so existing traffic is completely isolated — no shared ingressgateway required."

```bash
# Deploys: ServiceAccount, Deployment, Service, Role/RoleBinding, Gateway, EnvoyFilters, VirtualService, DestinationRules
kubectl apply -f 03-istio-proprietary/

kubectl get pods -n istio-system -l ingress=nginx-migration --watch
# Ctrl-C when Running/2/2

kubectl get gateway nginx-migration-gateway -n istio-system
kubectl get virtualservice -n nginx-demo
```

**Set the IP:**
```bash
ISTIO_A_IP=$(kubectl get svc nginx-migration-ingressgateway -n istio-system \
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
  http://${ISTIO_A_IP}/echo | jq '.request.headers | {
    xff:            .["x-forwarded-for"],
    envoy_ext_addr: .["x-envoy-external-address"],
    orig_xff:       .["x-original-forwarded-for"]
  }'
# Expected:
# {
#   "xff":            "1.2.3.4,<gateway-pod-IP>", ← Istio appends gateway IP to the XFF chain
#   "envoy_ext_addr": "1.2.3.4",                  ← trusted client IP extracted and set here
#   "orig_xff":       null                          ← nginx-specific header gone
# }
```

> "Two things happened. First, `X-Original-Forwarded-For` is gone — that was nginx-specific. Second, Istio now provides the trusted client IP in `X-Envoy-External-Address` in addition to forwarding the XFF chain with the gateway pod IP appended. Any application that was reading `X-Original-Forwarded-For` needs to switch to `X-Envoy-External-Address`. Any application reading raw `X-Forwarded-For` will now see the full chain ending with the gateway IP — same as before, just a different IP in the chain."

**Test 3 — Gzip preserved (via EnvoyFilter):**
```bash
curl -s -I -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${ISTIO_A_IP}/get | grep -i "content-encoding"
# → content-encoding: gzip
```

**Test 4 — Body size limit preserved (via EnvoyFilter):**
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

**Test 5 — Access log format (open a second terminal):**
```bash
# Run this in a second terminal, then make a request
kubectl logs -n istio-system -l ingress=nginx-migration -f --tail=0

# The log line should match the nginx-equivalent format:
# 1.2.3.4 (xff) - 10.x.x.x (client) - [timestamp] "GET /echo HTTP/1.1" 200 ...
```

Show the EnvoyFilter that enables all of this:
```bash
kubectl get envoyfilter -n istio-system
# → nginx-migration-header-buffers, nginx-migration-max-body, nginx-migration-gzip, nginx-migration-access-log
head -40 03-istio-proprietary/envoyfilters.yaml
```

> "All four behaviors are preserved. The cost is these EnvoyFilters — raw xDS config, no validation. A wrong path or field name silently breaks the gateway. This is the honest tradeoff of Option A."

```bash
bash verify.sh istio-proprietary
```

---

## Section 3: Option B — Istio with Gateway API (5 min)

> "Option B: same Istio control plane, same Envoy data plane, Gateway API instead of istio proprietary resources."

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
# XFF: same Istio behavior — X-Envoy-External-Address set, gateway IP appended to XFF chain
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/echo | jq '.request.headers["x-envoy-external-address"]'
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

**Test 1 — XFF behavior compared to Istio:**
```bash
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/echo | jq '.request.headers | {
    xff:            .["x-forwarded-for"],
    envoy_ext_addr: .["x-envoy-external-address"]
  }'
# Expected:
# {
#   "xff":            "1.2.3.4,<gateway-IP>", ← EG appends and forwards — same pattern as Istio
#   "envoy_ext_addr": null                     ← not set by EG (Istio-specific header)
# }
```

> "Same XFF chain behavior as Istio — client IP is preserved, gateway appends its own IP. The difference is `X-Envoy-External-Address` is not set by Envoy Gateway. That's an Istio-specific header. Applications that switched to reading `X-Envoy-External-Address` for the Istio migration would need to switch back to reading `X-Forwarded-For` if they later move to Envoy Gateway."

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

**Test 4 — BackendTrafficPolicy circuit breaker and retry in effect:**
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
  http://${NGINX_IP}/echo \
  | jq -r '(.request.headers["x-original-forwarded-for"] // "(not set)") | "  \(.)"'

echo "=== Istio — Options A and B (X-Envoy-External-Address) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/echo \
  | jq -r '(.request.headers["x-envoy-external-address"] // "(not set)") | "  \(.)"'

echo "=== Envoy Gateway — Option C (X-Forwarded-For) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/echo \
  | jq -r '(.request.headers["x-forwarded-for"] // "(not set)") | "  \(.)"'

# Expected output:
# === nginx (X-Original-Forwarded-For) ===
#   1.2.3.4
# === Istio — Options A and B (X-Envoy-External-Address) ===
#   1.2.3.4
# === Envoy Gateway — Option C (X-Forwarded-For) ===
#   1.2.3.4, <gateway-ip>
```

> "All three correctly identify the client IP — just from different headers. nginx preserves it in `X-Original-Forwarded-For`. Istio extracts it into `X-Envoy-External-Address`. Envoy Gateway keeps it at the front of the standard `X-Forwarded-For` chain. This is a migration checklist item, not a blocking issue — but every application that reads the client IP header needs to know which header to read per option."

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
  http://${GW_IP}/echo | jq '.request.headers | with_entries(
    select(.key | test("forward|envoy-external|real-ip|remote"))
  )'

# ── Gzip ──────────────────────────────────────────────────────────────────────
# Confirm gzip is proxy-applied (not httpbin's built-in /gzip endpoint)
curl -sv -H "Host: myapp.example.com" \
  -H "Accept-Encoding: gzip" \
  -H "X-Pad: $(python3 -c "print('A'*1200)")" \
  http://${GW_IP}/get 2>&1 | grep -iE "content-encoding|< HTTP"

# ── Body size ─────────────────────────────────────────────────────────────────
python3 -c "import json; print(json.dumps({'data': 'x'*1048576}))" > /tmp/body.json
curl -s -o /dev/null -w "1MB body: HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" \
  -X POST -H "Content-Type: application/json" \
  --data-binary "@/tmp/body.json" http://${GW_IP}/post
rm /tmp/body.json

# ── Live access logs ──────────────────────────────────────────────────────────
# Option A dedicated gateway:
kubectl logs -n istio-system -l ingress=nginx-migration -f --tail=0
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
