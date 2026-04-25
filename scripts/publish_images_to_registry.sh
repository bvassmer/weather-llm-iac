#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
IAC_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(CDPATH= cd -- "$IAC_DIR/.." && pwd)"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$IAC_DIR/.env}"
COMPOSE_ENV_LOCAL_FILE="${COMPOSE_ENV_LOCAL_FILE:-$IAC_DIR/.env.local}"

load_env_file() {
  env_file="$1"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
}

load_env_files() {
  load_env_file "$COMPOSE_ENV_FILE"
  load_env_file "$COMPOSE_ENV_LOCAL_FILE"
}

load_env_files

LOCAL_REGISTRY_HOST="${LOCAL_REGISTRY_HOST:-192.168.6.87}"
LOCAL_REGISTRY_PORT="${LOCAL_REGISTRY_PORT:-5000}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}"
VITE_WEATHER_LLM_API_BASE_URL="${VITE_WEATHER_LLM_API_BASE_URL:-http://192.168.6.87:3000}"
VITE_SSE_IDLE_TIMEOUT_MS="${VITE_SSE_IDLE_TIMEOUT_MS:-150000}"

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

registry_repo() {
  service_name="$1"
  printf '%s' "$LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT/$service_name:$IMAGE_TAG"
}

build_and_push() {
  service_name="$1"
  context_dir="$2"
  dockerfile_path="$3"
  shift 3

  image_ref="$(registry_repo "$service_name")"
  info "Building and pushing $image_ref"
  docker build --platform "$DOCKER_PLATFORM" -f "$dockerfile_path" -t "$image_ref" "$@" "$context_dir"
  docker push "$image_ref"
}

main() {
  require_command docker

  build_and_push \
    weather-llm-api \
    "$WORKSPACE_ROOT/weather-llm-api" \
    "$WORKSPACE_ROOT/weather-llm-api/Dockerfile"

  build_and_push \
    weather-llm-client \
    "$WORKSPACE_ROOT/weather-llm" \
    "$WORKSPACE_ROOT/weather-llm/Dockerfile" \
    --build-arg "VITE_WEATHER_LLM_API_BASE_URL=$VITE_WEATHER_LLM_API_BASE_URL" \
    --build-arg "VITE_SSE_IDLE_TIMEOUT_MS=$VITE_SSE_IDLE_TIMEOUT_MS"

  build_and_push \
    weather-llm-nwsalerts \
    "$WORKSPACE_ROOT/nwsAlerts" \
    "$WORKSPACE_ROOT/nwsAlerts/Dockerfile"

  info "Published images to $LOCAL_REGISTRY_HOST:$LOCAL_REGISTRY_PORT with tag $IMAGE_TAG"
}

main "$@"