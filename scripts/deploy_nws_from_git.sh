#!/bin/sh

set -eu

STACK_ROOT="${STACK_ROOT:-/home/pi/development/weather-stack}"
IAC_DIR="${IAC_DIR:-$STACK_ROOT/weather-llm-iac}"
DEFAULT_BRANCH="main"
GITHUB_SSH_KEY_PATH="${GITHUB_SSH_KEY_PATH:-$HOME/.ssh/id_github}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$IAC_DIR/.env}"
COMPOSE_ENV_LOCAL_FILE="${COMPOSE_ENV_LOCAL_FILE:-$IAC_DIR/.env.local}"
PREFER_PREBUILT_IMAGES="${PREFER_PREBUILT_IMAGES:-false}"

WEATHER_LLM_IAC_URL="git@github.com:bvassmer/weather-llm-iac.git"
NWS_ALERTS_URL="git@github.com:bvassmer/rPiWx.git"
WEATHER_LLM_API_URL="git@github.com:bvassmer/weather-llm-api.git"
WEATHER_LLM_URL="git@github.com:bvassmer/weather-llm.git"

info() {
  echo ">>> $*"
}

section_start() {
  date +%s
}

section_end() {
  section_name="$1"
  started_at="$2"
  finished_at="$(date +%s)"
  elapsed="$((finished_at - started_at))"
  info "$section_name completed in ${elapsed}s"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy_nws_from_git.sh <target>

Targets:
  registry   Update weather-llm-iac, then recreate the local image registry.
  full       Update weather-llm-iac, nwsAlerts, weather-llm-api, and weather-llm, then rebuild the full stack.
  api        Update weather-llm-iac and weather-llm-api, then recreate api and api-worker.
  client     Update weather-llm-iac and weather-llm, then recreate client.
  nwsalerts  Update weather-llm-iac and nwsAlerts, then recreate nwsalerts.

Environment overrides:
  STACK_ROOT  Defaults to /home/pi/development/weather-stack.
  IAC_DIR     Defaults to $STACK_ROOT/weather-llm-iac.
  GITHUB_SSH_KEY_PATH  Defaults to $HOME/.ssh/id_github.

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

load_compose_env() {
  if [ -f "$COMPOSE_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$COMPOSE_ENV_FILE"
    set +a
  fi

  if [ -f "$COMPOSE_ENV_LOCAL_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$COMPOSE_ENV_LOCAL_FILE"
    set +a
  fi
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

run_compose_command() {
  compose_command="$1"

  info "Running $compose_command"
  (
    cd "$IAC_DIR"
    sh -c "$compose_command"
  )
}

build_flag() {
  if [ "$PREFER_PREBUILT_IMAGES" = "true" ]; then
    printf '%s' ""
  else
    printf '%s' " --build"
  fi
}

local_registry_endpoint() {
  printf '%s' "${LOCAL_REGISTRY_HOST:-192.168.6.87}:${LOCAL_REGISTRY_PORT:-5000}"
}

uses_local_registry() {
  registry_endpoint="$(local_registry_endpoint)"

  for image_ref in \
    "${WEATHER_LLM_API_IMAGE:-}" \
    "${WEATHER_LLM_CLIENT_IMAGE:-}" \
    "${WEATHER_LLM_NWSALERTS_IMAGE:-}"
  do
    case "$image_ref" in
      "$registry_endpoint"/*)
        return 0
        ;;
    esac
  done

  return 1
}

ensure_local_registry() {
  run_compose_command "sudo docker-compose up -d registry"
}

pull_target_images() {
  target="$1"

  if [ "$PREFER_PREBUILT_IMAGES" != "true" ]; then
    return
  fi

  if uses_local_registry; then
    ensure_local_registry
  fi

  case "$target" in
    registry)
      return
      ;;
    full)
      run_compose_command "sudo docker-compose pull api api-migrate api-worker client nwsalerts nwsalerts-schema"
      ;;
    api)
      run_compose_command "sudo docker-compose pull api api-migrate api-worker"
      ;;
    client)
      run_compose_command "sudo docker-compose pull client"
      ;;
    nwsalerts)
      run_compose_command "sudo docker-compose pull nwsalerts nwsalerts-schema"
      ;;
    *)
      fail "Unsupported deploy target: $target"
      ;;
  esac
}

run_api_schema_step() {
  run_compose_command "sudo docker-compose up -d postgres"
  run_compose_command "sudo docker-compose up$(build_flag) api-migrate"
}

run_nwsalerts_schema_step() {
  require_healthy_mariadb
  run_compose_command "sudo docker-compose up$(build_flag) nwsalerts-schema"
}

run_compose() {
  target="$1"

  [ -d "$IAC_DIR/.git" ] || fail "weather-llm-iac checkout not found at $IAC_DIR."

  case "$target" in
    registry)
      compose_command="sudo docker-compose up -d registry"
      ;;
    full)
      pull_target_images "$target"
      run_compose_command "sudo docker-compose up -d postgres qdrant nwsalerts-mariadb ollama-preflight"
      run_api_schema_step
      run_nwsalerts_schema_step
      compose_command="sudo docker-compose up$(build_flag) -d api api-worker client nwsalerts"
      ;;
    api)
      pull_target_images "$target"
      run_compose_command "sudo docker-compose up -d postgres qdrant nwsalerts-mariadb ollama-preflight"
      run_api_schema_step
      compose_command="sudo docker-compose up -d$(build_flag) --no-deps --force-recreate api api-worker"
      ;;
    client)
      pull_target_images "$target"
      compose_command="sudo docker-compose up -d$(build_flag) --no-deps --force-recreate client"
      ;;
    nwsalerts)
      pull_target_images "$target"
      run_nwsalerts_schema_step
      compose_command="sudo docker-compose up -d$(build_flag) --no-deps --force-recreate nwsalerts"
      ;;
    *)
      fail "Unsupported deploy target: $target"
      ;;
  esac

  run_compose_command "$compose_command"
}

update_for_target() {
  target="$1"
  started_at="$(section_start)"

  update_repo "weather-llm-iac" "$IAC_DIR" "$WEATHER_LLM_IAC_URL"

  case "$target" in
    registry)
      ;;
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

  section_end "Git update for $target" "$started_at"
}

main() {
  [ "$#" -eq 1 ] || {
    usage
    exit 1
  }

  target="$1"

  case "$target" in
    registry|full|api|client|nwsalerts)
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

  load_compose_env
  deploy_started_at="$(section_start)"
  check_github_auth
  update_for_target "$target"
  compose_started_at="$(section_start)"
  run_compose "$target"
  section_end "Compose recreate for $target" "$compose_started_at"
  section_end "Total deploy for $target" "$deploy_started_at"
  info "Deploy completed for target: $target"
}

main "$@"