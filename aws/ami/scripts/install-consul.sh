#!/bin/bash

set -e

export DEBIAN_FRONTEND="noninteractive"
readonly DEFAULT_INSTALL_PATH="/opt/consul"
readonly DEFAULT_CONSUL_USER="consul"
readonly DEFAULT_CONSUL_GROUP="hashistack"
readonly DOWNLOAD_PACKAGE_PATH="/tmp/consul.zip"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SYSTEM_BIN_DIR="/usr/local/bin"

readonly SCRIPT_NAME="$(basename "$0")"

function print_usage {
  echo
  echo "Usage: install-consul [OPTIONS]"
  echo
  echo "This script can be used to install Consul and its dependencies. This script has been tested with Ubuntu 16.04/18.04/20.04 and Amazon Linux 2."
  echo
  echo "Options:"
  echo
  echo -e "  --version\t\tThe version of Consul to install. Optional if download-url is provided."
  echo -e "  --download-url\t\tUrl to exact Consul package to be installed. Optional if version is provided."
  echo -e "  --path\t\tThe path where Consul should be installed. Optional. Default: $DEFAULT_INSTALL_PATH."
  echo -e "  --user\t\tThe user who will own the Consul install directories. Optional. Default: $DEFAULT_CONSUL_USER."
  echo -e "  --ca-file-path\t\tPath to a PEM-encoded certificate authority used to encrypt and verify authenticity of client and server connections. Will be installed under <install-path>/tls/ca."
  echo -e "  --cert-file-path\t\tPath to a PEM-encoded certificate, which will be provided to clients or servers to verify the agent's authenticity. Will be installed under <install-path>/tls. Must be provided along with --key-file-path."
  echo -e "  --key-file-path\t\tPath to a PEM-encoded private key, used with the certificate to verify the agent's authenticity. Will be installed under <install-path>/tls. Must be provided along with --cert-file-path"
  echo
  echo "Example:"
  echo
  echo "  install-consul --version 1.15.1"
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

function create_consul_user {
  local -r username="$1"

  if user_exists "$username"; then
    echo "User $username already exists. Will not create again."
  else
    log_info "Creating user named $username"
    sudo useradd "$username"
  fi
}

function create_consul_install_paths {
  local -r path="${1}"
  local -r username="${2}"
  local -r group="${3}"

  log_info "Creating install dirs for Consul at $path"
  sudo mkdir -pv "$path"
  sudo mkdir -pv "$path/bin"
  sudo mkdir -pv "$path/config"
  sudo mkdir -pv "$path/data"
  sudo mkdir -pv "$path/tls"
  sudo mkdir -pv "$path/log"
  sudo chmod -R 770 "$path"

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
      # The following info is taken from https://www.consul.io/downloads
      #
      # Note for ARM users:
      #
      # Use Armelv5 for all 32-bit armel systems
      # Use Armhfv6 for all armhf systems with v6+ architecture
      # Use Arm64 for all v8 64-bit architectures
      # The following commands can help determine the right version for your system:
      #
      # $ uname -m
      # $ readelf -a /proc/self/exe | grep -q -c Tag_ABI_VFP_args && echo "armhf" || echo "armel"
      #
      local vfp_tag
      vfp_tag="$(readelf -a /proc/self/exe | grep -q -c Tag_ABI_VFP_args)"
      if [[ -z $vfp_tag  ]]; then
        binary_arch="armelv5"
      else
        binary_arch="armhfv6"
      fi
      ;;
    *)
      log_error "CPU architecture $cpu_arch is not a supported by Consul."
      exit 1
      ;;
    esac

  if [[ -z "$download_url" && -n "$version" ]]; then
    download_url="https://releases.hashicorp.com/consul/${version}/consul_${version}_linux_${binary_arch}.zip"
  fi

  retry \
    "curl -o '$DOWNLOAD_PACKAGE_PATH' '$download_url' --location --silent --fail --show-error" \
    "Downloading Consul to $DOWNLOAD_PACKAGE_PATH"
}

function install_binary {
  local -r install_path="$1"
  local -r username="$2"

  local -r bin_dir="$install_path/bin"
  local -r consul_dest_path="$bin_dir/consul"
  # local -r run_consul_dest_path="$bin_dir/run-consul"

  unzip -d /tmp "$DOWNLOAD_PACKAGE_PATH"

  log_info "Moving Consul binary to $consul_dest_path"
  sudo mv "/tmp/consul" "$consul_dest_path"
  sudo chown "$username:$username" "$consul_dest_path"
  sudo chmod a+x "$consul_dest_path"

  local -r symlink_path="$SYSTEM_BIN_DIR/consul"
  if [[ -f "$symlink_path" ]]; then
    log_info "Symlink $symlink_path already exists. Will not add again."
  else
    log_info "Adding symlink to $consul_dest_path in $symlink_path"
    sudo ln -s "$consul_dest_path" "$symlink_path"
  fi
}

function main {
  local version=""
  local download_url=""
  local path="$DEFAULT_INSTALL_PATH"
  local user="$DEFAULT_CONSUL_USER"
  local group="$DEFAULT_CONSUL_GROUP"

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
      --group)
        group="$2"
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

  log_info "Starting Consul install"

  install_dependencies
  create_consul_user "$user"
  create_consul_install_paths "$path" "$user" "$group"

  fetch_binary "$version" "$download_url"
  install_binary "$path" "$user"

  # This command is run with sudo rights so that it will succeed in cases where image hardening alters the permissions
  # on the directories where Consul may be installed. See https://github.com/hashicorp/terraform-aws-consul/issues/210.
  if sudo -E PATH=$PATH bash -c "command -v consul"; then
    log_info "Consul install complete!";
  else
    log_info "Could not find consul command. Aborting.";
    exit 1;
  fi
}

main "$@"
