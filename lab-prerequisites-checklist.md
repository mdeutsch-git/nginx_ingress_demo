# Lab Prerequisites Checklist

## 1. Local Tooling

- [ ] `kubectl` >= 1.28 — `kubectl version --client`
- [ ] `helm` >= 3.12 — `helm version`
- [ ] `istioctl` >= 1.20 — `istioctl version`
  - Install: `curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.20.0 sh -`
- [ ] `curl` — for endpoint testing
- [ ] `jq` — for parsing kubectl JSON output (optional but useful)

---

## 2. Kubernetes Cluster

- [ ] Kubernetes >= 1.28
- [ ] Minimum node capacity: **3 nodes, 4 vCPU / 8GB RAM each**
  - Istio control plane: ~1 vCPU / 1.5GB
  - ingress-nginx: ~0.5 vCPU / 256MB
  - Envoy Gateway: ~0.5 vCPU / 256MB
  - Sample app + load: ~0.5 vCPU / 512MB per replica
- [ ] LoadBalancer support (cloud LB, MetalLB, or `minikube tunnel` / `kind` with cloud-provider-kind)
- [ ] Default StorageClass present (for any PVC-backed components)
- [ ] `cluster-admin` permissions for the demo operator

### Verified cluster options

| Option | Notes |
|---|---|
| EKS / GKE / AKS | Preferred — native LoadBalancer support |
| `kind` | Use `cloud-provider-kind` for LB IPs |
| `minikube` | Run `minikube tunnel` in a separate terminal |
| k3d | Built-in LB via `--port` mappings |

---

## 3. Istio

- [ ] Istio >= 1.20 installed with `demo` or `default` profile
- [ ] `istiod` pod running in `istio-system`
- [ ] `istio-ingressgateway` deployment running in `istio-system`
- [ ] `istio-ingressgateway` has an external IP assigned

```bash
# Verify
kubectl get pods -n istio-system
kubectl get svc istio-ingressgateway -n istio-system
```

---

## 4. ingress-nginx (starting state)

- [ ] ingress-nginx >= 1.9 installed via Helm
- [ ] `ingress-nginx-controller` pod running
- [ ] Controller has an external IP assigned
- [ ] Demo ConfigMap applied (the one from the migration guide)

```bash
# Verify
kubectl get pods -n ingress-nginx
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

---

## 5. Gateway API CRDs

- [ ] Standard channel CRDs installed (covers Gateway, HTTPRoute, GRPCRoute)
- [ ] Experimental channel CRDs installed (covers TCPRoute, UDPRoute, BackendLBPolicy)

```bash
# Verify
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
```

---

## 6. Envoy Gateway (Option C)

- [ ] Envoy Gateway >= 1.0 installed via Helm
- [ ] `envoy-gateway` pod running in `envoy-gateway-system`
- [ ] `GatewayClass` `envoy-gateway` present and accepted

```bash
# Verify
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclass envoy-gateway
```

---

## 7. TLS Certificates

- [ ] Self-signed cert Secret created in `istio-system` (for demo TLS termination)
- [ ] Same Secret present in `envoy-gateway-system` (for Option C)
- [ ] OR cert-manager installed with a self-signed ClusterIssuer

---

## 8. Sample Application

- [ ] `httpbin` deployed in `default` namespace (used as the demo backend)
- [ ] `httpbin` Service exposed on port 80
- [ ] Namespace `default` labelled for Istio sidecar injection

```bash
# Verify sidecar injection label
kubectl get namespace default --show-labels | grep istio-injection
# Should show: istio-injection=enabled
```

---

## 9. DNS / Hosts (local demo)

For a local cluster without real DNS, add entries to `/etc/hosts`:

```
<INGRESS_NGINX_IP>   myapp.example.com
<ISTIO_GATEWAY_IP>   myapp.example.com
<ENVOY_GATEWAY_IP>   myapp.example.com
```

Update the IP as you cut over between controllers during the demo.

---

## 10. Pre-flight Verification

Run these before starting the demo:

```bash
# All expected pods running
kubectl get pods -n istio-system
kubectl get pods -n ingress-nginx
kubectl get pods -n envoy-gateway-system

# All controllers have external IPs
kubectl get svc -A | grep LoadBalancer

# Sample app responding through ingress-nginx (baseline)
curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: myapp.example.com" \
  http://$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')/get
# Expected: 200

# Gateway API CRDs present
kubectl get crd | grep gateway.networking.k8s.io | wc -l
# Expected: 6 (standard) or 13 (experimental)

# Istio sidecar injected into httpbin
kubectl get pod -n default -l app=httpbin -o jsonpath='{.items[0].spec.containers[*].name}'
# Expected includes: istio-proxy
```
