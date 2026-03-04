Here's a step-by-step test guide covering everything end-to-end:

Lab Test Runbook
Prerequisites

# Required tools
```
istioctl version --remote=false
helm version
kubectl version --client
jq --version

# Cluster must be 1.30+
kubectl version | grep "Server Version"
```
---

## Step 1 — Install everything

```
cd v3/lab/
bash lab-setup.sh
```
Validate install:
```
# All controllers Running
kubectl get pods -n istio-system        # istiod + istio-ingressgateway
kubectl get pods -n ingress-nginx       # ingress-nginx-controller
kubectl get pods -n envoy-gateway-system  # envoy-gateway-*

# All three controllers have LoadBalancer IPs assigned
kubectl get svc -A | grep LoadBalancer

# nginx-demo namespace exists and is injection-enabled
kubectl get namespace nginx-demo -o jsonpath='{.metadata.labels.istio-injection}'
# → enabled

# Sample app is up with sidecars (should show 2/2 for httpbin)
kubectl get pods -n nginx-demo
```

Expected pod counts:

|Namespace	|Pods|
| --- | --- |
|istio-system|istiod + istio-ingressgateway|
|ingress-nginx|	ingress-nginx-controller|
|envoy-gateway-system|	envoy-gateway-*|
|nginx-demo	|httpbin (2/2) + echoserver (1/1)|

---

## Step 2 — Baseline: ingress-nginx
```
kubectl apply -f 02-ingress-nginx/

# Wait for Ingress to get an address
kubectl get ingress -n nginx-demo --watch
# Ctrl-C when ADDRESS is populated

bash verify.sh nginx
# Expected: 4/4 passed
```

---

## Step 3 — Option A: Istio Proprietary API

Deploys a dedicated gateway pod — no shared `istio-ingressgateway` required.
```
kubectl apply -f 03-istio-proprietary/

# Wait for the dedicated gateway pod to be ready
kubectl get pods -n istio-system -l ingress=nginx-migration --watch
# Ctrl-C when Running/2/2

kubectl get svc nginx-migration-ingressgateway -n istio-system
# Must have an EXTERNAL-IP before verify.sh will work

bash verify.sh istio-proprietary
# Expected: 4/4 passed
```
Check EnvoyFilters applied:

```
kubectl get envoyfilter -n istio-system
# → nginx-migration-header-buffers, nginx-migration-max-body, nginx-migration-gzip, nginx-migration-access-log
```
If XFF test fails:
```
# XFF trust is baked into the Deployment pod template annotation — confirm it's present
kubectl get deployment nginx-migration-ingressgateway -n istio-system \
  -o jsonpath='{.spec.template.metadata.annotations.proxy\.istio\.io/config}'
# → {"gatewayTopology":{"numTrustedProxies":1}}

# If the pod is running but annotation is missing, re-apply and restart:
kubectl apply -f 03-istio-proprietary/deployment.yaml
kubectl rollout restart deployment nginx-migration-ingressgateway -n istio-system
kubectl rollout status deployment nginx-migration-ingressgateway -n istio-system
```

---

## Step 4 — Option B: Istio + Gateway API
```
kubectl apply -f 04-istio-gateway-api/

# Istio auto-provisions a pod — wait for it
kubectl get pods -n istio-system -l gateway.networking.k8s.io/gateway-name=demo-gateway --watch
# Ctrl-C when Running/2/2

kubectl get svc demo-gateway-istio -n istio-system
# Must have an EXTERNAL-IP before verify.sh will work

bash verify.sh istio-gateway-api
# Expected: 4/4 passed
```
If CERTIFICATE_VERIFY_FAILED / 503 on all requests:

```
# DestinationRule ISTIO_MUTUAL is required for auto-provisioned gateway pods
kubectl get destinationrule -n nginx-demo
# → httpbin, echoserver (both must exist)

# If missing, the httproute.yaml was applied without the destinationrule
kubectl apply -f 04-istio-gateway-api/
```

---

## Step 5 — Option C: Envoy Gateway
```
kubectl apply -f 05-envoy-gateway/envoy-gateway.yaml

# EnvoyPatchPolicies must be applied AFTER the gateway is Programmed
kubectl wait --for=condition=Programmed gateway demo-gateway-eg -n nginx-demo --timeout=60s

kubectl apply -f 05-envoy-gateway/envoy-patch-policies.yaml
```

Check patch policies actually attached:

```
kubectl get envoypatchpolicy -n nginx-demo
# All three should show PROGRAMMED: True

kubectl describe envoypatchpolicy gateway-gzip -n nginx-demo | grep -A 5 "Conditions:"

bash verify.sh envoy-gateway
# Expected: 4/4 passed
```
If gzip test fails:

```
# If EnvoyPatchPolicy was applied before gateway was Programmed, re-apply
kubectl delete envoypatchpolicy --all -n nginx-demo
kubectl wait --for=condition=Programmed gateway demo-gateway-eg -n nginx-demo --timeout=60s
kubectl apply -f 05-envoy-gateway/envoy-patch-policies.yaml
# Wait ~10s for xDS to propagate
sleep 10
bash verify.sh envoy-gateway
```

---

## Step 6 — Full suite check (all 4 stages)
Run all four stages back-to-back to confirm nothing regressed:

```
for stage in nginx istio-proprietary istio-gateway-api envoy-gateway; do
  echo ""
  echo ">>> Running: $stage"
  bash verify.sh $stage
done
```
All four should show 4 passed, 0 failed.

---

## Step 7 — Cutover (optional, end-of-test cleanup)
```
# Remove nginx routing — controller goes idle
kubectl delete -f 02-ingress-nginx/
kubectl get ingress -A  # → empty

# Uninstall nginx controller
helm uninstall ingress-nginx -n ingress-nginx

# Confirm chosen replacement still works after nginx is gone
bash verify.sh istio-gateway-api   # or whichever option you're keeping
```

---

## Quick diagnostics reference
```
# Pod restarts / CrashLoopBackOff
kubectl get pods -A | grep -v Running | grep -v Completed

# Sidecar not injected (shows 1/1 instead of 2/2)
kubectl get pods -n nginx-demo
kubectl rollout restart deployment -n nginx-demo

# Gateway not getting an IP
kubectl describe svc <svc-name> -n <namespace>  # look for Events

# EnvoyFilter not taking effect
kubectl get envoyfilter -n istio-system -o wide

# EnvoyPatchPolicy not applied
kubectl get envoypatchpolicy -n nginx-demo -o wide
kubectl describe envoypatchpolicy <name> -n nginx-demo
```