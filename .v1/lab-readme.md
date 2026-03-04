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
│   ├── gateway.yaml                    # Gateway + MeshConfig (XFF)
│   ├── virtualservice.yaml             # VirtualService routing
│   └── envoyfilters.yaml               # EnvoyFilters + Telemetry (gzip, body, headers, logs)
│
├── 04-istio-gateway-api/
│   ├── gateway.yaml                    # Gateway API Gateway
│   └── httproute.yaml                  # HTTPRoute (portable — also works with EG)
│
└── 05-envoy-gateway/
    ├── envoy-gateway.yaml              # EnvoyProxy + GatewayClass + Gateway + Policies + HTTPRoute
    └── envoy-patch-policies.yaml       # EnvoyPatchPolicy for gzip + body size (not yet typed)
```

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

```bash
# Stage 1: Show ingress-nginx baseline
bash verify.sh nginx

# Stage 2: Option A — Istio proprietary
kubectl apply -f 03-istio-proprietary/
bash verify.sh istio-proprietary

# Stage 3: Option B — Istio + Gateway API
kubectl apply -f 04-istio-gateway-api/
bash verify.sh istio-gateway-api

# Stage 4: Option C — Envoy Gateway
kubectl apply -f 05-envoy-gateway/
bash verify.sh envoy-gateway

# Cutover — remove ingress-nginx after all stages verified
kubectl delete -f 02-ingress-nginx/
helm uninstall ingress-nginx -n ingress-nginx
```

## Prerequisites Summary

| Requirement | Minimum version | Check |
|---|---|---|
| Kubernetes | 1.28 | `kubectl version` |
| Helm | 3.12 | `helm version` |
| istioctl | 1.20 | `istioctl version` |
| Istio (in cluster) | 1.20 | `kubectl get pods -n istio-system` |
| Gateway API CRDs | v1.1.0 | `kubectl get crd gateways.gateway.networking.k8s.io` |
| Envoy Gateway | 1.1.0 | `kubectl get pods -n envoy-gateway-system` |
| LoadBalancer support | — | `kubectl get svc -A \| grep LoadBalancer` |

## Notes

- The `httpbin` app is sidecar-injected by default (namespace label set in `01-sample-app/httpbin.yaml`)
- All gateway options run in parallel during the demo — IPs differ, DNS/Host header is used to switch between them
- `verify.sh` tests all five key settings from the customer's ingress-nginx config at each stage
- `EnvoyPatchPolicies` in `05-envoy-gateway/envoy-patch-policies.yaml` require the listener to be running before applying — apply them last
