# Demo Script: ingress-nginx → Istio / Envoy Gateway

> **Format:** Verbal walkthrough for a technical audience. <br>
> **Estimated time:** 25–30 minutes.<br>
> **Working directory:** `v3/lab/` for all commands. <br>
> **Customer Focus:** 
---

## Customer Notes 

Nginx Controller Config 
```
  config:
    allow-snippet-annotations: "true"
    annotations-risk-level: "Critical"
    http-snippet: |
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    compute-full-forwarded-for: "true"
    gzip-types: application/json
    use-gzip: "true"  
    client-header-buffer-size: 100k
    large-client-header-buffers: 4 100k
    log-format-upstream: $http_x_forwarded_for (xff) - $remote_addr (client) - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $request_length $request_time $upstream_response_time $upstream_addr
    use-forwarded-headers: "true"
    client-body-buffer-size: 64k
```
Ingress Annotations
```
    nginx.ingress.kubernetes.io/proxy-body-size: 300m
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
```


---
## Demo Purpose 

Customer has asked for a demo of how to move from ingress-nginx to another ingress pattern. 
This demo is aimed to outline some of those migration strategies with a focus on their existing configurations.


### 1. Context and Problem Statement

ingress-nginx works, but it has well-understood limitations that become friction points as platform maturity increases:

- **Configuration model is nginx, not Kubernetes.** Extensions require raw nginx config via `http-snippet` or `configuration-snippet` annotations. This is fragile, hard to validate, and a known security surface (arbitrary nginx directive injection).
- **`annotations-risk-level: Critical`** being set is a signal the team has already pushed past the intended safety guardrails to get features working. This is technical debt.
- **No native resilience primitives.** Retries, circuit breaking, and fault injection all require external tooling or nginx annotations with limited semantics.
- **End of active development trajectory.** The Kubernetes community's forward path is the Gateway API. ingress-nginx has no migration path to it.

**The existing Istio investment matters.** The cluster already has Envoy sidecars, mTLS, and observability in place. The question is not whether to change data planes — it's how to extend the existing Envoy investment to the ingress layer as well.

### 2. The Three Options
| | Option A | Option B | Option C |
|---|---|---|---|
| **API standard** | Istio proprietary | Gateway API (portable) | Gateway API (portable) |
| **Controller** | Istio (istiod) | Istio (istiod) | Envoy Gateway |
| **Data plane** | Envoy | Envoy | Envoy |
| **Mesh capabilities** | ✅ Full | ✅ Full | ❌ Ingress only |
| **Migration effort** | Lowest | Medium | Medium-High |
| **Future portability** | Low | High | High |
| **Extension model** | `EnvoyFilter` (raw xDS) | `EnvoyFilter` (raw xDS) | Typed policy CRDs + `EnvoyPatchPolicy` for gaps |

### 3. Decision Framework

**Choose Option A (Istio proprietary) if:**
- You want the fastest migration with least disruption
- Your team already knows VirtualService/DestinationRule
- You accept that you'll eventually want to migrate to Gateway API anyway (this is not the end state)

**Choose Option B (Istio + Gateway API) if:**
- You want to invest once and build on the right foundation
- You have multiple teams managing routes (the multi-tenancy model matters)
- You plan to potentially swap controllers later (e.g., move to Envoy Gateway)

**Choose Option C (Envoy Gateway) if:**
- You want to separate ingress concerns from mesh concerns operationally
- Your team finds Istio's operational complexity higher than needed for the ingress use case
- You want first-class typed policy CRDs instead of raw `EnvoyFilter` patches for common config
- You are willing to run two controllers (Istio for mesh, EG for ingress)

> **Note on Option C:** Running Envoy Gateway alongside Istio is a valid and increasingly common pattern. EG handles north-south traffic; Istio handles east-west. They share the same data plane (Envoy) and can be configured to interoperate with Istio's mTLS via `BackendTLSPolicy`.

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

---

## Section 1: What is the current state? (4 min)

Show the live ingress-nginx ConfigMap:

```bash
kubectl get configmap ingress-nginx-controller -n ingress-nginx -o yaml
```

> "Notice a few things. `annotations-risk-level: Critical` — this means we've explicitly accepted that any team with Ingress create access can inject raw nginx config. That's a security concern.
>
> `http-snippet` injects config directly into `nginx.conf`. There's no validation, no schema — it's a string that gets templated in. If there's a syntax error, nginx fails to reload and traffic drops.
>
> `client-header-buffer-size: 100k` — the nginx default is 1k. This was changed because something was breaking. We're compensating for a problem rather than understanding it.
>
> This is what 'it works' looks like before it doesn't."

Show the current routing in action:

```bash
# Basic connectivity — the starting state
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "Host: myapp.example.com" http://${NGINX_IP}/status/200
# → HTTP 200

# Show what headers the upstream application actually receives
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${NGINX_IP}/echo | jq '.request.headers["x-forwarded-for"]'
# Expected:
# "1.2.3.4, <nginx-pod-IP>"   ← incoming IP preserved, nginx appended its own outbound IP
```

> "This is what `compute-full-forwarded-for: true` + `use-forwarded-headers: true` + `proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for` gives you. The incoming `X-Forwarded-For` is trusted and the chain is extended — not replaced. The client IP is still visible at the front. This is the behavior we need to preserve across the migration."

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

> "The Gateway defines the listener — port, protocol, TLS, which hosts to accept. The VirtualService defines how to route traffic once it's accepted. These are two separate resources, which lets you change routing without touching the listener config."

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

**Test 2 — XFF chain preserved:**
```bash
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_A_IP}/echo | jq '.request.headers["x-forwarded-for"]'
# Expected:
# "1.2.3.4,<gateway-pod-IP>"  ← client IP preserved at front, gateway IP appended
```

> "XFF chain behavior is identical to nginx — client IP at the front, gateway appends its own. The nginx-specific `X-Original-Forwarded-For` is gone. Istio also sets `X-Envoy-External-Address` to the extracted trusted client IP, which is useful if you want a single clean header rather than parsing the chain."

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

> "Where does this fall short? The extension model. If I need gzip, or the 300m body limit, I'm writing an EnvoyFilter — raw xDS config wrapped in a Kubernetes resource. It's powerful but unvalidated. A typo here silently breaks the gateway. All four behaviors are preserved. That's the honest tradeoff of Option A."

```bash
bash verify.sh istio-proprietary
```

---

## Section 3: Option B — Istio with Gateway API (5 min)

> "Option B uses the same Istio control plane, same Envoy data plane, but swaps the API to the Kubernetes-standard Gateway API. The reason this matters isn't technical — it's operational."

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
# XFF chain behavior identical — client IP preserved, gateway IP appended
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/echo | jq '.request.headers["x-forwarded-for"]'
# → "1.2.3.4,<gateway-pod-IP>"
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

> "Two things I want to highlight.
>
> First — `allowedRoutes.namespaces.from: All`. This is the cluster operator saying 'any namespace can attach routes to this gateway.' If I set this to `Selector`, only specific namespaces can. ingress-nginx has no equivalent — any namespace can create an Ingress and it goes through the same controller.
>
> Second — the HTTPRoute is in the `nginx-demo` namespace. The Gateway is in `istio-system`. Different teams own these. The application team writes the HTTPRoute; the platform team writes the Gateway. No overlap, no stepping on each other.
>
> The EnvoyFilter story is the same as Option A — still raw xDS for anything beyond routing. That's the honest limitation."

```bash
bash verify.sh istio-gateway-api
```

---

## Section 4: Option C — Envoy Gateway (6 min)

> "Envoy Gateway is a separate controller. It's not Istio. It doesn't do service mesh. But it implements the same Gateway API — meaning the HTTPRoute we just wrote works unchanged against it.
>
> The reason to consider it alongside Istio is the extension model. Watch this."

Show the key comparison:
```bash
# Istio: raw xDS to set header buffer limits
grep -A 12 "max_request_headers_kb" 03-istio-proprietary/envoyfilters.yaml

# Envoy Gateway: typed CRD
kubectl explain clienttrafficpolicy.spec.clientIPDetection
```

> "Same outcome. One is raw xDS — `envoy.filters.network.http_connection_manager`, `typed_config`, manually constructing the protobuf type URL. The other is a typed Kubernetes CRD. It's validated, it's readable, it has docs.
>
> `ClientTrafficPolicy` covers XFF trust, header buffer limits, proxy protocol, HTTP/1/HTTP/2/HTTP/3 settings. `BackendTrafficPolicy` covers retries, timeouts, circuit breaking, rate limiting — all native. No xDS patches for the common 80% of cases.
>
> The tradeoff: you're running two controllers. Istio for your mesh, Envoy Gateway for your ingress. That's more to operate. Whether that's worth it depends on how much time your team spends writing and debugging EnvoyFilters."

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

**Test 1 — XFF chain preserved:**
```bash
curl -s -H "Host: myapp.example.com" \
  -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/echo | jq '.request.headers["x-forwarded-for"]'
# Expected:
# "1.2.3.4,<gateway-IP>"  ← client IP preserved at front, gateway IP appended
```

> "Same XFF chain behavior as nginx and Istio. One difference from Istio: `X-Envoy-External-Address` is not set — that's an Istio-specific header. Applications that read `X-Envoy-External-Address` would need to switch back to `X-Forwarded-For` when moving from Istio to Envoy Gateway."

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
echo "=== nginx (X-Forwarded-For chain) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${NGINX_IP}/echo \
  | jq -r '(.request.headers["x-forwarded-for"] // "(not set)") | "  \(.)"'

echo "=== Istio — Options A and B (X-Forwarded-For chain) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${ISTIO_B_IP}/echo \
  | jq -r '(.request.headers["x-forwarded-for"] // "(not set)") | "  \(.)"'

echo "=== Envoy Gateway — Option C (X-Forwarded-For chain) ==="
curl -s -H "Host: myapp.example.com" -H "X-Forwarded-For: 1.2.3.4" \
  http://${EG_IP}/echo \
  | jq -r '(.request.headers["x-forwarded-for"] // "(not set)") | "  \(.)"'

# Expected output:
# === nginx (X-Forwarded-For chain) ===
#   1.2.3.4, <nginx-pod-IP>
# === Istio — Options A and B (X-Forwarded-For chain) ===
#   1.2.3.4, <gateway-pod-IP>
# === Envoy Gateway — Option C (X-Forwarded-For chain) ===
#   1.2.3.4, <gateway-ip>
```

> "All three preserve the client IP at the front of the XFF chain — same behavior, different proxy IP appended. The XFF behavior is consistent across the migration. The one Istio bonus: it also sets `X-Envoy-External-Address` to the extracted client IP, giving applications a cleaner single-value header. That header is Istio-specific and won't be present with nginx or Envoy Gateway."

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

> "Three options, one data plane. You're not changing what handles your traffic — Envoy is already there. What you're changing is how you tell it what to do.
>
> Option A is the fastest migration but not the final state. It removes the nginx dependency immediately and gets you to Envoy everywhere — an afternoon migration if your team already knows Istio.
>
> Option B is the right foundation if Istio is your long-term platform. Gateway API portability means the HTTPRoute you write today works if you change controllers later. The multi-tenancy model scales as more teams adopt it.
>
> Option C is worth evaluating if your team is spending meaningful time on EnvoyFilters and you want a cleaner separation of concerns between mesh and ingress. The typed policy CRDs are a meaningfully better operational model for the 80% of common cases — at the cost of a second controller to operate.
>
> The configs we walked through today are all in the lab package — Gateway, HTTPRoute, EnvoyFilter equivalents, and the ClientTrafficPolicy alternatives. Start with Option B, keep Option C in your back pocket."

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
# Initial State
kubectl logs -n ingress-nginx ingress-nginx-controller-564b775c95-s79hh -f

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
