#!/bin/bash
#
# Setup for Worker Node servers

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

config_path="/vagrant/configs"

# --- Reset any previous Kubernetes state (idempotency) ---
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo systemctl stop crio || true
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d
sudo systemctl restart crio

# --- Join cluster ---
/bin/bash $config_path/join.sh --cri-socket=unix:///var/run/crio/crio.sock -v || true

# --- Wait until node object exists in the cluster ---
NODENAME=$(hostname -s)
echo "⏳ Waiting for node $NODENAME to register with controlplane..."
for i in {1..30}; do
  if kubectl get node "$NODENAME" >/dev/null 2>&1; then
    echo "✅ Node $NODENAME is registered!"
    break
  fi
  echo "[$i/30] Node $NODENAME not found yet... sleeping 5s"
  sleep 5
done

# --- Label the node as worker ---
kubectl label node "$NODENAME" node-role.kubernetes.io/worker=worker --overwrite || true
echo "🏷️ Node $NODENAME labeled as worker."

# --- Configure kubectl for vagrant user ---
sudo -i -u vagrant bash << EOF
mkdir -p /home/vagrant/.kube
cp -f $config_path/config /home/vagrant/.kube/config
chown 1000:1000 /home/vagrant/.kube/config
EOF

echo "🎉 Worker node $NODENAME setup complete!"


# Add Docker's official GPG key:
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

sudo apt-get install -y docker-compose-plugin