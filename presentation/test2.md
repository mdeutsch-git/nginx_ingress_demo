# Classic Ingress-NGINX Architecture
### Traffic Flow Demo

---
<!-- end_slide -->

## Components Overview

- **LoadBalancer Service** — External entry point (cloud LB / MetalLB)
- **ingress-nginx-controller** — Processes Ingress rules, proxies traffic
- **Ingress Resource** — Routing rules (host/path → backend service)
- **httpbin Service** — ClusterIP service in `nginx-demo` namespace
- **httpbin Pod** — The workload receiving requests

---
<!-- end_slide -->

## Traffic Flow Diagram

```
                        ┌─────────────────────────────────────────────────────┐
                        │              CLUSTER                                 │
                        │                                                      │
                        │  ┌──────────────────────────────────────────────┐   │
                        │  │  namespace: ingress-nginx                    │   │
                        │  │                                              │   │
  ┌──────────┐          │  │  ┌────────────────────────────────────────┐  │   │
  │          │  :443    │  │  │  ingress-nginx-controller (Pod)        │  │   │
  │  Client  │ ────────►│  │  │                                        │  │   │
  │          │          │  │  │  reads Ingress resources               │  │   │
  └──────────┘          │  │  │  across all namespaces                 │  │   │
                        │  │  └──────────────┬─────────────────────────┘  │   │
                        │  │                 │                             │   │
                        │  │  ┌──────────────▼─────────────────────────┐  │   │
                        │  │  │  Service: ingress-nginx-controller     │  │   │
                        │  │  │  type: LoadBalancer                    │  │   │
                        │  │  │  port: 80/443 → 10.0.0.5 (ext IP)     │  │   │
                        │  │  └────────────────────────────────────────┘  │   │
                        │  └──────────────────────────────────────────────┘   │
                        │                        │                             │
                        │                        │ routes via Ingress rule     │
                        │                        │ host: httpbin.example.com   │
                        │                        │ path: /                     │
                        │                        ▼                             │
                        │  ┌──────────────────────────────────────────────┐   │
                        │  │  namespace: nginx-demo                       │   │
                        │  │                                              │   │
                        │  │  ┌──────────────────────────────────────┐   │   │
                        │  │  │  Ingress Resource                    │   │   │
                        │  │  │  host: httpbin.example.com           │   │   │
                        │  │  │  path: /  →  httpbin-svc:80          │   │   │
                        │  │  └──────────────┬───────────────────────┘   │   │
                        │  │                 │                            │   │
                        │  │                 ▼                            │   │
                        │  │  ┌──────────────────────────────────────┐   │   │
                        │  │  │  Service: httpbin-svc                │   │   │
                        │  │  │  type: ClusterIP                     │   │   │
                        │  │  │  port: 80 → targetPort: 80           │   │   │
                        │  │  └──────────────┬───────────────────────┘   │   │
                        │  │                 │                            │   │
                        │  │                 ▼                            │   │
                        │  │  ┌──────────────────────────────────────┐   │   │
                        │  │  │  Pod: httpbin                        │   │   │
                        │  │  │  image: kennethreitz/httpbin         │   │   │
                        │  │  │  containerPort: 80                   │   │   │
                        │  │  └──────────────────────────────────────┘   │   │
                        │  └──────────────────────────────────────────────┘   │
                        └─────────────────────────────────────────────────────┘
```

<!-- end_slide -->

## Ingress Resource (nginx-demo namespace)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: httpbin-ingress
  namespace: nginx-demo
  annotations:
    kubernetes.io/ingress.class: "nginx"
spec:
  rules:
  - host: httpbin.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: httpbin-svc
            port:
              number: 80
```

---
<!-- end_slide -->

## LoadBalancer Service (ingress-nginx namespace)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: ingress-nginx
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
```

<!-- end_slide -->
---

## Request Trace

```
Client
  └─► 10.0.0.5:443  (LoadBalancer external IP)
        └─► ingress-nginx-controller Pod
              └─► reads Ingress rule: httpbin.example.com → httpbin-svc:80
                    └─► httpbin-svc.nginx-demo.svc.cluster.local:80
                          └─► Pod httpbin (containerPort: 80)
```
<!-- end_slide -->
---

## Key Observations

- Controller lives in `ingress-nginx` namespace, watches Ingress across **all** namespaces
- Traffic crosses namespace boundary: `ingress-nginx` → `nginx-demo`
- No sidecar proxies — traffic is **not** mTLS encrypted between controller and pod
- X-Forwarded-For header set by nginx controller (single hop)
- `ingressClassName` or annotation selects which controller handles the rule

---
<!-- end_slide -->
# Up Next

### Migrating to Istio Gateway + VirtualService

Same flow. Different control plane.
