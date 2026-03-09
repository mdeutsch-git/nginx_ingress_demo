---
title: Ingress Architecture Patterns
sub_title: Istio Proprietary · Istio Gateway API · Envoy Gateway
author: Max
---

# Agenda

- **Pattern 1** — Istio Proprietary (Gateway + VirtualService)
- **Pattern 2** — Istio with Kubernetes Gateway API
- **Pattern 3** — Envoy Gateway (standalone)

All patterns expose the same `httpbin` workload in `demo` namespace.

<!-- end_slide -->

# Pattern 1: Istio Proprietary Gateway

**Resources:** `Gateway` + `VirtualService` (Istio CRDs)

```
                     ┌──────────────────────────────────────────────────────────────────┐
                     │  CLUSTER                                                         │
                     │                                                                  │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  namespace: istio-system                                    │ │
                     │  │                                                             │ │
  ┌──────────┐       │  │  ┌───────────────────────────────────────────────────────┐  │ │
  │          │ :443  │  │  │  istio-ingressgateway (Pod)                           │  │ │
  │  Client  │──────►│  │  │  Envoy proxy — acts on Gateway + VirtualService rules │  │ │
  │          │       │  │  └───────────────────────┬───────────────────────────────┘  │ │
  └──────────┘       │  │                           │                                 │ │
                     │  │  ┌────────────────────────▼──────────────────────────────┐  │ │
                     │  │  │  Service: istio-ingressgateway                        │  │ │
                     │  │  │  type: LoadBalancer                                   │  │ │
                     │  │  └────────────────────────────────────────────────────── ┘  │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     │                             │                                    │
                     │         ┌───────────────────┘                                    │
                     │         │  matches Gateway + VirtualService rules                │
                     │         │  host: httpbin.example.com / path: /                   │
                     │         ▼                                                        │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  namespace: demo                                            │ │
                     │  │                                                             │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Gateway (Istio CRD)                                 │   │ │
                     │  │  │  selector: istio: ingressgateway                     │   │ │
                     │  │  │  port: 443 / protocol: HTTPS                         │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  │                                                             │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  VirtualService                                      │   │ │
                     │  │  │  gateways: [demo/httpbin-gateway]                    │   │ │
                     │  │  │  hosts: [httpbin.example.com]                        │   │ │
                     │  │  │  route → httpbin-svc:80                              │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Service: httpbin-svc  (ClusterIP :80)               │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Pod: httpbin  [sidecar: envoy proxy]                │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     └──────────────────────────────────────────────────────────────────┘
```

<!-- end_slide -->

# Pattern 1: Key Resources

```yaml
# Gateway — lives in demo namespace, selects istio-ingressgateway pod
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
spec:
  selector:
    istio: ingressgateway          # targets pod in istio-system
  servers:
  - port:
      number: 80
      protocol: HTTP
    hosts: ["httpbin.example.com"]
---
# VirtualService — wires host to backend service
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: httpbin-vs
  namespace: demo
spec:
  hosts: ["httpbin.example.com"]
  gateways: ["demo/httpbin-gateway"]
  http:
  - route:
    - destination:
        host: httpbin-svc
        port:
          number: 80
```

<!-- end_slide -->

# Pattern 2: Istio with Kubernetes Gateway API

**Resources:** `GatewayClass` + `Gateway` + `HTTPRoute` (sig-network CRDs)

```
                     ┌──────────────────────────────────────────────────────────────────┐
                     │  CLUSTER                                                         │
                     │                                                                  │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  cluster-scoped                                             │ │
                     │  │                                                             │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  GatewayClass                                        │   │ │
                     │  │  │  name: istio                                         │   │ │
                     │  │  │  controllerName: istio.io/gateway-controller         │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     │                             │                                    │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  namespace: demo                                            │ │
                     │  │                                                             │ │
  ┌──────────┐       │  │  ┌──────────────────────────────────────────────────────┐   │ │
  │          │ :80   │  │  │  Gateway (k8s Gateway API)                           │   │ │
  │  Client  │──────►│  │  │  gatewayClassName: istio                             │   │ │
  │          │       │  │  │  listeners: port 80 / HTTP                           │   │ │
  └──────────┘       │  │  │                                                      │   │ │
                     │  │  │  ► Istio provisions an Envoy pod + LB Service here   │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │  ┌────────────────────────▼─────────────────────────────┐   │ │
                     │  │  │  HTTPRoute                                           │   │ │
                     │  │  │  parentRefs: [demo/httpbin-gateway]                  │   │ │
                     │  │  │  hostnames: [httpbin.example.com]                    │   │ │
                     │  │  │  rules: path / → backendRef httpbin-svc:80           │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Service: httpbin-svc  (ClusterIP :80)               │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Pod: httpbin  [sidecar: envoy proxy]                │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     └──────────────────────────────────────────────────────────────────┘
```

<!-- end_slide -->

# Pattern 2: Key Resources

```yaml
# GatewayClass — cluster-scoped, points to Istio controller
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: istio
spec:
  controllerName: istio.io/gateway-controller
---
# Gateway — Istio provisions Envoy pod + LB Service automatically
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
# HTTPRoute — standard k8s routing rule
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: demo
spec:
  parentRefs:
  - name: httpbin-gateway
  hostnames: ["httpbin.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin-svc
      port: 80
```

<!-- end_slide -->

# Pattern 3: Envoy Gateway (Standalone)

**Resources:** `GatewayClass` + `Gateway` + `HTTPRoute` (same API, different controller)

```
                     ┌──────────────────────────────────────────────────────────────────┐
                     │  CLUSTER                                                         │
                     │                                                                  │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  cluster-scoped                                             │ │
                     │  │                                                             │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  GatewayClass                                        │   │ │
                     │  │  │  name: eg                                            │   │ │
                     │  │  │  controllerName: gateway.envoyproxy.io/gatewayclass  │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     │                                                                  │
                     │  ┌─────────────────────────────────────────────────────────────┐ │
                     │  │  namespace: envoy-gateway-system                            │ │
                     │  │                                                             │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  envoy-gateway (control plane)                       │   │ │
                     │  │  │  watches Gateway + HTTPRoute resources               │   │ │
                     │  │  │  programs Envoy proxy data plane via xDS             │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     │                             │  xDS                               │
  ┌──────────┐       │  ┌──────────────────────────▼──────────────────────────────────┐ │
  │          │ :80   │  │  namespace: demo                                            │ │
  │  Client  │──────►│  │                                                             │ │
  │          │       │  │  ┌──────────────────────────────────────────────────────┐   │ │
  └──────────┘       │  │  │  Gateway (k8s Gateway API)                           │   │ │
                     │  │  │  gatewayClassName: eg                                │   │ │
                     │  │  │  listeners: port 80 / HTTP                           │   │ │
                     │  │  │                                                      │   │ │
                     │  │  │  ► EG provisions dedicated Envoy pod + LB Service    │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │  ┌────────────────────────▼─────────────────────────────┐   │ │
                     │  │  │  HTTPRoute                                           │   │ │
                     │  │  │  parentRefs: [demo/httpbin-gateway]                  │   │ │
                     │  │  │  hostnames: [httpbin.example.com]                    │   │ │
                     │  │  │  rules: path / → backendRef httpbin-svc:80           │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Service: httpbin-svc  (ClusterIP :80)               │   │ │
                     │  │  └────────────────────────┬─────────────────────────────┘   │ │
                     │  │                           │                                 │ │
                     │  │                           ▼                                 │ │
                     │  │  ┌──────────────────────────────────────────────────────┐   │ │
                     │  │  │  Pod: httpbin  [NO sidecar — no mesh]                │   │ │
                     │  │  └──────────────────────────────────────────────────────┘   │ │
                     │  └─────────────────────────────────────────────────────────────┘ │
                     └──────────────────────────────────────────────────────────────────┘
```

<!-- end_slide -->

# Pattern 3: Key Resources

```yaml
# GatewayClass — points to Envoy Gateway controller
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass
---
# Gateway — EG provisions its own Envoy pod + LB Service
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: demo
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
# HTTPRoute — identical structure to Istio Gateway API pattern
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: demo
spec:
  parentRefs:
  - name: httpbin-gateway
  hostnames: ["httpbin.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: httpbin-svc
      port: 80
```

<!-- end_slide -->

# Side-by-Side Comparison

```
┌──────────────────────┬─────────────────────┬──────────────────────┬──────────────────────┐
│                      │  Istio Proprietary  │  Istio + Gateway API │  Envoy Gateway       │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  Routing CRDs        │  Gateway            │  Gateway (k8s)       │  Gateway (k8s)       │
│                      │  VirtualService     │  HTTPRoute           │  HTTPRoute           │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  Controller          │  istiod             │  istiod              │  envoy-gateway       │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  Data plane          │  Envoy (shared pod) │  Envoy (dedicated)   │  Envoy (dedicated)   │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  Sidecar mesh        │  Yes                │  Yes                 │  No (ingress only)   │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  mTLS (pod-to-pod)   │  Yes                │  Yes                 │  No                  │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  API standard        │  Istio-specific     │  K8s sig-network     │  K8s sig-network     │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  Portability         │  Istio only         │  Controller-agnostic │  Controller-agnostic │
├──────────────────────┼─────────────────────┼──────────────────────┼──────────────────────┤
│  XFF handling        │  numTrustedProxies  │  numTrustedProxies   │  ClientIPDetection   │
└──────────────────────┴─────────────────────┴──────────────────────┴──────────────────────┘
```

**Key takeaway:** Patterns 2 and 3 use identical routing YAML — only `gatewayClassName` differs.

<!-- end_slide -->

# Up Next

### Live Demo

Watch the same `httpbin` request flow through each pattern.

```bash
curl -H "Host: httpbin.example.com" http://<LB_IP>/get
```