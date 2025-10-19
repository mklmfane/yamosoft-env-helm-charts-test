#!/bin/bash
#
# Setup for Control Plane (Master) servers

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

NODENAME=$(hostname -s)
config_path="/vagrant/configs"

# --- Reset old state (idempotent) ---
sudo kubeadm reset -f || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d || true
sudo mkdir -p /etc/cni/net.d

# --- Preload Kubernetes images ---
sudo kubeadm config images pull
echo "✅ Preflight Check Passed: Downloaded All Required Images"

# --- Initialize the Kubernetes cluster ---
if [ ! -f /etc/kubernetes/admin.conf ]; then
  sudo kubeadm init \
    --apiserver-advertise-address=$CONTROL_IP \
    --apiserver-cert-extra-sans=$CONTROL_IP \
    --pod-network-cidr=$POD_CIDR \
    --service-cidr=$SERVICE_CIDR \
    --node-name "$NODENAME" \
    --cri-socket=unix:///var/run/crio/crio.sock \
    --ignore-preflight-errors Swap
else
  echo "ℹ️ Kubernetes is already initialized. Skipping kubeadm init."
fi

# --- Configure kubectl for root ---
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

# --- Save configs to Vagrant shared folder ---
mkdir -p $config_path
cp -f /etc/kubernetes/admin.conf $config_path/config
touch $config_path/join.sh
chmod +x $config_path/join.sh

# Generate join command and force cri-o socket
kubeadm token create --print-join-command > $config_path/join.sh
sed -i 's|kubeadm join|kubeadm join --cri-socket=unix:///var/run/crio/crio.sock|' $config_path/join.sh

# --- Install Calico CNI ---
echo "🌐 Applying Calico CNI manifest..."
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico.yaml -o calico.yaml
kubectl apply -f calico.yaml

# --- Wait for Calico CNI config to appear ---
echo "⏳ Waiting for Calico to create /etc/cni/net.d/10-calico.conflist..."
for i in {1..30}; do
  if [ -s /etc/cni/net.d/10-calico.conflist ]; then
    echo "✅ Calico CNI config detected!"
    break
  fi
  echo "[$i/30] Calico CNI not ready yet... sleeping 5s"
  sleep 5
done

# --- Switch Calico to VXLAN mode (fixes BIRD/BGP issues in Vagrant) ---
echo "🔧 Patching Calico IPPool to use VXLAN instead of IPIP..."
kubectl patch ippool default-ipv4-ippool -n kube-system \
  --type merge -p '{"spec": {"ipipMode": "Never", "vxlanMode": "Always"}}' || true

# --- Restart Calico pods to pick up VXLAN config ---
kubectl -n kube-system delete pod -l k8s-app=calico-node || true

# --- Restart kubelet ---
sudo systemctl restart kubelet

# --- Configure kubectl for vagrant user ---
sudo -i -u vagrant bash << EOF
mkdir -p /home/vagrant/.kube
cp -f $config_path/config /home/vagrant/.kube/config
chown 1000:1000 /home/vagrant/.kube/config
EOF

# --- Install Metrics Server ---
kubectl apply -f https://raw.githubusercontent.com/techiescamp/kubeadm-scripts/main/manifests/metrics-server.yaml
kubectl rollout restart deployment -n kube-system metrics-server || true

echo "🎉 Master node setup complete!"
