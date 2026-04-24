#!/bin/sh

set -eu

STACK_ROOT="${STACK_ROOT:-/home/pi/development/weather-stack}"
IAC_DIR="${IAC_DIR:-$STACK_ROOT/weather-llm-iac}"
DAEMON_CONFIG_PATH="${DAEMON_CONFIG_PATH:-/etc/docker/daemon.json}"
LOCAL_REGISTRY_HOST="${LOCAL_REGISTRY_HOST:-192.168.6.87}"
LOCAL_REGISTRY_PORT="${LOCAL_REGISTRY_PORT:-5000}"

info() {
  echo ">>> $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
  [ -f "$1" ] || fail "Required file not found: $1"
}

registry_endpoint() {
  printf '%s' "$LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT"
}

ensure_daemon_config() {
  endpoint="$(registry_endpoint)"

  if [ ! -f "$DAEMON_CONFIG_PATH" ]; then
    info "Creating $DAEMON_CONFIG_PATH for insecure registry $endpoint"
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "$endpoint" | sudo tee "$DAEMON_CONFIG_PATH" >/dev/null
    sudo systemctl restart docker
    return
  fi

  if grep -Fq '"insecure-registries"' "$DAEMON_CONFIG_PATH"; then
    if grep -Fq "$endpoint" "$DAEMON_CONFIG_PATH"; then
      info "Docker daemon already trusts $endpoint"
      return
    fi

    fail "$DAEMON_CONFIG_PATH already defines insecure-registries. Merge $(registry_endpoint) manually to avoid overwriting host config."
  fi

  if [ "$(tr -d '[:space:]' < "$DAEMON_CONFIG_PATH")" = '{}' ]; then
    info "Replacing empty Docker daemon config with insecure registry entry for $endpoint"
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "$endpoint" | sudo tee "$DAEMON_CONFIG_PATH" >/dev/null
    sudo systemctl restart docker
    return
  fi

  fail "$DAEMON_CONFIG_PATH exists with unmanaged content. Merge $(registry_endpoint) manually before rerunning this helper."
}

main() {
  require_command sudo
  require_command systemctl
  require_command sh
  require_file "$IAC_DIR/scripts/deploy_nws_from_git.sh"

  ensure_daemon_config

  info "Starting local registry via deploy wrapper"
  (
    cd "$IAC_DIR"
    sh ./scripts/deploy_nws_from_git.sh registry
  )

  info "Local registry setup complete at http://$(registry_endpoint)"
}

main "$@"