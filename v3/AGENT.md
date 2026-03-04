# v3 Lab — Agent Reference

> For Claude Code: context, known issues, demo flow, and version notes for this project.
> Only files in `v3/` are in scope. Do not modify v1/ or v2/.

---

## Project Purpose

Demo lab comparing three alternatives for migrating off ingress-nginx when Istio is already installed.

| File | Purpose |
|---|---|
| [ingress-migration-guide.md](ingress-migration-guide.md) | Full decision guide, side-by-side config equivalents, migration walkthrough |
| [DEMO-SCRIPT.md](DEMO-SCRIPT.md) | Standalone demo script with corrected commands — use this for live sessions |

**Three options demonstrated:**
- **Option A** — Istio proprietary API (Gateway + VirtualService + EnvoyFilter)
- **Option B** — Istio implementing Gateway API (Gateway + HTTPRoute)
- **Option C** — Envoy Gateway OSS (Gateway API + typed policy CRDs)

---

## Versions (as of last update)

| Component | Version |
|---|---|
| Istio | 1.29.0 |
| Envoy Gateway | 1.7.0 |
| Gateway API CRDs | v1.5.0 |
| Kubernetes required | 1.30+ |

Set in [lab/lab-setup.sh](lab/lab-setup.sh) — `ISTIO_VERSION`, `EG_VERSION`, `GATEWAY_API_VERSION`.

---

## Namespace Layout

| Namespace | Contents |
|---|---|
| `nginx-demo` | httpbin, echoserver, Ingress, VirtualService, HTTPRoutes, DestinationRules, Option C Gateway + ClientTrafficPolicy + BackendTrafficPolicy + EnvoyPatchPolicies, TLS cert for Option C |
| `istio-system` | Istio control plane, Option A/B Gateway resources, EnvoyFilters, dedicated gateway Deployment + Service, TLS cert for Options A & B |
| `envoy-gateway-system` | Envoy Gateway controller, EnvoyProxy, GatewayClass |
| `ingress-nginx` | ingress-nginx controller (starting state) |

**Why cert is in `nginx-demo` for Option C:** The Gateway resource is in `nginx-demo`. Gateway API requires the TLS cert to be in the same namespace as the Gateway (or use a ReferenceGrant for cross-namespace). No ReferenceGrant needed with this layout.

---

## Directory Map

```
v3/
├── ingress-migration-guide.md      Full guide + decision framework + side-by-side configs + demo script
├── AGENT.md                        This file
└── lab/
    ├── lab-setup.sh                Install all dependencies (idempotent, stateless)
    ├── verify.sh                   Test each stage (nginx | istio-proprietary | istio-gateway-api | envoy-gateway)
    ├── 00-install/
    │   ├── ingress-nginx-values.yaml   "Before" state Helm values
    │   ├── generate-tls-secret.sh      Creates demo-tls-cert in istio-system + nginx-demo
    │   └── tls-secrets.yaml            Placeholder only — do NOT apply directly; use generate-tls-secret.sh
    ├── 01-sample-app/
    │   ├── httpbin.yaml                Sidecar-injected; used for /get /post /headers /status/200
    │   └── echoserver.yaml             Used for large-header tests (/echo); no Werkzeug 8k limit
    ├── 02-ingress-nginx/
    │   └── ingress.yaml                Starting state — routes /echo + / through nginx
    ├── 03-istio-proprietary/           Option A — dedicated gateway (no shared ingressgateway required)
    │   ├── rbac.yaml                   ServiceAccount + Role/RoleBinding for TLS secret access
    │   ├── deployment.yaml             Dedicated gateway pod (label: ingress: nginx-migration) + Service
    │   ├── gateway.yaml                Istio Gateway → selector: ingress: nginx-migration
    │   ├── envoyfilters.yaml           Gzip, body size, header buffers, access log — scoped to dedicated pod
    │   ├── virtualservice.yaml         Routing with retries/timeouts → nginx-migration-gateway
    │   ├── destinationrule.yaml        ISTIO_MUTUAL for httpbin + echoserver
    │   └── dedicated-gateway/          Archived — superseded by parent directory
    ├── 04-istio-gateway-api/           Option B
    │   ├── gateway.yaml                gatewayClassName: istio → auto-provisions demo-gateway-istio pod
    │   ├── httproute.yaml              Identical to Option C routes (portability demo)
    │   └── destinationrule.yaml        ISTIO_MUTUAL — required for auto-provisioned gateway pods
    └── 05-envoy-gateway/               Option C
        ├── envoy-gateway.yaml          EnvoyProxy + GatewayClass + Gateway + ClientTrafficPolicy + BackendTrafficPolicy + HTTPRoute
        └── envoy-patch-policies.yaml   EnvoyPatchPolicy for gzip, body size, header size (not yet in typed CRDs)
```

---

## Demo Flow

### Setup (before demo)

```bash
cd lab/
bash lab-setup.sh          # installs Istio 1.29.0, EG 1.7.0, ingress-nginx, Gateway API CRDs, TLS certs, sample app
kubectl apply -f 02-ingress-nginx/
bash verify.sh nginx        # baseline — confirm all 6 tests pass
```

### Stage 1: Option A — Istio Proprietary API

```bash
kubectl apply -f 03-istio-proprietary/
kubectl get pods -n istio-system -l ingress=nginx-migration --watch
# Ctrl-C when Running/2/2
ISTIO_A_IP=$(kubectl get svc nginx-migration-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -H "Host: myapp.example.com" http://${ISTIO_A_IP}/headers
bash verify.sh istio-proprietary
```

### Stage 2: Option B — Istio + Gateway API

```bash
kubectl apply -f 04-istio-gateway-api/
# Istio auto-provisions: deployment + service named "demo-gateway-istio" in istio-system
kubectl get pods -n istio-system -l gateway.networking.k8s.io/gateway-name=demo-gateway
bash verify.sh istio-gateway-api
```

### Stage 3: Option C — Envoy Gateway

```bash
kubectl apply -f 05-envoy-gateway/
# EnvoyPatchPolicies require the listener to exist before patching xDS
kubectl wait --for=condition=Programmed gateway demo-gateway-eg -n default --timeout=60s
kubectl apply -f 05-envoy-gateway/envoy-patch-policies.yaml
bash verify.sh envoy-gateway
```

### Cutover (end of demo)

```bash
kubectl delete -f 02-ingress-nginx/
helm uninstall ingress-nginx -n ingress-nginx
```

---

## Known Issues / Gotchas

### Istio upgrade — sidecar restart required
After any `istioctl install` (install or upgrade), all sidecar-injected pods must be restarted.
`image: auto` on the dedicated gateway handles this automatically.
`lab-setup.sh` restarts `default` namespace automatically. Other namespaces must be done manually:
```bash
kubectl rollout restart deployment -n <namespace>
```
Symptom of missing restart: `TLS_error: CERTIFICATE_VERIFY_FAILED: SAN matcher`

### XFF — never use meshConfig.defaultConfig
`meshConfig.defaultConfig.gatewayTopology.numTrustedProxies` propagates to ALL sidecars.
Every sidecar inbound listener will consume + strip XFF before it reaches the application.
Use `proxy.istio.io/config` annotation on the gateway pod template only.

### Header name after XFF
| Option | Header seen by upstream |
|---|---|
| ingress-nginx | `X-Original-Forwarded-For` |
| Istio (A & B) | `X-Envoy-External-Address` |
| Envoy Gateway (C) | `X-Forwarded-For` |

Applications reading XFF for client IP must be updated when migrating to Istio.

### DestinationRule + ISTIO_MUTUAL is mandatory for Option B
The auto-provisioned gateway pod (`demo-gateway-istio`) does NOT inherit mTLS defaults
from the Istio installation profile. Without `ISTIO_MUTUAL` in DestinationRule, every
request gets `CERTIFICATE_VERIFY_FAILED`. See `04-istio-gateway-api/destinationrule.yaml`.

### Do NOT apply tls-secrets.yaml directly
`tls-secrets.yaml` contains placeholder base64 values. Applying it after `generate-tls-secret.sh`
overwrites the real cert with garbage. Always use `generate-tls-secret.sh` for cert setup.
`lab-setup.sh` calls `generate-tls-secret.sh` directly in step 5.

### EnvoyPatchPolicy listener names — apply AFTER gateway is Programmed
Listener names follow `<namespace>/<gateway-name>/<listener-name>`.
If applied before the Gateway is Programmed, the patch target doesn't exist and the policy
silently has no effect. Always `kubectl wait --for=condition=Programmed` first.

### Gzip min_content_length — lab vs production
EnvoyFilters: `min_content_length: 100` (lowered for lab testing)
EnvoyPatchPolicy: `min_content_length: 1024` (production default)
The `verify.sh` gzip test pads the request with a 1200-byte header so the response body
exceeds the 1024 threshold — works for both values.

### Envoy Gateway API version notes (EG 1.7.0)
- `ClientTrafficPolicy`, `BackendTrafficPolicy`: use `targetRefs` (plural array)
- `EnvoyPatchPolicy`: uses `targetRef` (singular)
- `max_request_headers_kb` is NOT a typed field in `ClientTrafficPolicy.headers`
- Gzip compression is NOT a typed policy field — requires `EnvoyPatchPolicy`

---

## Bugs Fixed in This Version

| File | Bug | Fix |
|---|---|---|
| `verify.sh` | `((PASS++))` with `set -e` exits script when PASS=0 (arithmetic exits 1 for value 0) | Replaced with `PASS=$((PASS+1))` |
| `verify.sh` | `istio-gateway-api` stage looked up `istio-ingressgateway` service; Option B auto-provisions `demo-gateway-istio` | Updated service name in case block |
| `envoy-gateway.yaml` | `headers:` null key in ClientTrafficPolicy failed validation | Removed empty key; added explanatory comment |
| `lab-setup.sh` | Applied `tls-secrets.yaml` (placeholders) after cert generation, overwriting real cert | Changed to call `generate-tls-secret.sh` directly |
| `lab-setup.sh` | XFF patch was unconditional and non-idempotent; repeated runs caused unnecessary restarts | Added annotation check before patching |
| `lab-setup.sh` | No Istio upgrade restart handling — sidecar mTLS breaks after version mismatch | Added `rollout restart` for `default` namespace post-install |
| `lab-setup.sh` | Relative paths failed if script called from outside `lab/` | Added `SCRIPT_DIR` + `cd` at start |
| `lab-setup.sh` | Versions pinned to old Istio 1.20.3, EG 1.1.0, Gateway API v1.1.0 | Updated to 1.29.0 / 1.7.0 / v1.2.1 |

---

## What Still Requires Manual Attention

1. **EG 1.7.0 BackendTrafficPolicy `retryOn.triggers` format** — verify accepted string values match
   the EG 1.7.0 API. Current values (`"5xx"`, `"gateway-error"`, `"connect-failure"`) are from EG
   1.1.x. In newer versions these may be typed enums.

2. **Envoy Gateway gzip EnvoyPatchPolicy JSON path** — The path
   `/filter_chains/0/filters/0/typed_config/http_filters/0` is xDS-version sensitive. If EG 1.7.0
   generates a different filter chain layout, this patch may apply at the wrong path or fail silently.
   Validate with: `kubectl get envoyfilter` and check `kubectl describe envoygateway` for patch status.

3. **Istio 1.29.0 API versions** — YAMLs use `networking.istio.io/v1beta1` and `v1alpha3`.
   Istio 1.25+ prefers `networking.istio.io/v1`. The `v1beta1` aliases still work but consider
   updating to `v1` for new resources.

4. **Other sidecar-injected namespaces** — After running `lab-setup.sh` with a new Istio version,
   any namespace with `istio-injection=enabled` outside of `default` needs manual restart.
   Run: `kubectl rollout restart deployment -n <namespace>` for each.
