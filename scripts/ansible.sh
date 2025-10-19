#!/bin/bash

set -euxo pipefail

# Set non-interactive mode for APT
export DEBIAN_FRONTEND=noninteractive

# Update system and install prerequisites
apt-get update -y && apt-get upgrade -y
apt-get install -y ansible
apt-get dist-upgrade -y
