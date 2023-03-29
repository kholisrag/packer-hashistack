#!/bin/bash
set -e

SCRIPT=`basename "$0"`
export DEBIAN_FRONTEND="noninteractive"

CPU_ARCH="$(uname -m)"
BINARY_ARCH=""
case "${CPU_ARCH}" in
  x86_64)
    export BINARY_ARCH="amd64"
    ;;
  x86)
    export BINARY_ARCH="386"
    ;;
  arm64|aarch64)
    export BINARY_ARCH="arm64"
    ;;
  arm*)
    export BINARY_ARCH="arm"
    ;;
  *)
    log_error "CPU architecture ${CPU_ARCH} is not a supported."
    exit 1
    ;;
esac

# Using Docker CE directly provided by Docker
echo "[INFO] [${SCRIPT}] Setup Docker"
cd /tmp/
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
apt-cache policy docker-ce
sudo apt-get install -y \
  docker-ce="${DOCKER_VERSION}" \
  docker-ce-cli="${DOCKER_VERSION}" \
  containerd.io="${CONTAINERD_VERSION}"

echo "[INFO] [${SCRIPT}] Configuring User and Group"
sudo addgroup --system hashistack --gid 9000
sudo useradd --system --user-group --shell /bin/false \
  --uid 9001 \
  --create-home --home-dir /opt/vault \
  --groups hashistack,docker,sudo vault
sudo useradd --system --user-group --shell /bin/false \
  --uid 9002 \
  --create-home --home-dir /opt/consul \
  --groups hashistack,docker,sudo consul
sudo useradd --system --user-group --shell /bin/false \
  --uid 9003 \
  --create-home --home-dir /opt/nomad \
  --groups hashistack,docker,sudo nomad

echo "[INFO] [${SCRIPT}] Setup Prerequisite Package"
sudo apt-get install -y \
  acl awscli curl unzip jq libcap2-bin

echo "[INFO] [${SCRIPT}] Setup docker-credential-ecr-login"
curl -LO "https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com/0.6.0/linux-${BINARY_ARCH}/docker-credential-ecr-login"
sudo install -o root -g root -m 0755 docker-credential-ecr-login /usr/local/bin/docker-credential-ecr-login

echo "[INFO] [${SCRIPT}] Setup iptables-persistent"
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get install -y iptables-persistent

echo "[INFO] [${SCRIPT}] Install Nomad"
/tmp/scripts/install-nomad.sh \
  --version "${NOMAD_VERSION}"
echo "[INFO] [${SCRIPT}] Install Consul"
/tmp/scripts/install-consul.sh \
  --version "${CONSUL_VERSION}"
echo "[INFO] [${SCRIPT}] Setup SystemD Resolver to use Consul DNS"
/tmp/scripts/setup-systemd-resolved.sh
echo "[INFO] [${SCRIPT}] Install Vault"
/tmp/scripts/install-vault.sh \
  --version "${VAULT_VERSION}"
echo "[INFO] [${SCRIPT}] Install CNI Plugins"
/tmp/scripts/install-cni.sh \
  --version "${CNI_PLUGINS_VERSION}"
echo "[INFO] [${SCRIPT}] Install SSM Agent"
/tmp/scripts/install-ssm.sh

echo "[INFO] [${SCRIPT}] Setup Sudoers"
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl stop vault' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl stop consul' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl stop nomad' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')

echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl start vault' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl start consul' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl start nomad' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')

echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl restart vault' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl restart consul' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')
echo 'vault ALL=(ALL) NOPASSWD:/usr/bin/systemctl restart nomad' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')

echo 'vault ALL=(ALL) NOPASSWD:/bin/kill --signal SIGHUP *' | (sudo su -c 'EDITOR="tee -a" visudo -f /etc/sudoers.d/vault')

echo "[INFO] [${SCRIPT}] Clean /tmp directory"
sudo rm -rf /tmp/*
