mkdir -p "$HOME/k8s/manifests/metallb"
mkdir -p "$HOME/k8s/manifests/petclinic"

tee "$HOME/k8s/manifests/metallb/values.yaml" >/dev/null <<'EOF'
controller:
  logLevel: info

speaker:
  logLevel: info

crds:
  enabled: true
EOF

tee "$HOME/k8s/manifests/metallb/l2-config.yaml" >/dev/null <<'EOF'
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
EOF


tee "$HOME/k8s/manifests/petclinic/petclinic-lb-service.yaml" >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: petclinic
  namespace: __NAMESPACE__
spec:
  type: LoadBalancer
  selector:
    app: petclinic
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
EOF


sed "s|__NAMESPACE__|petclinic|g" \
  "$HOME/k8s/manifests/petclinic/petclinic-lb-service.yaml" \
  > "$HOME/k8s/manifests/petclinic/petclinic-lb-service-rendered.yaml"


helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm upgrade --install metallb metallb/metallb \
  -n metallb-system \
  --create-namespace \
  -f "$HOME/k8s/manifests/metallb/values.yaml"
  --timeout 5m


kubectl apply -f "$HOME/k8s/manifests/metallb/l2-config.yaml"


kubectl apply -f "$HOME/k8s/manifests/petclinic/petclinic-lb-service-rendered.yaml"
kubectl apply -f "$HOME/k8s/manifests/metallb/l2-config.yaml"

kubectl get pods -n metallb-system -o wide
kubectl get svc -n metallb-system
kubectl get endpoints -n metallb-system
kubectl get ipaddresspools,l2advertisements -n metallb-system
kubectl get validatingwebhookconfiguration | grep metallb || true

kubectl get svc -n petclinic -o wide