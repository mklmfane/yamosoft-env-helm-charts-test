#!/bin/bash
#
# Setup for Worker Node servers

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

NODENAME="$(hostname -s)"

echo "🚀 [${NODENAME}] Preparing worker to join cluster ..."

# --- Reset any previous Kubernetes state (idempotent) ---
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo systemctl stop crio || true
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d || true
sudo mkdir -p /etc/cni/net.d
sudo systemctl restart crio

# --- Wait for join.sh from master via /vagrant ---
echo "⏳ [${NODENAME}] Waiting for /vagrant/configs/join.sh from master ..."
for i in {1..60}; do
  if [ -x /vagrant/configs/join.sh ]; then
    echo "✅ [${NODENAME}] Found /vagrant/configs/join.sh"
    break
  fi
  echo "[${i}/60] [${NODENAME}] join.sh not present yet, sleeping 5s..."
  sleep 5
done

if [ ! -x /vagrant/configs/join.sh ]; then
  echo "❌ [${NODENAME}] /vagrant/configs/join.sh still missing after 5 minutes. Aborting."
  exit 1
fi

# --- Join the cluster, with retries ---
success=0
for i in {1..5}; do
  echo "⚙️ [${NODENAME}] Attempt ${i}/5: kubeadm join ..."
  if sudo /vagrant/configs/join.sh --cri-socket=unix:///var/run/crio/crio.sock; then
    echo "✅ [${NODENAME}] kubeadm join succeeded on attempt ${i}"
    success=1
    break
  fi
  echo "❌ [${NODENAME}] kubeadm join failed on attempt ${i}, retrying in 15s..."
  sleep 15
done

if [ "${success}" -ne 1 ]; then
  echo "❌ [${NODENAME}] kubeadm join failed after 5 attempts, giving up."
  exit 1
fi

# --- Configure kubectl for vagrant user on worker (optional, but nice to have) ---
if [ -f /vagrant/configs/config ]; then
  echo "⚙️ [${NODENAME}] Installing kubeconfig for vagrant user ..."
  sudo mkdir -p /home/vagrant/.kube
  sudo cp -f /vagrant/configs/config /home/vagrant/.kube/config
  sudo chown vagrant:vagrant /home/vagrant/.kube/config
fi

echo "🎉 [${NODENAME}] Worker node successfully joined the cluster!"
