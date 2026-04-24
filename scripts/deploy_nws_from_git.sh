#!/bin/sh

set -eu

STACK_ROOT="${STACK_ROOT:-/home/pi/development/weather-stack}"
IAC_DIR="${IAC_DIR:-$STACK_ROOT/weather-llm-iac}"
DEFAULT_BRANCH="main"
GITHUB_SSH_KEY_PATH="${GITHUB_SSH_KEY_PATH:-$HOME/.ssh/github}"

WEATHER_LLM_IAC_URL="git@github.com:bvassmer/weather-llm-iac.git"
NWS_ALERTS_URL="git@github.com:bvassmer/nws-alerts.git"
WEATHER_LLM_API_URL="git@github.com:bvassmer/weather-llm-api.git"
WEATHER_LLM_URL="git@github.com:bvassmer/weather-llm.git"

info() {
  echo ">>> $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy_nws_from_git.sh <target>

Targets:
  full       Update weather-llm-iac, nwsAlerts, weather-llm-api, and weather-llm, then rebuild the full stack.
  api        Update weather-llm-iac and weather-llm-api, then recreate api and api-worker.
  client     Update weather-llm-iac and weather-llm, then recreate client.
  nwsalerts  Update weather-llm-iac and nwsAlerts, then recreate nwsalerts.

Environment overrides:
  STACK_ROOT  Defaults to /home/pi/development/weather-stack.
  IAC_DIR     Defaults to $STACK_ROOT/weather-llm-iac.
  GITHUB_SSH_KEY_PATH  Defaults to $HOME/.ssh/github.

Before the first deploy, copy the GitHub SSH key you want to use onto the Pi and
set its permissions to 600.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
  [ -f "$1" ] || fail "Required file not found: $1"
}

git_ssh_command() {
  printf '%s' "ssh -i $GITHUB_SSH_KEY_PATH -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
}

git_with_key() {
  GIT_SSH_COMMAND="$(git_ssh_command)" git "$@"
}

check_github_auth() {
  info "Checking GitHub SSH access ..."
  require_file "$GITHUB_SSH_KEY_PATH"

  set +e
  ssh \
    -i "$GITHUB_SSH_KEY_PATH" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -T git@github.com >/dev/null 2>&1
  status=$?
  set -e

  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || \
    fail "GitHub SSH authentication failed for git@github.com using $GITHUB_SSH_KEY_PATH. Copy a GitHub-authorized key to the Pi or set GITHUB_SSH_KEY_PATH explicitly."
}

clone_if_missing() {
  repo_name="$1"
  repo_path="$2"
  repo_url="$3"

  if [ -d "$repo_path/.git" ]; then
    return
  fi

  if [ -e "$repo_path" ]; then
    fail "$repo_name exists at $repo_path but is not a Git checkout. Archive or remove it before using this script."
  fi

  info "Cloning $repo_name into $repo_path ..."
  mkdir -p "$(dirname "$repo_path")"
  git_with_key clone "$repo_url" "$repo_path"
}

assert_clean_repo() {
  repo_name="$1"
  repo_path="$2"

  [ -d "$repo_path/.git" ] || fail "$repo_name is not a Git checkout at $repo_path."

  status_output="$(git -C "$repo_path" status --porcelain)"
  [ -z "$status_output" ] || \
    fail "$repo_name checkout at $repo_path is dirty. Commit, stash, or clean it before deploying."
}

checkout_main() {
  repo_path="$1"

  if git -C "$repo_path" rev-parse --verify "$DEFAULT_BRANCH" >/dev/null 2>&1; then
    git -C "$repo_path" checkout "$DEFAULT_BRANCH" >/dev/null 2>&1 || \
      git -C "$repo_path" checkout "$DEFAULT_BRANCH"
    return
  fi

  git -C "$repo_path" checkout -b "$DEFAULT_BRANCH" --track "origin/$DEFAULT_BRANCH"
}

update_repo() {
  repo_name="$1"
  repo_path="$2"
  repo_url="$3"

  clone_if_missing "$repo_name" "$repo_path" "$repo_url"
  assert_clean_repo "$repo_name" "$repo_path"

  info "Updating $repo_name from origin/$DEFAULT_BRANCH ..."
  git_with_key -C "$repo_path" fetch --prune origin
  checkout_main "$repo_path"
  git_with_key -C "$repo_path" pull --ff-only origin "$DEFAULT_BRANCH"
}

require_healthy_mariadb() {
  health_status="$({
    sudo docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      weather-llm-nwsalerts-mariadb
  } 2>/dev/null || true)"

  [ "$health_status" = "healthy" ] || \
    fail "weather-llm-nwsalerts-mariadb must be healthy before deploying nwsalerts (current: ${health_status:-missing})."
}

run_compose() {
  target="$1"

  [ -d "$IAC_DIR/.git" ] || fail "weather-llm-iac checkout not found at $IAC_DIR."

  case "$target" in
    full)
      compose_command="sudo docker-compose up --build -d"
      ;;
    api)
      compose_command="sudo docker-compose up -d --build --no-deps --force-recreate api api-worker"
      ;;
    client)
      compose_command="sudo docker-compose up -d --build --no-deps --force-recreate client"
      ;;
    nwsalerts)
      require_healthy_mariadb
      compose_command="sudo docker-compose up -d --build --no-deps --force-recreate nwsalerts"
      ;;
    *)
      fail "Unsupported deploy target: $target"
      ;;
  esac

  info "Running $compose_command"
  (
    cd "$IAC_DIR"
    sh -c "$compose_command"
  )
}

update_for_target() {
  target="$1"

  update_repo "weather-llm-iac" "$IAC_DIR" "$WEATHER_LLM_IAC_URL"

  case "$target" in
    full)
      update_repo "nwsAlerts" "$STACK_ROOT/nwsAlerts" "$NWS_ALERTS_URL"
      update_repo "weather-llm-api" "$STACK_ROOT/weather-llm-api" "$WEATHER_LLM_API_URL"
      update_repo "weather-llm" "$STACK_ROOT/weather-llm" "$WEATHER_LLM_URL"
      ;;
    api)
      update_repo "weather-llm-api" "$STACK_ROOT/weather-llm-api" "$WEATHER_LLM_API_URL"
      ;;
    client)
      update_repo "weather-llm" "$STACK_ROOT/weather-llm" "$WEATHER_LLM_URL"
      ;;
    nwsalerts)
      update_repo "nwsAlerts" "$STACK_ROOT/nwsAlerts" "$NWS_ALERTS_URL"
      ;;
    *)
      fail "Unsupported deploy target: $target"
      ;;
  esac
}

main() {
  [ "$#" -eq 1 ] || {
    usage
    exit 1
  }

  target="$1"

  case "$target" in
    full|api|client|nwsalerts)
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown deploy target: $target"
      ;;
  esac

  require_command git
  require_command ssh
  require_command sudo
  require_command docker-compose

  check_github_auth
  update_for_target "$target"
  run_compose "$target"
  info "Deploy completed for target: $target"
}

main "$@"