#!/bin/bash

set -e

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

function configure_sysctl_patch() {
  log_info "Patching sysctl for AWS SSM Agent..."

  cat > /tmp/12-aws-ssm.conf <<EOF
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024

EOF
  sudo cp /tmp/12-aws-ssm.conf /etc/sysctl.d/12-aws-ssm.conf
  sudo sysctl -p
  log_info "Sysctl patch done!"
}

function enable_ssm() {
  log_info "Enabling SSM Agent Services..."
  sudo snap list
  sudo snap start amazon-ssm-agent
  sudo snap services amazon-ssm-agent
  sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service
}

function main() {
  configure_sysctl_patch
  enable_ssm
}

main "$@"
