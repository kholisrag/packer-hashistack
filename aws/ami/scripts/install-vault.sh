#!/bin/bash

set -e

export DEBIAN_FRONTEND="noninteractive"
readonly DEFAULT_INSTALL_PATH="/opt/vault"
readonly DEFAULT_VAULT_USER="vault"
readonly DEFAULT_VAULT_GROUP="hashistack"
readonly DEFAULT_SKIP_PACKAGE_UPDATE="false"

readonly VAULT_CONFIG_FILE="default.hcl"
readonly VAULT_PID_FILE="vault-pid"
readonly VAULT_TOKEN_FILE="vault-token"
readonly SYSTEMD_CONFIG_PATH="/etc/systemd/system/vault.service"

readonly DOWNLOAD_PACKAGE_PATH="/tmp/vault.zip"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SYSTEM_BIN_DIR="/usr/local/bin"

readonly SCRIPT_NAME="$(basename "$0")"

function print_usage {
  echo
  echo "Usage: install-vault [OPTIONS]"
  echo
  echo "This script can be used to install Vault and its dependencies. This script has been tested with Ubuntu 16.04, Ubuntu 18.04 and Amazon Linux 2."
  echo
  echo "Options:"
  echo
  echo -e "  --version\t\tThe version of Vault to install. Optional if download-url is provided."
  echo -e "  --download-url\t\tUrl to exact Vault package to be installed. Optional if version is provided."
  echo -e "  --path\t\tThe path where Vault should be installed. Optional. Default: $DEFAULT_INSTALL_PATH."
  echo -e "  --user\t\tThe user who will own the Vault install directories. Optional. Default: $DEFAULT_VAULT_USER."
  echo -e "  --skip-package-update\t\tSkip yum/apt updates. Optional. Only recommended if you already ran yum update or apt-get update yourself. Default: $DEFAULT_SKIP_PACKAGE_UPDATE."
  echo
  echo "Example:"
  echo
  echo "  install-vault --version 1.13.0"
}

function log {
  local -r level="$1"
  local -r message="$2"
  local -r timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  >&2 echo -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local -r message="$1"
  log "INFO" "$message"
}

function log_warn {
  local -r message="$1"
  log "WARN" "$message"
}

function log_error {
  local -r message="$1"
  log "ERROR" "$message"
}

function assert_not_empty {
  local -r arg_name="$1"
  local -r arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_either_or {
  local -r arg1_name="$1"
  local -r arg1_value="$2"
  local -r arg2_name="$3"
  local -r arg2_value="$4"

  if [[ -z "$arg1_value" && -z "$arg2_value" ]]; then
    log_error "Either the value for '$arg1_name' or '$arg2_name' must be passed, both cannot be empty"
    print_usage
    exit 1
  fi
}

# A retry function that attempts to run a command a number of times and returns the output
function retry {
  local -r cmd="$1"
  local -r description="$2"

  for i in $(seq 1 5); do
    log_info "$description"

    # The boolean operations with the exit status are there to temporarily circumvent the "set -e" at the
    # beginning of this script which exits the script immediatelly for error status while not losing the exit status code
    output=$(eval "$cmd") && exit_status=0 || exit_status=$?
    log_info "$output"
    if [[ $exit_status -eq 0 ]]; then
      echo "$output"
      return
    fi
    log_warn "$description failed. Will sleep for 10 seconds and try again."
    sleep 10
  done;

  log_error "$description failed after 5 attempts."
  exit $exit_status
}

function has_yum {
  [[ -n "$(command -v yum)" ]]
}

function has_apt_get {
  [[ -n "$(command -v apt-get)" ]]
}

function install_dependencies {
  local -r skip_package_update=$1
  log_info "Installing dependencies"
  if $(has_apt_get); then
    if [[ "$skip_package_update" != "true" ]]; then
      log_info "Running apt-get update"
      sudo apt-get update -y
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl unzip jq libcap2-bin
  elif $(has_yum); then
    if [[ "$skip_package_update" != "true" ]]; then
      log_info "Running yum update"
      sudo yum update -y
    fi
    sudo yum install -y awscli curl unzip jq
  else
    log_error "Could not find apt-get or yum. Cannot install dependencies on this OS."
    exit 1
  fi
}

function user_exists {
  local -r username="$1"
  id "$username" >/dev/null 2>&1
}

function create_vault_user {
  local -r username="$1"

  if $(user_exists "$username"); then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd --system "$username"
  fi
}

function create_vault_install_paths {
  local -r path="${1}"
  local -r username="${2}"
  local -r group="${3}"

  log_info "Creating install dirs for Vault at $path"
  sudo mkdir -pv "$path"
  sudo mkdir -pv "$path/bin"
  sudo mkdir -pv "$path/config"
  sudo mkdir -pv "$path/data"
  sudo mkdir -pv "$path/tls"
  sudo mkdir -pv "$path/log"
  sudo mkdir -pv "$path/audit"
  sudo chmod 755 "$path"
  sudo chmod 755 "$path/bin"
  sudo chmod 755 "$path/data"

  log_info "Changing ownership of $path to $username:$group"
  sudo chown -R "$username:$group" "$path"
}

function fetch_binary {
  local -r version="$1"
  local download_url="$2"

  local cpu_arch
  cpu_arch="$(uname -m)"
  local binary_arch=""
  case "$cpu_arch" in
    x86_64)
      binary_arch="amd64"
      ;;
    x86)
      binary_arch="386"
      ;;
    arm64|aarch64)
      binary_arch="arm64"
      ;;
    arm*)
      binary_arch="arm"
      ;;
    *)
      log_error "CPU architecture $cpu_arch is not a supported by Consul."
      exit 1
      ;;
    esac

  if [[ -z "$download_url" && -n "$version" ]];  then
    download_url="https://releases.hashicorp.com/vault/${version}/vault_${version}_linux_${binary_arch}.zip"
  fi

  retry \
    "curl -o '$DOWNLOAD_PACKAGE_PATH' '$download_url' --location --silent --fail --show-error" \
    "Downloading Vault to $DOWNLOAD_PACKAGE_PATH"
}

function install_binary {
  local -r install_path="$1"
  local -r username="$2"

  local -r bin_dir="$install_path/bin"
  local -r vault_dest_path="$bin_dir/vault"
  # local -r run_vault_dest_path="$bin_dir/run-vault"

  unzip -d /tmp "$DOWNLOAD_PACKAGE_PATH"

  log_info "Moving Vault binary to $vault_dest_path"
  sudo mv "/tmp/vault" "$vault_dest_path"
  sudo chown "$username:$username" "$vault_dest_path"
  sudo chmod a+x "$vault_dest_path"

  local -r symlink_path="$SYSTEM_BIN_DIR/vault"
  if [[ -f "$symlink_path" ]]; then
    log_info "Symlink $symlink_path already exists. Will not add again."
  else
    log_info "Adding symlink to $vault_dest_path in $symlink_path"
    sudo ln -s "$vault_dest_path" "$symlink_path"
  fi
}

# For more info, see: https://www.vaultproject.io/docs/configuration/#disable_mlock
function configure_mlock {
  echo "Giving Vault permission to use the mlock syscall"
  # Requires installing libcap2-bin on Ubuntu 18
  sudo setcap cap_ipc_lock=+ep $(readlink -f $(which vault))
}

function generate_systemd_config {
  local -r systemd_config_path="${1}"
  local -r vault_config_dir="${2}"
  local -r vault_bin_dir="${3}"
  local -r vault_log_level="${4}"
  local -r vault_user="${5}"
  local -r vault_group="${6}"
  local -r config_path="$vault_config_dir/$VAULT_CONFIG_FILE"

  local vault_description="HashiCorp Vault - A tool for managing secrets"
  vault_command="agent"
  vault_config_file="$config_path"

  log_info "Creating systemd config file to run Vault in $systemd_config_path"

  local -r unit_config=$(cat <<EOF
[Unit]
Description="HashiCorp Vault Agent"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
StartLimitIntervalSec=5
StartLimitBurst=100


EOF
)

  local -r service_config=$(cat <<EOF
[Service]
User=$vault_user
Group=$vault_group
ProtectSystem=full
ReadWritePaths=/etc/systemd/system /var /opt
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=no
NoNewPrivileges=no
SecureBits=keep-caps
AmbientCapabilities=CAP_SETGID CAP_SETUID CAP_AUDIT_WRITE CAP_SYSLOG CAP_IPC_LOCK CAP_KILL CAP_SETFCAP
CapabilityBoundingSet=CAP_SETGID CAP_SETUID CAP_AUDIT_WRITE CAP_SYSLOG CAP_IPC_LOCK CAP_KILL CAP_SETFCAP
ExecStart=$vault_bin_dir/vault $vault_command -config $vault_config_file -log-level=$vault_log_level
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=always
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity


EOF
)

  local -r install_config=$(cat <<EOF
[Install]
WantedBy=multi-user.target


EOF
)

  systemd_service_temp=$(mktemp)
  echo -e "$unit_config" > "$systemd_service_temp"
  echo -e "$service_config" >> "$systemd_service_temp"
  echo -e "$install_config" >> "$systemd_service_temp"

  sudo cp "$systemd_service_temp" "$systemd_config_path"
}

function start_vault {
  log_info "Reloading systemd config and starting Vault"
  sudo systemctl daemon-reload
  sudo systemctl enable vault.service
  sudo systemctl restart vault.service
  sudo systemctl status vault.service
}

function main {
  local version=""
  local download_url=""
  local path="$DEFAULT_INSTALL_PATH"
  local user="$DEFAULT_VAULT_USER"
  local group="$DEFAULT_VAULT_GROUP"
  local skip_package_update="$DEFAULT_SKIP_PACKAGE_UPDATE"

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --version)
        version="$2"
        shift
        ;;
      --download-url)
        download_url="$2"
        shift
        ;;
      --path)
        path="$2"
        shift
        ;;
      --user)
        user="$2"
        shift
        ;;
      --group)
        group="$2"
        shift
        ;;
      --skip-package-update)
        skip_package_update="true"
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        log_error "Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  assert_either_or "--version" "$version" "--download-url" "$download_url"
  assert_not_empty "--path" "$path"
  assert_not_empty "--user" "$user"

  log_info "Starting Vault install"

  install_dependencies "$skip_package_update"
  create_vault_user "$user"
  create_vault_install_paths "$path" "$user"
  fetch_binary "$version" "$download_url"
  install_binary "$path" "$user"
  configure_mlock

  log_info "Running as Vault agent"
  generate_systemd_config \
    "$SYSTEMD_CONFIG_PATH" \
    "$path/config" \
    "$path/bin" \
    "info" \
    "$user" \
    "$group"

  start_vault

  if command -v vault; then
    log_info "Vault install complete!"
  else
    log_info "Could not find vault command. Aborting.";
    exit 1;
  fi
}

main "$@"
