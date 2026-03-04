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
istioctl install --set profile=demo --set meshConfig.defaultConfig.gatewayTopology.numTrustedProxies=1 -y
kubectl label namespace default istio-injection=enabled --overwrite

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
