#!/bin/sh

set -eu

CHAT_BASE_URL="${OLLAMA_CHAT_BASE_URL:-${OLLAMA_BASE_URL:-http://localhost:11434}}"
CHAT_MODEL="${OLLAMA_CHAT_MODEL:-}"

fail() {
  echo "✗ ERROR: $*" >&2
  exit 1
}

check_model_config() {
  [ -n "$CHAT_MODEL" ] || fail "OLLAMA_CHAT_MODEL is not set."
}

check_tags() {
  base_url="$1"
  model="$2"
  target_file="$3"
  label="$4"

  echo ">>> Checking ${label} connectivity at ${base_url} ..."
  curl -sf --max-time 10 "${base_url}/api/tags" -o "$target_file" || \
    fail "Cannot reach ${label} endpoint at ${base_url}."

  echo ">>> ${label} reachable. Checking for model: ${model} ..."
  grep -q "${model}" "$target_file" || \
    fail "Model ${model} is not found on the ${label} endpoint."
}

generate_request_body() {
  printf '{"model":"%s","prompt":"%s","stream":false,"options":{"temperature":0,"num_predict":8}}' \
    "$CHAT_MODEL" \
    'Reply with ok.'
}

probe_generate() {
  payload="$(generate_request_body)"
  attempt=1
  max_attempts=3

  echo ">>> Probing generation on ${CHAT_BASE_URL} with model ${CHAT_MODEL} ..."

  while :; do
    if response="$(curl -sf --max-time 20 "${CHAT_BASE_URL}/api/generate" \
      -H 'Content-Type: application/json' \
      -d "$payload")"; then
      break
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      fail "Generation probe failed at ${CHAT_BASE_URL}."
    fi

    echo ">>> Generation probe attempt ${attempt}/${max_attempts} failed; retrying ..."
    attempt=$((attempt + 1))
    sleep 2
  done

  printf '%s' "$response" | grep -q '"response"' || \
    fail "Generation probe returned an unexpected payload."
}

main() {
  check_model_config
  check_tags "$CHAT_BASE_URL" "$CHAT_MODEL" /tmp/chat-tags.json generation
  probe_generate
  echo "✓ Ollama-compatible generation pre-flight passed."
}

main "$@"