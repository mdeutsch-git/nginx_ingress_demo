#!/usr/bin/env bash
# lab-setup.sh — installs all prerequisites for the ingress migration lab
# Run once before starting the demo
# Usage: bash lab-setup.sh

set -euo pipefail

ISTIO_VERSION="1.20.3"
EG_VERSION="1.1.0"
GATEWAY_API_VERSION="v1.1.0"

echo "==> [1/6] Installing Gateway API CRDs (experimental channel)"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml

echo "==> [2/6] Installing Istio (demo profile)"
if ! command -v istioctl &>/dev/null; then
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh -
  export PATH="$PWD/istio-${ISTIO_VERSION}/bin:$PATH"
fi
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled --overwrite

# Scope XFF trust to the ingress gateway pod only via annotation.
# Do NOT use meshConfig.defaultConfig.gatewayTopology.numTrustedProxies — that setting
# applies to every sidecar in the mesh, causing all inbound Envoy listeners to consume
# and strip X-Forwarded-For before it reaches the application.
# The annotation on the Deployment pod template targets only the gateway proxy.
kubectl patch deployment istio-ingressgateway -n istio-system \
  --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"proxy.istio.io/config":"{\"gatewayTopology\":{\"numTrustedProxies\":1}}"}}}}}' 
kubectl rollout restart deployment istio-ingressgateway -n istio-system
kubectl rollout status deployment istio-ingressgateway -n istio-system --timeout=90s

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

echo "==> [5/6] Creating TLS certificate secrets"
kubectl apply -f 00-install/tls-secrets.yaml

echo "==> [6/6] Deploying sample application (httpbin)"
kubectl apply -f 01-sample-app/

echo ""
echo "✅ Lab setup complete. Run pre-flight checks:"
echo ""
echo "  kubectl get pods -n istio-system"
echo "  kubectl get pods -n ingress-nginx"
echo "  kubectl get pods -n envoy-gateway-system"
echo "  kubectl get svc -A | grep LoadBalancer"
