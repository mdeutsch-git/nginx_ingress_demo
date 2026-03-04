# Ingress Migration Guide: ingress-nginx → Istio / Envoy Gateway

> **Audience:** Platform/infrastructure teams currently running ingress-nginx with Istio already deployed, evaluating migration options.  
> **Scope:** Option analysis, side-by-side config equivalents, working YAML, and a demo walkthrough.

---

## Table of Contents

1. [Context and Problem Statement](#1-context-and-problem-statement)
2. [The Three Options](#2-the-three-options)
3. [Decision Framework](#3-decision-framework)
4. [Option A — Istio Proprietary API (Gateway + VirtualService)](#4-option-a--istio-proprietary-api)
5. [Option B — Istio with Gateway API (HTTPRoute)](#5-option-b--istio-with-gateway-api)
6. [Option C — Envoy Gateway (OSS)](#6-option-c--envoy-gateway-oss)
7. [Side-by-Side Config Equivalents](#7-side-by-side-config-equivalents)
8. [Migration Walkthrough: ingress-nginx → Istio](#8-migration-walkthrough-ingress-nginx--istio)
9. [Demo Script](#9-demo-script)

---

## 1. Context and Problem Statement

ingress-nginx works, but it has well-understood limitations that become friction points as platform maturity increases:

- **Configuration model is nginx, not Kubernetes.** Extensions require raw nginx config via `http-snippet` or `configuration-snippet` annotations. This is fragile, hard to validate, and a known security surface (arbitrary nginx directive injection).
- **`annotations-risk-level: Critical`** being set is a signal the team has already pushed past the intended safety guardrails to get features working. This is technical debt.
- **No native resilience primitives.** Retries, circuit breaking, and fault injection all require external tooling or nginx annotations with limited semantics.
- **End of active development trajectory.** The Kubernetes community's forward path is the Gateway API. ingress-nginx has no migration path to it.

**The existing Istio investment matters.** The cluster already has Envoy sidecars, mTLS, and observability in place. The question is not whether to change data planes — it's how to extend the existing Envoy investment to the ingress layer as well.

---

## 2. The Three Options

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         OPTION LANDSCAPE                                │
│                                                                         │
│  Already have:          Option A            Option B            Option C│
│  ┌──────────────┐       ┌────────────────┐  ┌────────────────┐  ┌──────┐│
│  │ ingress-nginx│──────▶│ Istio          │  │ Istio          │  │Envoy ││
│  │              │       │ Gateway +      │  │ GatewayClass + │  │Gateway│
│  │ + Istio mesh │       │ VirtualService │  │ HTTPRoute      │  │(OSS) ││
│  └──────────────┘       └────────────────┘  └────────────────┘  └──────┘│
│                         Proprietary API     Standard API         Standard│
│                         Fastest migration   Forward path         API +   │
│                         Familiar Istio UX   Portable             new CRDs│
└─────────────────────────────────────────────────────────────────────────┘
```

| | Option A | Option B | Option C |
|---|---|---|---|
| **API standard** | Istio proprietary | Gateway API (portable) | Gateway API (portable) |
| **Controller** | Istio (istiod) | Istio (istiod) | Envoy Gateway |
| **Data plane** | Envoy | Envoy | Envoy |
| **Mesh capabilities** | ✅ Full | ✅ Full | ❌ Ingress only |
| **Migration effort** | Lowest | Medium | Medium-High |
| **Future portability** | Low | High | High |
| **Extension model** | `EnvoyFilter` (raw xDS) | `EnvoyFilter` (raw xDS) | Typed policy CRDs + `EnvoyPatchPolicy` for gaps |

---

## 3. Decision Framework

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

---

## 4. Option A — Istio Proprietary API

### Resources involved

```
Gateway (networking.istio.io/v1beta1)
  └── defines listeners (port, protocol, TLS, hosts)

VirtualService (networking.istio.io/v1beta1)
  └── defines routing rules, rewrites, retries, timeouts, fault injection
  └── attaches to a Gateway by name

DestinationRule (networking.istio.io/v1beta1)
  └── defines upstream connection behaviour, circuit breaking, mTLS policy
```

### Working example

```yaml
# 1. Gateway — defines the ingress listener
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: my-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway       # targets the default istio ingress gateway pod
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "myapp.example.com"
      # No tls.httpsRedirect: true = equivalent to ssl-redirect: false
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: myapp-tls-cert   # references a Kubernetes Secret
      hosts:
        - "myapp.example.com"
```

```yaml
# 2. VirtualService — defines routing
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: myapp
  namespace: default
spec:
  hosts:
    - "myapp.example.com"
  gateways:
    - istio-system/my-gateway
  http:
    - match:
        - uri:
            prefix: "/api"
      route:
        - destination:
            host: myapp-service
            port:
              number: 8080
      timeout: 30s
      retries:
        attempts: 3
        perTryTimeout: 10s
        retryOn: "gateway-error,connect-failure,retriable-4xx"

    - route:                          # default catch-all
        - destination:
            host: myapp-service
            port:
              number: 8080
```

```yaml
# 3. DestinationRule — upstream connection tuning
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: myapp
  namespace: default
spec:
  host: myapp-service
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
    outlierDetection:               # circuit breaking
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

### DestinationRule — required for mTLS to sidecar-injected upstreams

When the ingress gateway connects to a service with Istio sidecar injection enabled, a
`DestinationRule` with `ISTIO_MUTUAL` is required. Without it the gateway fails with:
`TLS_error: CERTIFICATE_VERIFY_FAILED: SAN matcher`

`ISTIO_MUTUAL` lets Istio manage certificates and automatically derive the expected SPIFFE SAN
from the service namespace and service account — no manual SAN specification needed.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: myapp
  namespace: default
spec:
  host: myapp-service.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

> **After any Istio reinstall or upgrade:** Always restart sidecar-injected pods. The sidecar
> image is injected only at pod creation — existing pods keep their old proxy version and will
> fail mTLS handshakes against a newer control plane. The symptom is the same
> `CERTIFICATE_VERIFY_FAILED` error. `istioctl analyze` reports a proxy version mismatch warning.
> ```bash
> for ns in $(kubectl get namespace -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}'); do
>   kubectl rollout restart deployment -n $ns
> done
> ```

### Dedicated ingress gateway — isolating EnvoyFilter config from the shared gateway

By default, EnvoyFilters targeting `istio: ingressgateway` apply to the shared gateway that
all workloads use. If you want to isolate the migration-specific config (gzip, body size,
header buffers, log format) to a separate gateway without touching existing traffic, deploy
a dedicated ingress gateway with its own unique label and scope all EnvoyFilters to that label.

```
istio-ingressgateway              ← shared, untouched, existing traffic
nginx-migration-ingressgateway    ← isolated, carries migration EnvoyFilters only
```

The dedicated gateway is deployed as a standalone Deployment using `image: auto` and the
`inject.istio.io/templates: gateway` annotation — istiod fills in the correct proxy image
version automatically, avoiding the version mismatch problem that produces `CERTIFICATE_VERIFY_FAILED`.

```yaml
# Dedicated gateway pod — istiod manages its xDS config via the gateway injection template
metadata:
  labels:
    ingress: nginx-migration          # unique label — no overlap with shared gateway
  annotations:
    inject.istio.io/templates: gateway
spec:
  containers:
    - name: istio-proxy
      image: auto                     # istiod replaces with correct version at admission
```

All EnvoyFilters then target `ingress: nginx-migration` instead of `istio: ingressgateway`:

```yaml
spec:
  workloadSelector:
    labels:
      ingress: nginx-migration        # scoped to dedicated gateway only
```

The lab package includes a complete working example under
`03-istio-proprietary/dedicated-gateway/` with `deployment.yaml`, `rbac.yaml`,
`gateway.yaml`, and `envoyfilters-dedicated.yaml`.

### Extending beyond standard config — EnvoyFilter

For settings that don't have a native Istio CRD equivalent (gzip, body size limits, header buffer tuning), you use `EnvoyFilter`. See Section 7 for these configs.

---

## 5. Option B — Istio with Gateway API

### Resources involved

```
GatewayClass (gateway.networking.k8s.io/v1)
  └── cluster-scoped, defines which controller handles Gateways of this class

Gateway (gateway.networking.k8s.io/v1)
  └── defines listeners — owned by cluster operator

HTTPRoute (gateway.networking.k8s.io/v1)
  └── defines routing rules — owned by application teams
  └── attaches to Gateway via parentRefs

ReferenceGrant (gateway.networking.k8s.io/v1beta1)
  └── allows cross-namespace references (HTTPRoute → Service in another namespace)
```

The key structural difference from Option A is **separation of ownership**. The Gateway is a cluster-operator concern. HTTPRoutes are an application-team concern. They attach independently — no single resource ties them together, enabling true multi-tenancy.

### Working example

```yaml
# 1. GatewayClass — usually pre-installed, shown for completeness
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: istio
spec:
  controllerName: istio.io/gateway-controller
```

```yaml
# 2. Gateway — cluster operator manages this
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      hostname: "*.example.com"
      allowedRoutes:
        namespaces:
          from: All          # or Selector for restricted tenancy
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: myapp-tls-cert
            namespace: istio-system
      allowedRoutes:
        namespaces:
          from: All
```

```yaml
# 3. HTTPRoute — application team manages this, in their own namespace
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
      namespace: istio-system
      sectionName: http            # attaches to the specific listener
  hostnames:
    - "myapp.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/api"
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Source
                value: gateway
      backendRefs:
        - name: myapp-service
          port: 8080

    - backendRefs:                 # default catch-all
        - name: myapp-service
          port: 8080
```

```yaml
# 4. HTTPRoute with redirect (equivalent to ssl-redirect: true — shown for reference)
# To replicate ssl-redirect: false simply omit this entirely
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-redirect
  namespace: istio-system
spec:
  parentRefs:
    - name: my-gateway
      sectionName: http
  hostnames:
    - "myapp.example.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

### DestinationRule — more critical for Option B than Option A

When using Gateway API, Istio provisions a **new dedicated gateway Deployment** per `Gateway`
resource (named `<gateway-name>-istio`). Unlike `istio-ingressgateway` created by `istioctl install`,
this pod does not inherit mTLS defaults from the installation profile. A `DestinationRule` with
`ISTIO_MUTUAL` is required for every sidecar-injected upstream — without it you will see
`TLS_error: CERTIFICATE_VERIFY_FAILED: SAN matcher` on every request.

Apply the same `DestinationRule` shown in the Option A section for each upstream service.

### Istio-specific extensions still needed

Gateway API covers routing. For Istio-specific resilience (circuit breaking, outlier detection) you still use DestinationRule alongside HTTPRoute — this is intentional, DestinationRule is upstream policy and the Gateway API has a separate `BackendLBPolicy` spec for some of this, but Istio's DestinationRule remains the practical tool today.

---

## 6. Option C — Envoy Gateway (OSS)

### What it is and is not

Envoy Gateway is a Kubernetes-native implementation of the Gateway API backed by Envoy. It is:
- **An ingress/API gateway controller** — north-south traffic only
- **A first-class Gateway API implementation** — same `GatewayClass`, `Gateway`, `HTTPRoute` resources as Option B
- **A purpose-built extension layer** — typed policy CRDs replace raw xDS patching for most common cases

It is not:
- A service mesh — no sidecar injection, no east-west mTLS, no distributed tracing across services
- A replacement for Istio if you need mesh capabilities

### The extension CRDs

```
ClientTrafficPolicy     — how Envoy handles inbound client connections
                          (XFF, header buffer limits, proxy protocol, HTTP/1/2/3 settings)

BackendTrafficPolicy    — how Envoy handles connections to upstreams
                          (retries, timeouts, circuit breaking, rate limiting, health checks)

SecurityPolicy          — auth at the gateway
                          (JWT validation, OIDC, Basic Auth, API key)

BackendTLSPolicy        — TLS configuration toward upstreams
                          (cert validation, SNI, mTLS)

EnvoyPatchPolicy        — raw xDS escape hatch (equivalent to Istio's EnvoyFilter)
```

### Working example

```yaml
# 1. GatewayClass
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: my-proxy-config
    namespace: envoy-gateway-system
```

```yaml
# 2. EnvoyProxy — cluster-wide proxy configuration, telemetry, logging
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: my-proxy-config
  namespace: envoy-gateway-system
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: >
              %REQ(X-FORWARDED-FOR)% (xff) -
              %DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT% (client) -
              [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%"
              %RESPONSE_CODE% %BYTES_SENT% "%REQ(REFERER)%" "%REQ(USER-AGENT)%"
              %BYTES_RECEIVED% %DURATION% %RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)% %UPSTREAM_HOST%
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

```yaml
# 3. Gateway
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      hostname: "myapp.example.com"
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "myapp.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: myapp-tls-cert
```

```yaml
# 4. ClientTrafficPolicy — replaces several EnvoyFilter patches
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: client-policy
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1          # replaces compute-full-forwarded-for + use-forwarded-headers
  # Note: header size limits (max_request_headers_kb) are NOT available as a typed field
  # in ClientTrafficPolicy — use EnvoyPatchPolicy instead (see Section 7)
  http1:
    enableTrailers: false
```

```yaml
# 5. BackendTrafficPolicy — resilience config per route target
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: backend-policy
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: myapp
  retry:
    numRetries: 3
    perRetry:
      timeout: 10s
    retryOn:
      triggers:
        - "5xx"
        - "gateway-error"
        - "connect-failure"
  timeout:
    http:
      requestTimeout: 30s
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 1024
    maxParallelRequests: 1024
    maxParallelRetries: 3
```

```yaml
# 6. SecurityPolicy — JWT auth example (no ingress-nginx equivalent without external plugin)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: jwt-policy
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: myapp
  jwt:
    providers:
      - name: my-idp
        issuer: "https://auth.example.com"
        remoteJWKS:
          uri: "https://auth.example.com/.well-known/jwks.json"
```

```yaml
# 7. HTTPRoute — identical to Option B, demonstrating portability
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
      namespace: default
  hostnames:
    - "myapp.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: "/api"
      backendRefs:
        - name: myapp-service
          port: 8080
    - backendRefs:
        - name: myapp-service
          port: 8080
```

---

## 7. Side-by-Side Config Equivalents

The following table maps each ingress-nginx setting to its equivalent in all three options.

### XFF / Trusted Proxies

**ingress-nginx:**
```yaml
config:
  compute-full-forwarded-for: "true"
  use-forwarded-headers: "true"
  http-snippet: |
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

**Option A & B — Istio:**

> **Do not apply a raw ConfigMap.** Replacing the `istio` ConfigMap clobbers all existing
> mesh settings (mTLS, tracing, proxy defaults). Use `istioctl install --set` which merges
> only the specified field into the existing IstioOperator configuration.

```bash
# For existing clusters
istioctl install \
  --set meshConfig.defaultConfig.gatewayTopology.numTrustedProxies=1 \
  -y

# For fresh installs — chain onto the initial install
istioctl install --set profile=default \
  --set meshConfig.defaultConfig.gatewayTopology.numTrustedProxies=1 \
  -y
```

> **Header name change:** After enabling this, the trusted client IP is exposed as
> `X-Envoy-External-Address` in upstream services — not `X-Forwarded-For`. Istio intentionally
> strips the raw XFF header on internal mesh hops as a security property. Applications reading
> `X-Forwarded-For` for the original client IP must be updated.
>
> | Option | Header seen by upstream application |
> |---|---|
> | ingress-nginx | `X-Original-Forwarded-For` (original XFF renamed) |
> | Istio (A & B) | `X-Envoy-External-Address` (XFF consumed at edge, stripped internally) |
> | Envoy Gateway (C) | `X-Forwarded-For` (appended and forwarded — traditional behaviour) |

**Option C — Envoy Gateway (ClientTrafficPolicy):**
```yaml
spec:
  clientIPDetection:
    xForwardedFor:
      numTrustedHops: 1
```

---

### Header Buffer Size

> **The nginx and Envoy buffer models are not equivalent.**
>
> nginx uses a two-tier, per-header-field model: `client-header-buffer-size` is the initial
> buffer; `large-client-header-buffers: 4 100k` is an overflow pool of up to 4 additional
> buffers each capped at 100k. Each **individual header field** must fit within one buffer —
> a single 150k header is rejected even though 4 × 100k = 400k aggregate total.
>
> Envoy's `max_request_headers_kb` is a single ceiling on the **combined size of all headers**.
> Setting it to `100` is the correct equivalent — it matches nginx's per-field ceiling of 100k.

**ingress-nginx:**
```yaml
config:
  client-header-buffer-size: 100k
  large-client-header-buffers: 4 100k
```

**Option A & B — Istio (EnvoyFilter):**
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: gateway-header-buffers
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      istio: ingressgateway
  configPatches:
    - applyTo: NETWORK_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: MERGE
        value:
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            max_request_headers_kb: 100
```

**Option C — Envoy Gateway (EnvoyPatchPolicy):**

> **`maxRequestHeadersKb` does not exist in `ClientTrafficPolicy`.** The `HeaderSettings`
> type only covers early/late header modification and underscore handling — there is no typed
> field for request header size limits. This requires `EnvoyPatchPolicy`, the same escape
> hatch needed for gzip. This is a genuine gap in the typed CRD surface for Option C.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyPatchPolicy
metadata:
  name: max-request-headers
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
  type: JSONPatch
  jsonPatches:
    - type: "type.googleapis.com/envoy.config.listener.v3.Listener"
      name: "default/my-gateway/http"
      operation:
        op: add
        path: "/default_filter_chain/filters/0/typed_config/max_request_headers_kb"
        value: 100    # matches nginx per-field ceiling (100k per header field)
```

---

### Max Request Body Size (proxy-body-size: 300m)

**ingress-nginx:**
```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-body-size: 300m
```

**Option A & B — Istio (EnvoyFilter):**
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: gateway-max-body
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      istio: ingressgateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.buffer
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.buffer.v3.Buffer
            max_request_bytes: 314572800   # 300 * 1024 * 1024
```

**Option C — Envoy Gateway (EnvoyPatchPolicy):**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyPatchPolicy
metadata:
  name: max-body-size
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: my-gateway
  type: JSONPatch
  jsonPatches:
    - type: "type.googleapis.com/envoy.config.listener.v3.Listener"
      name: "default/my-gateway/http"
      operation:
        op: add
        path: "/filter_chains/0/filters/0/typed_config/http_filters/0"
        value:
          name: envoy.filters.http.buffer
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.buffer.v3.Buffer
            max_request_bytes: 314572800
```

---

### Gzip Compression

**ingress-nginx:**
```yaml
config:
  use-gzip: "true"
  gzip-types: application/json
```

**Option A & B — Istio (EnvoyFilter):**
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: gateway-gzip
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      istio: ingressgateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.compressor
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.compressor.v3.Compressor
            response_direction_config:
              common_config:
                min_content_length: 100     # lowered for lab (production default: 1024)
                content_type:
                  - application/json
            compressor_library:
              name: envoy.compression.gzip.compressor
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.compression.gzip.compressor.v3.Gzip
```

**Option C — Envoy Gateway (EnvoyPatchPolicy):**
Same xDS config as above, wrapped in `EnvoyPatchPolicy` instead of `EnvoyFilter`. Gzip is not yet a typed policy field in Envoy Gateway — this is one area where the escape hatch is still needed.

---

### Access Log Format

**ingress-nginx:**
```yaml
config:
  log-format-upstream: $http_x_forwarded_for (xff) - $remote_addr (client) ...
```

**Option A & B — Istio (EnvoyFilter):**

> **Do not use the Telemetry API with an inline format string.** The `Telemetry` v1alpha1 API
> requires a named `extensionProvider` registered in MeshConfig first. Applying it with an
> inline format string returns:
> `strict decoding error: unknown field "spec.accessLogging[0].format"`
>
> Use an EnvoyFilter patching the HCM directly instead — this is version-agnostic and requires
> no additional MeshConfig setup.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: gateway-access-log
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      istio: ingressgateway
  configPatches:
    - applyTo: NETWORK_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: MERGE
        value:
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
            access_log:
              - name: envoy.access_loggers.stream
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
                  log_format:
                    text_format_source:
                      inline_string: "%REQ(X-FORWARDED-FOR)% (xff) - %DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT% (client) - [%START_TIME%] \"%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\" %RESPONSE_CODE% %BYTES_SENT% \"%REQ(REFERER)%\" \"%REQ(USER-AGENT)%\" %BYTES_RECEIVED% %DURATION% %RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)% %UPSTREAM_HOST%\n"
```

**Option C — Envoy Gateway (EnvoyProxy):**
```yaml
spec:
  telemetry:
    accessLog:
      settings:
        - format:
            type: Text
            text: "%REQ(X-FORWARDED-FOR)% (xff) - %DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT% (client) ..."
```

---

### SSL Redirect (disabled)

**ingress-nginx:**
```yaml
annotations:
  nginx.ingress.kubernetes.io/ssl-redirect: "false"
```

**Option A — Istio Gateway:**
```yaml
# Simply omit tls.httpsRedirect: true on the HTTP server block
servers:
  - port:
      number: 80
      protocol: HTTP
    hosts:
      - "myapp.example.com"
    # No tls block = no redirect
```

**Option B & C — HTTPRoute:**
```yaml
# Simply do not add a redirect filter to the HTTP HTTPRoute
# Absence of this filter = ssl-redirect: false:
#   filters:
#     - type: RequestRedirect
#       requestRedirect:
#         scheme: https
```

---

### Variable name reference: nginx → Envoy

| nginx variable | Envoy access log command |
|---|---|
| `$http_x_forwarded_for` | `%REQ(X-FORWARDED-FOR)%` |
| `$remote_addr` | `%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%` |
| `$remote_user` | `%REQ(:authority)%` |
| `$time_local` | `%START_TIME%` |
| `$request` | `%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%` |
| `$status` | `%RESPONSE_CODE%` |
| `$body_bytes_sent` | `%BYTES_SENT%` |
| `$http_referer` | `%REQ(REFERER)%` |
| `$http_user_agent` | `%REQ(USER-AGENT)%` |
| `$request_length` | `%BYTES_RECEIVED%` |
| `$request_time` | `%DURATION%` |
| `$upstream_response_time` | `%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%` |
| `$upstream_addr` | `%UPSTREAM_HOST%` |

---

## 8. Migration Walkthrough: ingress-nginx → Istio

This walkthrough assumes Istio is already installed and the `istio-ingressgateway` pod is running. We follow Option B (Gateway API) as the recommended target state, with notes on where Option A differs.

### Phase 1: Audit existing Ingress resources

Before writing any new config, map every Ingress resource to understand the full scope:

```bash
# List all Ingress resources across namespaces
kubectl get ingress -A

# For each ingress, capture annotations in use
kubectl get ingress <name> -n <namespace> -o yaml | grep -A20 "annotations:"
```

Build an inventory:

| Ingress name | Namespace | Host | TLS | Key annotations |
|---|---|---|---|---|
| myapp | default | myapp.example.com | Yes | proxy-body-size, ssl-redirect |
| api | backend | api.example.com | Yes | proxy-connect-timeout |

### Phase 2: Install Gateway API CRDs (if not present)

```bash
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

For Istio with experimental Gateway API features (TCPRoute, GRPCRoute):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/experimental-install.yaml
```

### Phase 3: Create the Gateway

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: istio-system
  annotations:
    # Request an external load balancer IP — same as ingress-nginx behaviour
    networking.istio.io/service-type: LoadBalancer
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      hostname: "*.example.com"
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls-cert
            namespace: istio-system
      allowedRoutes:
        namespaces:
          from: All
```

```bash
kubectl apply -f gateway.yaml

# Verify the gateway gets an IP
kubectl get gateway main-gateway -n istio-system
```

### Phase 4: Migrate Ingress resources to HTTPRoute

For each Ingress, create an equivalent HTTPRoute. The mapping is direct:

**Before (Ingress):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 300m
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myapp.example.com
      secretName: myapp-tls
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 8080
```

**After (HTTPRoute):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: default
spec:
  parentRefs:
    - name: main-gateway
      namespace: istio-system
  hostnames:
    - "myapp.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: myapp-service
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-service
          port: 8080
```

> **proxy-body-size:** Handled by EnvoyFilter (see Section 7) applied to the gateway, not per-route.  
> **ssl-redirect: false:** Handled by the absence of a redirect filter — the HTTPRoute above serves HTTP without redirecting.

### Phase 5: Apply EnvoyFilters for advanced config

Apply the EnvoyFilter resources from Section 7 for any settings that don't have native CRD support: body size limits, header buffers, gzip, and log format.

```bash
kubectl apply -f envoyfilter-header-buffers.yaml
kubectl apply -f envoyfilter-max-body.yaml
kubectl apply -f envoyfilter-gzip.yaml
kubectl apply -f telemetry-access-log.yaml
```

### Phase 6: Update MeshConfig for XFF

> **Do not use `kubectl edit` on the `istio` ConfigMap.** The `mesh` field is a multi-line
> string — editing it replaces the entire value and silently drops all existing settings
> (mTLS, tracing, proxy defaults).

```bash
istioctl install \
  --set meshConfig.defaultConfig.gatewayTopology.numTrustedProxies=1 \
  -y
```

Restart the ingress gateway to pick up the change:
```bash
kubectl rollout restart deployment istio-ingressgateway -n istio-system
```

> **Application impact:** After this change, upstream services receive the trusted client IP
> as `X-Envoy-External-Address`, not `X-Forwarded-For`. Istio strips the raw XFF header on
> internal mesh hops by design. Any application code reading `X-Forwarded-For` for the
> original client IP must be updated to read `X-Envoy-External-Address` instead.

### Phase 7: Cutover

Run both ingress controllers in parallel before cutting over DNS.

```bash
# Get the new Gateway IP
NEW_IP=$(kubectl get gateway main-gateway -n istio-system \
  -o jsonpath='{.status.addresses[0].value}')

# Test against the new gateway with a Host header before DNS change
curl -H "Host: myapp.example.com" http://$NEW_IP/api/health

# Once verified, update DNS to point to $NEW_IP
# Then remove the old Ingress resources
kubectl delete ingress myapp -n default

# Finally, remove ingress-nginx once all routes are migrated
helm uninstall ingress-nginx -n ingress-nginx
```

---

## 9. Demo Script

> **Format:** Verbal walkthrough for a technical audience. Estimated time: 20–25 minutes.  
> **Setup:** A cluster with Istio installed, ingress-nginx running alongside, and a sample app deployed.

---

### Opening (2 min)

> "Today we're going to walk through what it looks like to migrate off ingress-nginx when you already have Istio in place. This isn't a theoretical discussion — we'll look at real configs and a live migration.
>
> The question we're answering isn't 'should we use Envoy' — you already are. Every time a request hits your ingress-nginx controller, Envoy sidecars are handling the internal traffic. What we're doing today is extending that same data plane to the edge, and deciding how we want to manage it."

---

### Section 1: What's wrong with the current state (3 min)

Show the current ingress-nginx ConfigMap:

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

---

### Section 2: Option A — Istio Proprietary API (5 min)

> "Because you already have Istio, the fastest path is Option A — replacing the Ingress resource with an Istio Gateway and VirtualService. The ingress-nginx controller goes away, the Istio ingress gateway takes over."

Apply and show:

```bash
kubectl apply -f gateway-istio-proprietary.yaml
kubectl apply -f virtualservice.yaml
kubectl get gateway,virtualservice -n istio-system
```

> "The Gateway defines the listener — port, protocol, TLS, which hosts to accept. The VirtualService defines how to route traffic once it's accepted. These are two separate resources, which lets you change routing without touching the listener config.
>
> Where does this fall short? The extension model. If I need gzip, or the 300m body limit, I'm writing an EnvoyFilter — raw xDS config wrapped in a Kubernetes resource. It's powerful but unvalidated. A typo here silently breaks the gateway."

Show an EnvoyFilter:
```bash
kubectl apply -f envoyfilter-max-body.yaml
kubectl describe envoyfilter gateway-max-body -n istio-system
```

> "This is where Option A lives — powerful, fast to adopt, but the extension story is rough edges."

---

### Section 3: Option B — Istio with Gateway API (5 min)

> "Option B uses the same Istio control plane, same Envoy data plane, but swaps the API to the Kubernetes-standard Gateway API. The reason this matters isn't technical — it's operational."

Apply and show:

```bash
kubectl apply -f gateway-api.yaml
kubectl apply -f httproute.yaml
kubectl get gateway,httproute -A
```

> "Two things I want to highlight.
>
> First — `allowedRoutes.namespaces.from: All`. This is the cluster operator saying 'any namespace can attach routes to this gateway.' If I set this to `Selector`, only specific namespaces can. ingress-nginx has no equivalent — any namespace can create an Ingress and it goes through the same controller.
>
> Second — the HTTPRoute is in the `default` namespace. The Gateway is in `istio-system`. Different teams own these. The application team writes the HTTPRoute; the platform team writes the Gateway. No overlap, no stepping on each other.
>
> The EnvoyFilter story is the same as Option A — still raw xDS for anything beyond routing. That's the honest limitation."

---

### Section 4: Option C — Envoy Gateway (5 min)

> "Envoy Gateway is a separate controller. It's not Istio. It doesn't do service mesh. But it implements the same Gateway API — meaning the HTTPRoute we just wrote works unchanged against it.
>
> The reason to consider it alongside Istio is the extension model. Watch this."

Show ClientTrafficPolicy vs EnvoyFilter side by side:

```bash
# What Istio needs for header buffer config:
cat envoyfilter-header-buffers.yaml

# What Envoy Gateway needs:
cat client-traffic-policy.yaml
```

> "Same outcome. One is raw xDS — `envoy.filters.network.http_connection_manager`, `typed_config`, manually constructing the protobuf type URL. The other is a typed Kubernetes CRD. It's validated, it's readable, it has docs.
>
> `ClientTrafficPolicy` covers XFF trust, header buffer limits, proxy protocol, HTTP/1/HTTP/2/HTTP/3 settings. `BackendTrafficPolicy` covers retries, timeouts, circuit breaking, rate limiting — all native. No xDS patches for the common 80% of cases.
>
> The tradeoff: you're running two controllers. Istio for your mesh, Envoy Gateway for your ingress. That's more to operate. Whether that's worth it depends on how much time your team spends writing and debugging EnvoyFilters."

---

### Section 5: Live cutover demo (5 min)

```bash
# Show both running in parallel
kubectl get pods -n istio-system | grep ingressgateway
kubectl get pods -n envoy-gateway-system

# Get both IPs
echo "nginx: $(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "new:   $(kubectl get gateway main-gateway -n istio-system \
  -o jsonpath='{.status.addresses[0].value}')"

# Test against new gateway
curl -H "Host: myapp.example.com" http://<NEW_IP>/api/health

# Show access log format is correct
kubectl logs -n istio-system -l istio=ingressgateway --tail=5
```

> "Traffic is flowing through the new gateway. DNS isn't changed yet — we're testing with a Host header directly against the IP. This is the validation step before cutover.
>
> Once DNS is updated and we've verified in production, the ingress-nginx resources come down. The Ingress objects, the controller, the ConfigMap — all of it."

```bash
kubectl delete ingress myapp -n default
# Don't remove ingress-nginx controller until all ingresses are migrated
kubectl get ingress -A   # Should return empty
helm uninstall ingress-nginx -n ingress-nginx
```

---

### Close (1 min)

> "Three options, one data plane. You're not changing what handles your traffic — Envoy is already there. What you're changing is how you tell it what to do.
>
> Option A is the fastest migration but not the final state. Option B is the right foundation if Istio is your long-term platform. Option C is worth evaluating if your team is spending meaningful time on EnvoyFilters and you want a cleaner separation of concerns between mesh and ingress.
>
> The configs we walked through today are all in the repo — Gateway, HTTPRoute, EnvoyFilter equivalents, and the ClientTrafficPolicy alternatives. Start with Option B, keep Option C in your back pocket."
