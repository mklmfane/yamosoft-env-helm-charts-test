#!/bin/bash

set -euxo pipefail

# Set non-interactive mode for APT
export DEBIAN_FRONTEND=noninteractive

# Update system and install prerequisites
apt-get update -y && apt-get upgrade -y
apt-get install -y openjdk-21-jdk wget gnupg apt-transport-https ca-certificates
apt-get dist-upgrade -y

# Add Jenkins repository key and repository
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key -o /etc/apt/keyrings/jenkins-apt-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/jenkins-apt-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

# Update package lists
apt-get update -y

# Install Jenkins
apt-get install -y jenkins

# Update Jenkins configuration to bind to 0.0.0.0
sed -i 's/^JENKINS_ARGS=.*/JENKINS_ARGS="--httpListenAddress=0.0.0.0 --httpPort=8080"/' /etc/default/jenkins

# Ensure Jenkins service is enabled and started
systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins

# Display Jenkins initial admin password
if [ -f /var/lib/jenkins/secrets/initialAdminPassword ]; then
    echo "Jenkins initial admin password:"
    cat /var/lib/jenkins/secrets/initialAdminPassword
else
    echo "Initial admin password file not found. Jenkins may not have started correctly."
fi
