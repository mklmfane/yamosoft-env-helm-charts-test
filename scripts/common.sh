#!/bin/bash
#
# Common setup for all servers (Control Plane and Worker Nodes)

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== [1/7] Updating base system ==="
apt-get update -y
apt-get -o Dpkg::Options::="--force-confold" upgrade -y

# Install base tools
apt-get install -y qemu-guest-agent software-properties-common curl \
                   apt-transport-https ca-certificates jq ipvsadm gnupg

systemctl restart qemu-guest-agent || true

echo "=== [2/7] Configuring DNS ==="
mkdir -p /etc/systemd/resolved.conf.d/
cat <<EOF | tee /etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
EOF
systemctl restart systemd-resolved

echo "=== [3/7] Disable swap ==="
swapoff -a
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
sed -i '/ swap / s/^/#/' /etc/fstab || true

echo "=== [4/7] Kernel modules & sysctl ==="
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "=== [5/7] Install CRI-O runtime ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/Release.key \
  -o /etc/apt/keyrings/cri-o-apt-keyring.asc

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.asc] \
https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/ /" \
  | tee /etc/apt/sources.list.d/cri-o.list

apt-get update -y
apt-get install -y cri-o
systemctl enable crio --now

# ✅ Fix pause image with drop-in config (Ubuntu 24.04 style)
mkdir -p /etc/crio/crio.conf.d
cat <<EOF | tee /etc/crio/crio.conf.d/99-pause.conf
[crio.image]
pause_image = "registry.k8s.io/pause:3.10.1"
EOF

systemctl restart crio

echo "=== [6/7] Install Kubernetes components ==="
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION_SHORT/deb/Release.key \
  -o /etc/apt/keyrings/kubernetes-apt-keyring.asc

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] \
https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION_SHORT/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet="$KUBERNETES_VERSION" \
                   kubeadm="$KUBERNETES_VERSION" \
                   kubectl="$KUBERNETES_VERSION"

apt-mark hold kubelet kubeadm kubectl cri-o

echo "=== [7/7] Configure kubelet node IP ==="
local_ip="$(ip --json a s | jq -r '.[] | select(.ifname=="eth1") | .addr_info[] | select(.family=="inet") | .local')"
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
${ENVIRONMENT}
EOF

echo "=== ✅ Common setup complete! ==="

# Reboot if required
if [ -f /var/run/reboot-required ]; then
  echo "🔄 Reboot required, rebooting..."
  reboot
fi
