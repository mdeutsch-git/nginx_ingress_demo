#!/usr/bin/env bash
# lab-setup.sh — installs all prerequisites for the ingress migration lab
# Run once before starting the demo
# Usage: bash lab-setup.sh
#
# Prerequisites:
#   - Istio installed and istiod running in istio-system (TSB-managed is supported)
#   - kubectl and helm available on PATH
#
# Stateless design notes:
#   - TLS secrets: idempotent (kubectl create --dry-run | apply)
#   - ingress-nginx/EG: all via helm upgrade --install (idempotent)
#   - XFF patch on istio-ingressgateway: conditional, skipped if annotation already set
#   - Istio: pre-installed (by TSB or standalone) — this script only labels the lab
#     namespace for sidecar injection via the standard istio-injection=enabled label.

set -euo pipefail

# Ensure relative paths work regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EG_VERSION="1.7.0"
GATEWAY_API_VERSION="v1.5.0"

if ! command -v helm &>/dev/null; then
  echo "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> [1/6] Installing Gateway API CRDs (experimental channel)"
# Remove the safe-upgrades policy that blocks standard→experimental channel upgrades
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl apply --server-side --force-conflicts -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "==> [2/6] Configuring lab namespace for Istio sidecar injection"
# Istio is pre-installed — create the namespace and enable injection.
# TSB's webhook respects istio-injection=enabled on a clean cluster.
kubectl create namespace nginx-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace nginx-demo istio-injection=enabled --overwrite

echo "  Restarting lab pods in 'nginx-demo' to pick up current sidecar image..."
# || true: no-op if no deployments exist yet on first run
kubectl rollout restart deployment -n nginx-demo 2>/dev/null || true
kubectl rollout status deployment -n nginx-demo --timeout=120s 2>/dev/null || true

# XFF trust — scope to the SHARED istio-ingressgateway pod via annotation.
#
# This is only required for the Option A (non-dedicated) demo path.
# The recommended dedicated gateway (03-istio-proprietary/dedicated-gateway/) already has
# this annotation in its pod template — no shared gateway patch needed for that path.
#
# Do NOT use meshConfig.defaultConfig.gatewayTopology.numTrustedProxies — that setting
# propagates to every sidecar, causing all inbound Envoy listeners to consume and strip
# X-Forwarded-For before it reaches the application.
#
# Idempotent: checks for existing annotation before patching.
if kubectl get deployment istio-ingressgateway -n istio-system &>/dev/null; then
  EXISTING_ANNO=$(kubectl get deployment istio-ingressgateway -n istio-system \
    -o jsonpath='{.spec.template.metadata.annotations.proxy\.istio\.io/config}' 2>/dev/null || echo "")
  if [[ -z "$EXISTING_ANNO" ]]; then
    echo "  Applying XFF annotation to shared istio-ingressgateway (Option A shared path)..."
    kubectl patch deployment istio-ingressgateway -n istio-system \
      --type merge \
      -p '{"spec":{"template":{"metadata":{"annotations":{"proxy.istio.io/config":"{\"gatewayTopology\":{\"numTrustedProxies\":1}}"}}}}}'
    kubectl rollout restart deployment istio-ingressgateway -n istio-system
    kubectl rollout status deployment istio-ingressgateway -n istio-system --timeout=90s
  else
    echo "  XFF annotation already present on istio-ingressgateway — skipping patch"
  fi
else
  echo "  istio-ingressgateway not found in istio-system — skipping XFF patch (deploy it for Option A)"
fi

echo "==> [3/6] Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values 00-install/ingress-nginx-values.yaml \
  --wait

echo "==> [4/6] Installing Envoy Gateway"
# Gateway API CRDs (v1.5.0) were installed in step 1.
# EG's helm chart bundles both Gateway API CRDs (older) and EG-specific CRDs.
# --skip-crds would skip everything — instead, extract only EG-specific CRDs
# (gateway.envoyproxy.io group: EnvoyPatchPolicy, ClientTrafficPolicy, etc.)
# and apply them separately, leaving the Gateway API v1.5.0 CRDs untouched.
echo "  Installing Envoy Gateway-specific CRDs (gateway.envoyproxy.io)..."
# Use EG's release install.yaml (not helm template) — helm template renders the envoyproxies
# CRD with a malformed v1alpha1 entry (Served:false, Storage:false) that kubectl rejects.
# The release artifact has correctly-formed CRDs.
curl -sL "https://github.com/envoyproxy/gateway/releases/download/v${EG_VERSION}/install.yaml" \
  | python3 -c "
import sys, re
content = sys.stdin.read()
# Split on '---' only when it appears as a standalone line (document separator).
# A naive .split('---') breaks CRDs that contain '---' inside description strings.
docs = re.split(r'^---\s*$', content, flags=re.MULTILINE)
for doc in docs:
    if 'kind: CustomResourceDefinition' in doc and 'gateway.envoyproxy.io' in doc:
        print('---')
        print(doc.strip())
" | kubectl apply --server-side --force-conflicts -f -

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v${EG_VERSION} \
  -n envoy-gateway-system \
  --create-namespace \
  --set "config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true" \
  --skip-crds
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "==> [5/6] Creating TLS certificate secrets (idempotent)"
# generate-tls-secret.sh uses kubectl create --dry-run | apply — safe to run multiple times.
# Do NOT apply tls-secrets.yaml directly — it contains placeholder values that would
# overwrite real certs if generate-tls-secret.sh was run first.
bash 00-install/generate-tls-secret.sh

echo "==> [6/6] Deploying sample application"
kubectl apply -f 01-sample-app/

echo ""
echo "✅ Lab setup complete. Run pre-flight checks:"
echo ""
echo "  kubectl get pods -n istio-system"
echo "  kubectl get pods -n ingress-nginx"
echo "  kubectl get pods -n envoy-gateway-system"
echo "  kubectl get svc -A | grep LoadBalancer"
