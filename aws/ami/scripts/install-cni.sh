#!/bin/bash

set -e

export DEBIAN_FRONTEND="noninteractive"
readonly DEFAULT_INSTALL_PATH="/opt/cni"
readonly DEFAULT_CNI_USER="consul"
readonly DOWNLOAD_PACKAGE_PATH="/tmp/cni-plugins.tgz"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SYSTEM_BIN_DIR="/usr/local/bin"

readonly SCRIPT_NAME="$(basename "$0")"

function print_usage {
  echo
  echo "Usage: install-cni [OPTIONS]"
  echo
  echo "This script can be used to install cni and its dependencies. This script has been tested with Ubuntu 16.04/18.04/20.04 and Amazon Linux 2."
  echo
  echo "Options:"
  echo
  echo -e "  --version\t\tThe version of cni to install. Optional if download-url is provided."
  echo -e "  --download-url\t\tUrl to exact cni package to be installed. Optional if version is provided."
  echo -e "  --path\t\tThe path where cni should be installed. Optional. Default: $DEFAULT_INSTALL_PATH."
  echo -e "  --user\t\tThe user who will own the cni install directories. Optional. Default: $DEFAULT_CNI_USER."
  echo "Example:"
  echo
  echo "  install-cni --version 1.2.0"
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
  [ -n "$(command -v yum)" ]
}

function has_apt_get {
  [ -n "$(command -v apt-get)" ]
}

function install_dependencies {
  log_info "Installing dependencies"

  if has_apt_get; then
    sudo apt-get update -y
    sudo apt-get install -y awscli curl unzip jq
  elif has_yum; then
    sudo yum update -y
    sudo yum install -y aws curl unzip jq
  else
    log_error "Could not find apt-get or yum. Cannot install dependencies on this OS."
    exit 1
  fi
}

function user_exists {
  local -r username="$1"
  id "$username" >/dev/null 2>&1
}

function create_cni_user {
  local -r username="$1"

  if user_exists "$username"; then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd "$username"
  fi
}

function create_cni_install_paths {
  local -r path="$1"
  local -r username="$2"

  log_info "Creating install dirs for CNI Plugins at $path"
  sudo mkdir -p "$path"
  sudo mkdir -p "$path/bin"

  log_info "Changing ownership of $path to $username"
  sudo chown -R "$username:$username" "$path"
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
    *)
      log_error "CPU architecture $cpu_arch is not a supported by CNI Plugins."
      exit 1
      ;;
    esac

  if [[ -z "$download_url" && -n "$version" ]]; then
    download_url="https://github.com/containernetworking/plugins/releases/download/${version}/cni-plugins-linux-${binary_arch}-${version}.tgz"
  fi

  retry \
    "curl -o '$DOWNLOAD_PACKAGE_PATH' '$download_url' --location --silent --fail --show-error" \
    "Downloading CNI Plugins to $DOWNLOAD_PACKAGE_PATH"
}

function install_binary {
  local -r install_path="$1"
  local -r username="$2"

  local -r bin_dir="$install_path/bin"

  mkdir -pv /tmp/cni-plugins
  tar -C /tmp/cni-plugins -xvzf $DOWNLOAD_PACKAGE_PATH

  log_info "Moving CNI Plugins binary to $bin_dir"
  sudo mv /tmp/cni-plugins/* $bin_dir
  sudo chown "$username:$username" $bin_dir
  sudo chmod -R a+x $bin_dir/*
}

function configure_sysctl_patch() {
  log_info "Configuring sysctl to allow use of CNI Plugins Feature"

  cat > /tmp/11-cni-plugins.conf <<EOF
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1

EOF
  sudo cp /tmp/11-cni-plugins.conf /etc/sysctl.d/11-cni-plugins.conf
  sudo sysctl -p
  log_info "Done configuring the sysctl patch!"
}

function main {
  local version=""
  local download_url=""
  local path="$DEFAULT_INSTALL_PATH"
  local user="$DEFAULT_CNI_USER"

  while [[ $# -gt 0 ]]; do
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

  log_info "Starting CNI Plugins install"

  install_dependencies
  create_cni_user "$user"
  create_cni_install_paths "$path" "$user"

  fetch_binary "$version" "$download_url"
  install_binary "$path" "$user"
  configure_sysctl_patch
}

main "$@"
