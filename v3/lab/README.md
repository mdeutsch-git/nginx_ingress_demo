# Ingress Migration Lab — YAML Package

## Directory Structure

```
lab/
├── lab-setup.sh                        # Install all dependencies
├── verify.sh                           # Verify each stage of the demo
│
├── 00-install/
│   ├── ingress-nginx-values.yaml       # Helm values replicating customer config
│   ├── tls-secrets.yaml                # TLS Secret placeholders
│   └── generate-tls-secret.sh         # Script to generate and apply self-signed certs
│
├── 01-sample-app/
│   └── httpbin.yaml                    # httpbin deployment + service
│
├── 02-ingress-nginx/
│   └── ingress.yaml                    # Starting state — Ingress resource with annotations
│
├── 03-istio-proprietary/
│   ├── gateway.yaml                    # Gateway resource + XFF annotation guidance
│   ├── virtualservice.yaml             # VirtualService routing
│   ├── envoyfilters.yaml               # EnvoyFilters (gzip, body size, header buffers, access log)
│   ├── destinationrule.yaml            # DestinationRule — ISTIO_MUTUAL for sidecar upstreams
│   └── dedicated-gateway/             # *** RECOMMENDED for live environments ***
│       ├── deployment.yaml             # Second gateway pod (label: ingress: nginx-migration)
│       ├── rbac.yaml                   # ServiceAccount + ClusterRoleBinding for gateway injection
│       ├── gateway.yaml                # Istio Gateway targeting dedicated pod only
│       └── envoyfilters-dedicated.yaml # EnvoyFilters scoped to dedicated pod — shared gateway untouched
│
├── 04-istio-gateway-api/
│   ├── gateway.yaml                    # Gateway API Gateway (annotation scopes XFF to this pod)
│   ├── httproute.yaml                  # HTTPRoute — portable, identical to Option C
│   └── destinationrule.yaml            # DestinationRule — ISTIO_MUTUAL required for Gateway API pods
│
└── 05-envoy-gateway/
    ├── envoy-gateway.yaml              # EnvoyProxy + GatewayClass + Gateway + Policies + HTTPRoute
    └── envoy-patch-policies.yaml       # EnvoyPatchPolicy for gzip, body size, header size (not yet typed CRD fields)
```

## Gateway Isolation — What Each Option Does

A key customer concern during migration is **not touching existing production traffic**. Each option
handles this differently.

### Option A — Istio Proprietary API

**Default path (`03-istio-proprietary/`):** Uses the shared `istio-ingressgateway`. EnvoyFilters
target the `istio: ingressgateway` label, so any change or misconfiguration affects all traffic
through the shared gateway.

**Recommended path for live environments (`03-istio-proprietary/dedicated-gateway/`):** Deploys a
second gateway pod with the unique label `ingress: nginx-migration`. All EnvoyFilters target this
label exclusively. The shared `istio-ingressgateway` is not modified in any way — existing traffic
is completely isolated.

```
istio-ingressgateway             ← existing production traffic, untouched
nginx-migration-ingressgateway   ← migration traffic, carries all new EnvoyFilters
```

The dedicated pod uses `image: auto` + `inject.istio.io/templates: gateway` so istiod manages the
proxy version automatically — no manual image tag tracking or risk of version mismatch errors.

**XFF scoping:** The `proxy.istio.io/config` annotation belongs on the dedicated gateway Deployment's
pod template — not on the shared gateway and not in MeshConfig (see note below).

### Option B — Istio + Gateway API

**Isolation is automatic.** When `gatewayClassName: istio` is used, Istio provisions a brand-new
Deployment per Gateway resource (named `<gateway-name>-istio`). It does not reuse or modify
`istio-ingressgateway`. The two gateways are fully independent from the moment the Gateway resource
is applied.

The `proxy.istio.io/config` annotation on the Gateway resource is propagated by Istio directly to
the pod template of the provisioned Deployment — XFF trust is scoped to this gateway only, with no
manual Deployment patching required.

```
istio-ingressgateway    ← existing, untouched
demo-gateway-istio      ← auto-provisioned by Istio, carries only Gateway API routes
```

This is a meaningful advantage over Option A's default path — no manual dedicated gateway setup
required.

### Option C — Envoy Gateway

**Isolation is by design.** Envoy Gateway runs in its own namespace (`envoy-gateway-system`) with
its own control plane and provisions independent gateway pods per `Gateway` resource. It has no
access to or interaction with `istio-ingressgateway`. The `EnvoyProxy` resource scopes telemetry
and proxy config to Envoy Gateway's own fleet only.

```
istio-ingressgateway     ← existing, untouched (entirely separate control plane)
envoy-gateway (pod)      ← provisioned by Envoy Gateway in its own namespace
```

---

## Quick Start

```bash
# 1. Generate TLS certs
bash 00-install/generate-tls-secret.sh

# 2. Install all dependencies
bash lab-setup.sh

# 3. Deploy sample app and starting state
kubectl apply -f 01-sample-app/
kubectl apply -f 02-ingress-nginx/

# 4. Verify baseline (nginx)
bash verify.sh nginx
```

## Demo Sequence

### Stage 1 — Baseline

```bash
bash verify.sh nginx
```

### Stage 2 — Option A: Istio Proprietary API

Two paths depending on whether the customer has existing production traffic on `istio-ingressgateway`.

**Lab / greenfield (no existing gateway traffic):**
```bash
kubectl apply -f 03-istio-proprietary/
bash verify.sh istio-proprietary
```

**Live environment with existing traffic — recommended:**
```bash
# Deploy dedicated gateway — shared istio-ingressgateway is not modified
kubectl apply -f 03-istio-proprietary/dedicated-gateway/

# Verify dedicated pod is running
kubectl get pods -n istio-system -l ingress=nginx-migration

# Test against dedicated gateway IP directly
DEDICATED_IP=$(kubectl get svc nginx-migration-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -H "Host: myapp.example.com" http://${DEDICATED_IP}/headers

# Confirm shared gateway is untouched — EnvoyFilters with workloadSelector ingress:nginx-migration
# do not appear on istio-ingressgateway pods
kubectl get envoyfilter -n istio-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{" → "}{.spec.workloadSelector.labels}{"\n"}{end}'
```

> **Demo talking point:** "The dedicated gateway pattern means we can run the migration in
> parallel — new configuration is live and testable without a maintenance window or any risk
> to existing traffic. Cutover is a DNS change, not a config change."

### Stage 3 — Option B: Istio + Gateway API

```bash
kubectl apply -f 04-istio-gateway-api/
bash verify.sh istio-gateway-api
```

> **Demo talking point:** "With Gateway API, Istio auto-provisions a dedicated Deployment per
> Gateway resource — you get isolation for free. The existing `istio-ingressgateway` is never
> touched. There's no Option A-style dedicated gateway setup to manage."

```bash
# Show the auto-provisioned pod — Istio created this from the Gateway resource alone
kubectl get pods -n istio-system -l gateway.networking.k8s.io/gateway-name=demo-gateway
```

### Stage 4 — Option C: Envoy Gateway

```bash
kubectl apply -f 05-envoy-gateway/

# EnvoyPatchPolicies require the listener to exist before patching xDS
kubectl wait --for=condition=Programmed gateway demo-gateway-eg -n default --timeout=60s
kubectl apply -f 05-envoy-gateway/envoy-patch-policies.yaml

bash verify.sh envoy-gateway
```

> **Demo talking point:** "Envoy Gateway runs in its own namespace with its own control plane.
> It is architecturally impossible for it to affect `istio-ingressgateway` — they have no shared
> state. This is the strongest isolation guarantee of all three options."

### Cutover

Only after all stages are verified and the customer has committed to an option:

```bash
kubectl delete -f 02-ingress-nginx/
helm uninstall ingress-nginx -n ingress-nginx
```

---

## Prerequisites Summary

| Requirement | Version used | Check |
|---|---|---|
| Kubernetes | 1.30+ | `kubectl version` |
| Helm | 3.14+ | `helm version` |
| istioctl | 1.29.0 | `istioctl version` |
| Istio (in cluster) | 1.29.0 | `kubectl get pods -n istio-system` |
| Gateway API CRDs | v1.5.0 | `kubectl get crd gateways.gateway.networking.k8s.io` |
| Envoy Gateway | 1.7.0 | `kubectl get pods -n envoy-gateway-system` |
| LoadBalancer support | — | `kubectl get svc -A \| grep LoadBalancer` |

## Notes

- `httpbin` is sidecar-injected — the namespace label is set in `01-sample-app/httpbin.yaml`
- All gateway options run in parallel during the demo — IPs differ, the `Host:` header routes correctly to each
- `verify.sh` tests all five key settings from the customer's ingress-nginx config at each stage
- **Do not use `meshConfig.defaultConfig.gatewayTopology.numTrustedProxies`** — it propagates to
  all sidecars and causes inbound listeners to strip `X-Forwarded-For` before it reaches the
  application. Use `proxy.istio.io/config` on the gateway pod template instead (handled in
  `lab-setup.sh` for the shared gateway, and in `dedicated-gateway/deployment.yaml` for Option A isolation)
