#!/bin/bash
#
# Setup for dedicated Jenkins server

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"

echo "=== [1/6] Update system and install base packages ==="
apt-get update
apt-get -o Dpkg::Options::="--force-confold" upgrade -y
apt-get install -y wget ca-certificates curl gnupg git unzip fontconfig openjdk-21-jre openjdk-21-jdk

echo "=== [2/6] Add Jenkins repository ==="
install -d -m 0755 /etc/apt/keyrings

sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" https://pkg.jenkins.io/debian-stable binary/ | \
  sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

echo "=== [3/6] Install Jenkins ==="
apt-get update
apt-get install -y jenkins


echo "=== [4/6] Configure Jenkins port ==="
mkdir -p /etc/default
if [ -f /etc/default/jenkins ]; then
  sed -i "s/^HTTP_PORT=.*/HTTP_PORT=${JENKINS_HTTP_PORT}/" /etc/default/jenkins || true
  grep -q "^HTTP_PORT=" /etc/default/jenkins || echo "HTTP_PORT=${JENKINS_HTTP_PORT}" >> /etc/default/jenkins
fi

mkdir -p /usr/lib/systemd/system/jenkins.service.d
cat <<EOF > /usr/lib/systemd/system/jenkins.service.d/override.conf
[Service]
Environment="JENKINS_PORT=${JENKINS_HTTP_PORT}"
EOF

echo "=== [5/6] Enable and start Jenkins ==="
systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins

echo "=== [6/6] Optional tooling for CI agents / Docker builds ==="
# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl start docker || true
systemctl enable docker || true
sudo systemctl restart jenkins

usermod -aG docker vagrant || true
usermod -aG docker jenkins || true

echo "=== Jenkins status ==="
systemctl status jenkins --no-pager || true

echo "=== Initial admin password ==="
if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
  cat /var/lib/jenkins/secrets/initialAdminPassword
else
  echo "Initial admin password not available yet. Jenkins may still be starting."
fi

echo "✅ Jenkins setup complete!"
echo "Jenkins URL: http://$(hostname -I | awk '{print $2}'):${JENKINS_HTTP_PORT} or http://localhost:${JENKINS_HTTP_PORT}"