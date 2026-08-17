#!/bin/bash
#
# Setup for Control Plane (Master) server

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

NODENAME="$(hostname -s)"

echo "🏁 [MASTER] Starting control plane setup on ${NODENAME} (CONTROL_IP=${CONTROL_IP})"

# --- Reset old state ---
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo systemctl stop crio || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d || true
sudo mkdir -p /etc/cni/net.d
sudo systemctl restart crio

# --- Initialize the Kubernetes cluster (no static token, let kubeadm manage) ---
echo "⚙️ [MASTER] Running kubeadm init ..."
sudo kubeadm init \
  --apiserver-advertise-address="${CONTROL_IP}" \
  --apiserver-cert-extra-sans="${CONTROL_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SERVICE_CIDR}" \
  --node-name "${NODENAME}" \
  --cri-socket=unix:///var/run/crio/crio.sock \
  --ignore-preflight-errors=Swap

# --- Configure kubectl for root ---
echo "⚙️ [MASTER] Configuring kubectl for root ..."
mkdir -p "${HOME}/.kube"
sudo cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "${HOME}/.kube/config"

# --- Configure kubectl for vagrant user ---
echo "⚙️ [MASTER] Configuring kubectl for vagrant ..."
sudo mkdir -p /home/vagrant/.kube
sudo cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
sudo chown vagrant:vagrant /home/vagrant/.kube/config

# --- Install Calico CNI ---
echo "🌐 [MASTER] Applying Calico CNI v${CALICO_VERSION} ..."
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml"

# --- Wait for Calico DaemonSet to be ready (more robust than poking /etc/cni) ---
echo "⏳ [MASTER] Waiting for calico-node DaemonSet to be Ready ..."
for i in {1..60}; do
  READY=$(kubectl -n kube-system get ds calico-node -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  DESIRED=$(kubectl -n kube-system get ds calico-node -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  echo "[${i}/60] calico-node ready ${READY}/${DESIRED}"

  if [ "${DESIRED}" != "0" ] && [ "${READY}" = "${DESIRED}" ]; then
    echo "✅ [MASTER] Calico DaemonSet is ready (${READY}/${DESIRED})"
    break
  fi
  sleep 5
done

# --- Install Metrics Server (optional) ---
echo "📈 [MASTER] Deploying Metrics Server ..."
kubectl apply -f https://raw.githubusercontent.com/techiescamp/kubeadm-scripts/main/manifests/metrics-server.yaml
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s || true

# --- Generate join command and kubeconfig for workers via /vagrant (shared folder) ---
echo "🔐 [MASTER] Generating join command and kubeconfig for workers ..."
JOIN_CMD="$(kubeadm token create --print-join-command)"

mkdir -p /vagrant/configs

cat <<EOF >/vagrant/configs/join.sh
#!/bin/bash
${JOIN_CMD}
EOF

chmod +x /vagrant/configs/join.sh
cp -f /etc/kubernetes/admin.conf /vagrant/configs/config
chown -R vagrant:vagrant /vagrant/configs

echo "✅ [MASTER] join.sh and kubeconfig written to /vagrant/configs"

echo "🎉 [MASTER] Control plane setup complete!"
