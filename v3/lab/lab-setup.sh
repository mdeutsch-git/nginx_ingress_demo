#!/usr/bin/env bash
# lab-setup.sh — installs all prerequisites for the ingress migration lab
# Run once before starting the demo
# Usage: bash lab-setup.sh
#
# Stateless design notes:
#   - TLS secrets: idempotent (kubectl create --dry-run | apply)
#   - Istio/EG/nginx: all via helm upgrade --install (idempotent)
#   - XFF patch on istio-ingressgateway: conditional, skipped if annotation already set
#   - Sidecar pod restarts: only the lab 'nginx-demo' namespace is restarted automatically.
#     After an Istio upgrade, restart all other sidecar-injected namespaces manually:
#       kubectl rollout restart deployment -n <your-namespace>

set -euo pipefail

# Ensure relative paths work regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ISTIO_VERSION="1.29.0"
EG_VERSION="1.7.0"
GATEWAY_API_VERSION="v1.5.0"

echo "==> [1/6] Installing Gateway API CRDs (experimental channel)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "==> [2/6] Installing/upgrading Istio (demo profile, ${ISTIO_VERSION})"
if ! command -v istioctl &>/dev/null; then
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
  export PATH="${SCRIPT_DIR}/istio-${ISTIO_VERSION}/bin:$PATH"
fi

# Create the lab namespace before installing Istio so the injection label is present
# when pods are first created. Idempotent via --dry-run=client.
kubectl create namespace nginx-demo --dry-run=client -o yaml | kubectl apply -f -

# istioctl install handles both fresh installs and in-place upgrades.
# After an upgrade, existing sidecar-injected pods keep their old proxy image until restarted.
# The lab namespace (nginx-demo) is restarted below. Restart other namespaces manually.
istioctl install --set profile=demo -y
kubectl label namespace nginx-demo istio-injection=enabled --overwrite

echo "  Restarting lab pods in 'nginx-demo' to pick up new sidecar image..."
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

echo "==> [3/6] Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values 00-install/ingress-nginx-values.yaml \
  --wait

echo "==> [4/6] Installing Envoy Gateway"
helm repo add envoy-gateway https://charts.gateway.envoyproxy.io --force-update
helm upgrade --install envoy-gateway envoy-gateway/gateway-helm \
  --namespace envoy-gateway-system \
  --create-namespace \
  --version v${EG_VERSION} \
  --wait

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
