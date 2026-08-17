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
cat <<EOF >/etc/systemd/resolved.conf.d/dns_servers.conf
[Resolve]
DNS=${DNS_SERVERS}
EOF
systemctl restart systemd-resolved

echo "=== [3/7] Disable swap ==="
swapoff -a || true
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
sed -i '/\sswap\s/s/^/#/' /etc/fstab || true

echo "=== [4/7] Kernel modules & sysctl ==="
cat <<EOF >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay || true
modprobe br_netfilter || true

cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "=== [5/7] Install CRI-O runtime ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/Release.key \
  -o /etc/apt/keyrings/crio-apt-keyring.asc

cat <<EOF >/etc/apt/sources.list.d/cri-o.list
deb [signed-by=/etc/apt/keyrings/crio-apt-keyring.asc] https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/ /
EOF

apt-get update -y
apt-get install -y cri-o
systemctl enable crio --now

# Pause image override for Kubernetes 1.34
mkdir -p /etc/crio/crio.conf.d
cat <<EOF >/etc/crio/crio.conf.d/99-pause.conf
[crio.image]
pause_image = "registry.k8s.io/pause:3.10.1"
EOF

systemctl restart crio

echo "=== [6/7] Install Kubernetes components ==="
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION_SHORT}/deb/Release.key" \
  -o /etc/apt/keyrings/kubernetes-apt-keyring.asc

cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION_SHORT}/deb/ /
EOF

apt-get update -y
# Let apt pull the latest patch for the given major.minor (no version pinning)
apt-get install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl cri-o

echo "=== [7/7] Configure kubelet node IP ==="

local_ip=""

# Prefer eth1 (private network) if present, otherwise first non-loopback IPv4
if ip --json a s >/dev/null 2>&1; then
  local_ip="$(ip --json a s \
    | jq -r '.[] | select(.ifname=="eth1") | .addr_info[] | select(.family=="inet") | .local' \
    | head -n1 || true)"
fi

if [ -z "${local_ip}" ]; then
  local_ip="$(ip -4 addr show scope global \
    | awk '/inet/ && $2 !~ /^127/ {print $2; exit}' \
    | cut -d/ -f1)"
fi

cat <<EOF >/etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=${local_ip}
EOF

# Append ENVIRONMENT only if it's set (avoid unbound-variable crash)
if [ -n "${ENVIRONMENT:-}" ]; then
  echo "${ENVIRONMENT}" >> /etc/default/kubelet
fi

echo "=== ✅ Common setup complete! ==="
