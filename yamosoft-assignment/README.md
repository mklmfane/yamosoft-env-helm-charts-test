# Deploying an Application with Helm (Local Kubernetes via Vagrant + MetalLB)

This README walks through creating a **simple templated Helm chart** that deploys an **NGINX** web server with an **Ingress**, configured to work on a **local Kubernetes cluster** provisioned via **Vagrant**. It also documents how MetalLB is installed and used to provide a LoadBalancer IP, plus a smoke test app to validate ingress.

---

## 1 Prerequisites

* Local Kubernetes cluster (brought up via `vagrant up` from this repo)
* `kubectl` pointing at that cluster
* `helm` v3+
* Network `192.168.56.0/24` available (typical Vagrant host-only network)
* MetalLB to assign external IPs to LoadBalancer services

---

## 2 Repo Layout (suggested)

```
.
├── charts/
│   └── nginx-hello/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── ingress.yaml
├── metallb-pool.yaml
└── echo-app.yaml            # optional smoke test
```

---

## 3 Create the Helm chart: `charts/nginx-hello`

### 3.1 `Chart.yaml`

```yaml
apiVersion: v2
name: nginx-hello
description: A simple NGINX server with Ingress
type: application
version: 0.1.0
appVersion: "1.25.3"
```

### 3.2 `values.yaml` (chart values)

```yaml
replicaCount: 1

image:
  repository: nginx
  tag: "1.25.3"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: nginx
  host: nginx.localtest.me
  annotations: {}
  path: /
  pathType: Prefix

resources: {}
nodeSelector: {}
tolerations: []
affinity: {}
```

### 3.3 `templates/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "nginx-hello.fullname" . }}
  labels:
    app.kubernetes.io/name: {{ include "nginx-hello.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "nginx-hello.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "nginx-hello.name" . }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: nginx
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
```

### 3.4 `templates/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "nginx-hello.fullname" . }}
  labels:
    app.kubernetes.io/name: {{ include "nginx-hello.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
  selector:
    app.kubernetes.io/name: {{ include "nginx-hello.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
```

### 3.5 `templates/ingress.yaml`

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "nginx-hello.fullname" . }}
  annotations:
    {{- with .Values.ingress.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className | quote }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: {{ .Values.ingress.pathType }}
            backend:
              service:
                name: {{ include "nginx-hello.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

> Tip: Add standard Helm helper templates in `_helpers.tpl` if you prefer. The chart above keeps it minimal.

---

## 4 Installing and Configuring MetalLB

### 4.1 Add repos and pull charts (as you did)

```bash
helm repo update
helm pull ingress-nginx/ingress-nginx --untar
```

### 4.2 Create the MetalLB address pool (will fail until CRDs exist)

`metallb-pool.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vagrant-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.56.240-192.168.56.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vagrant-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - vagrant-pool
```

Applying at this point returns:

* `no matches for kind "IPAddressPool"` → CRDs aren’t installed yet.

### 4.3 Install MetalLB via Helm and wait for webhook

```bash
kubectl create ns metallb-system
helm repo add metallb https://metallb.github.io/metallb
helm repo update

# wait for controller + webhook to be ready
helm upgrade --install metallb metallb/metallb \
  -n metallb-system --create-namespace --wait --timeout 3m
```

### 4.4 Apply the pool again

```bash
kubectl apply -f metallb-pool.yaml
```

Expect:

* `ipaddresspool.metallb.io/vagrant-pool created`
* `l2advertisement.metallb.io/vagrant-l2 created`

### 4.5 Verify MetalLB readiness

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get svc metallb-webhook-service
kubectl -n metallb-system get endpoints metallb-webhook-service
kubectl -n metallb-system logs deploy/metallb-controller
```

---

## 5 Install Ingress-NGINX (MetalLB-friendly)

Use the chart you untarred (`~/ingress-nginx`) and set the controller service to `LoadBalancer` with annotations to use your pool.

Create or edit `~/ingress-nginx/values.yaml`:

```yaml
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
```

Install/upgrade:

```bash
cd ~/ingress-nginx
helm upgrade --install my-ingress . \
  -n ingress-nginx --create-namespace -f values.yaml --wait
```

Watch the service until it receives an external IP from MetalLB:

```bash
kubectl -n ingress-nginx get svc my-ingress-ingress-nginx-controller --watch
```

Expected: `TYPE=LoadBalancer`, `EXTERNAL-IP 192.168.56.240` (first address in your pool).

---

## 6 Deploy the NGINX Hello chart you created

Use the templated chart from `charts/nginx-hello`:

```bash
helm upgrade --install nginx-hello ./charts/nginx-hello \
  -n default --create-namespace -f charts/nginx-hello/values.yaml --wait
```

---

## 7 Show the command that **dumps the generated templates**

Use `helm template` to render manifests without applying them:

```bash
helm template nginx-hello ./charts/nginx-hello \
  -n default -f charts/nginx-hello/values.yaml
```

> This prints the fully rendered YAML to stdout.

---

## 8 Quick Smoke Test (optional but recommended)

Deploy a tiny echo app to confirm the ingress pathing works:

`echo-app.yaml`:

```yaml
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
spec:
  ingressClassName: nginx
  rules:
    - host: echo.localtest.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: echo
                port:
                  number: 80
```

Apply and test:

```bash
kubectl apply -f echo-app.yaml

# If EXTERNAL-IP is 192.168.56.240:
# Option A: set /etc/hosts
#   192.168.56.240  echo.localtest.me
# Then:
curl -H "Host: echo.localtest.me" http://192.168.56.240/
# Expected: "hello from ingress"
```

---

## 9 Verification Checklist

```bash
# MetalLB objects
kubectl -n metallb-system get ipaddresspools,l2advertisements

# Ingress-NGINX LoadBalancer has external IP from your pool
kubectl -n ingress-nginx get svc my-ingress-ingress-nginx-controller -o wide

# IngressClass is default (if configured)
kubectl get ingressclass nginx -o yaml
```

---

## 10 Troubleshooting Notes

* **CRDs not found** when applying `IPAddressPool` / `L2Advertisement`
  Install MetalLB first (its CRDs) before applying those resources.

* **Webhook “connection refused”** right after installing MetalLB
  The validating webhook may not be ready. Use `--wait` on `helm upgrade --install metallb ...` and retry.

* **No external IP assigned** to the ingress controller service
  Ensure Service type is `LoadBalancer` and annotations reference the correct address pool:

  ```yaml
  metallb.universe.tf/address-pool: vagrant-pool
  ```

  Confirm `IPAddressPool`/`L2Advertisement` exist and are in `metallb-system`.

---

## 11 Summary

* Update Helm repos and work with the local charts
* Install **MetalLB** and **wait** for its webhook
* Apply the **IPAddressPool** and **L2Advertisement**
* Install **ingress-nginx** with a **LoadBalancer** service and MetalLB annotations
* Deploy your **templated NGINX chart** and **verify** the external IP
* **Smoke test** with a tiny echo app and curl against the LB IP with the Host header

 * The entire scripted tested for all the steps above is teh following
 ```bash
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
 ```

