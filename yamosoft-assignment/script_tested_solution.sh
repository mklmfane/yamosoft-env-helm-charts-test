#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Configuration evariables
# -------------------------------
METALLB_NS="metallb-system"
INGRESS_NS="ingress-nginx"
POOL_NAME="vagrant-pool"
LB_RANGE="192.168.56.240-192.168.56.250"
RELEASE_METALLB="metallb"
RELEASE_INGRESS="ingress-nginx"
INGRESS_HOST="echo.localtest.me"  # used to test echo app Ingress
TIMEOUT="5m"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not found in PATH"; exit 1; }
}

retry() {
  local attempts=$1; shift
  local delay=$1; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if [ $n -ge $attempts ]; then
      echo "ERROR: command failed after $attempts attempts: $*"
      return 1
    fi
    sleep "$delay"
  done
}

# -------------------------------
# Pre-flight
# -------------------------------
need kubectl
need helm
kubectl version >/dev/null
helm version >/dev/null

echo "Using context: $(kubectl config current-context)"

# -------------------------------
# Repos
# -------------------------------
echo "==> Adding/updating Helm repos"
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update

# -------------------------------
# Install MetalLB
# -------------------------------
echo "==> Installing MetalLB"
kubectl get ns "$METALLB_NS" >/dev/null 2>&1 || kubectl create ns "$METALLB_NS"

helm upgrade --install "$RELEASE_METALLB" metallb/metallb \
  -n "$METALLB_NS" \
  --wait --timeout "$TIMEOUT"

echo "==> Waiting for MetalLB CRDs to be established"
retry 30 2 \
  kubectl get crd ipaddresspools.metallb.io l2advertisements.metallb.io >/dev/null 2>&1

# -------------------------------
# Configure MetalLB Address Pool
# -------------------------------
echo "==> Applying MetalLB IPAddressPool and L2Advertisement ($LB_RANGE)"
cat <<YAML | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${POOL_NAME}
  namespace: ${METALLB_NS}
spec:
  addresses:
    - ${LB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vagrant-l2
  namespace: ${METALLB_NS}
spec:
  ipAddressPools:
    - ${POOL_NAME}
YAML

kubectl -n "$METALLB_NS" get ipaddresspools,l2advertisements

# -------------------------------
# Install ingress-nginx (LoadBalancer + MetalLB annotations)
# -------------------------------
echo "==> Installing ingress-nginx (LoadBalancer)"
kubectl get ns "$INGRESS_NS" >/dev/null 2>&1 || kubectl create ns "$INGRESS_NS"

# Inline values.yaml for the chart
TMP_VALUES="$(mktemp)"
cat > "$TMP_VALUES" <<'YAML'
controller:
  ingressClassResource:
    name: nginx
    default: true
  service:
    type: LoadBalancer
    annotations:
      metallb.universe.tf/address-pool: vagrant-pool
    externalTrafficPolicy: Local
  config:
    proxy-body-size: "64m"
    enable-brotli: "true"
YAML

# Replace pool name dynamically
sed -i "s/vagrant-pool/${POOL_NAME}/g" "$TMP_VALUES"

helm upgrade --install "$RELEASE_INGRESS" ingress-nginx/ingress-nginx \
  -n "$INGRESS_NS" -f "$TMP_VALUES" \
  --wait --timeout "$TIMEOUT"

echo "==> Waiting for ingress-nginx Service external IP"
SVC_NAME="${RELEASE_INGRESS}-controller"
EXTERNAL_IP=""
for i in {1..60}; do
  EXTERNAL_IP="$(kubectl -n "$INGRESS_NS" get svc "$SVC_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "$EXTERNAL_IP" ]]; then break; fi
  sleep 3
done

if [[ -z "$EXTERNAL_IP" ]]; then
  echo "ERROR: No external IP assigned to Service/$SVC_NAME. Current service:"
  kubectl -n "$INGRESS_NS" get svc "$SVC_NAME" -o wide || true
  exit 1
fi

echo "==> Ingress controller external IP: $EXTERNAL_IP"

# -------------------------------
# Deploy test echo app + Ingress
# -------------------------------
echo "==> Deploying echo app + Service + Ingress ($INGRESS_HOST)"
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: echo }
  template:
    metadata:
      labels: { app: echo }
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args: ["-text=hello from ingress"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: default
spec:
  selector: { app: echo }
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  namespace: default
  annotations:
    # You can add ingress.kubernetes.io annotations here if needed
spec:
  ingressClassName: nginx
  rules:
    - host: ${INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: echo
                port:
                  number: 80
YAML

echo "==> Waiting for echo pod to be Ready"
kubectl -n default rollout status deploy/echo --timeout="$TIMEOUT"

# -------------------------------
# Show status and test
# -------------------------------
echo "==> Current status"
kubectl -n "$METALLB_NS" get ipaddresspools,l2advertisements
kubectl -n "$INGRESS_NS" get svc "$SVC_NAME" -o wide
kubectl get ingress echo -n default -o wide

echo
echo "==> Test with curl using Host header (no /etc/hosts change required)"
echo "curl -H \"Host: ${INGRESS_HOST}\" http://${EXTERNAL_IP}/"
echo

# Try the curl from this script (will not modify /etc/hosts)
set +e
CURL_OUT="$(curl -sS -H "Host: ${INGRESS_HOST}" "http://${EXTERNAL_IP}/" 2>&1)"
CURL_RC=$?
set -e
if [ $CURL_RC -ne 0 ]; then
  echo "Curl didn't return 200 OK yet. It may take a few more seconds for endpoints to propagate."
  echo "Output:"
  echo "$CURL_OUT"
  exit 0
fi

echo "Response:"
echo "$CURL_OUT"
