# weather-llm-iac

This repository is the authoritative overall README for the current two-Raspberry Pi weather and AI deployment.

Today the stack is split across two hosts:

- `ai-hub` (`192.168.7.176`): Raspberry Pi 5 with 2 GB RAM and AI HAT+ 2, serving the Ollama-compatible LLM endpoint.
- `nws` (`192.168.6.87`): Raspberry Pi 4 with 4 GB RAM, running the weather data stack, vector database, API, and web UI.

Use this README for system-level deployment and operations. Use the component READMEs for deeper implementation detail:

- [../weather-llm/](../weather-llm/)
- [../weather-llm-api/README.md](../weather-llm-api/README.md)
- [../nwsAlerts/README.md](../nwsAlerts/README.md)
- [../rPi-5-ai/README.md](../rPi-5-ai/README.md)
- [../wx-modules/docs/ingestion-overview.md](../wx-modules/docs/ingestion-overview.md)

## System overview

| Host     | IP              | Hardware                            | Role                                            | Services                                                                                                           |
| -------- | --------------- | ----------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `ai-hub` | `192.168.7.176` | Raspberry Pi 5, 2 GB RAM, AI HAT+ 2 | LLM backend                                     | `hailo-ollama`, `nginx`, Ollama-compatible API on port `11434`                                                     |
| `nws`    | `192.168.6.87`  | Raspberry Pi 4, 4 GB RAM            | Weather aggregation, vector search, API, and UI | `weather-llm`, `weather-llm-api`, `weather-llm-api-worker`, `nwsalerts`, `postgres`, `nwsalerts-mariadb`, `qdrant` |

### Current working topology

- The user-facing web app runs on `http://192.168.6.87:5173`.
- The API runs on `http://192.168.6.87:3000`.
- Qdrant currently runs on `nws` and is exposed on `http://192.168.6.87:6333`.
- PostgreSQL for `weather-llm-api` runs on `nws` port `5432`.
- MariaDB for `nwsalerts` runs on `nws` port `3307`.
- The Ollama-compatible generation backend runs on `ai-hub` at `http://192.168.7.176:11434`.

### Intended direction

The intended system behavior is:

- `ai-hub` acts as the dedicated AI node that serves the LLM used to answer weather questions.
- `nws` acts as the weather data aggregator that collects forecasts, outlooks, active events, and related products.
- The overall experience presented to the user is a single weather assistant UI on port `5173` that answers questions using retrieved weather context.

Important current-state note: the deployed stack today still runs Qdrant on `nws` through Docker Compose. Do not read this README as claiming that Qdrant already runs on `ai-hub`.

## End-to-end flow

```text
Public weather sources
	-> nwsalerts polling and normalization on nws
	-> MariaDB persistence and optional alert email delivery
	-> embedding outbox dispatch to weather-llm-api
	-> in-process embeddings in weather-llm-api
	-> Qdrant vector storage on nws
	-> user query from weather-llm on port 5173
	-> query embedding + vector search in weather-llm-api
	-> grounded answer generation through Ollama on ai-hub
```

### What each part does

1. `nwsalerts` polls public sources such as NWS alerts, SPC outlooks, WPC products, and related weather feeds.
2. `nwsalerts` stores normalized alert records in MariaDB and can send important alert emails when SMTP settings are configured.
3. `nwsalerts` queues embedding jobs and dispatches them to `POST /nws-alerts/embeddings:ingest` on `weather-llm-api`.
4. `weather-llm-api` generates embeddings locally using `Xenova/all-MiniLM-L6-v2` by default and writes vectors into Qdrant.
5. A user asks a question in `weather-llm` on port `5173`.
6. `weather-llm-api` embeds the query locally, retrieves relevant documents from Qdrant, and sends grounded context to the Ollama-compatible endpoint on `ai-hub`.
7. The UI streams an answer back to the browser with citations.

## What runs on the `nws` host

This Compose stack is currently the deployment entry point for the `nws` machine.

| Service             | Host port      | Purpose                                                                   |
| ------------------- | -------------- | ------------------------------------------------------------------------- |
| `client`            | `5173`         | React and Vite UI for weather question answering                          |
| `api`               | `3000`         | NestJS API for embeddings, search, answers, and admin endpoints           |
| `api-worker`        | none           | Background queue worker for API-side embedding work                       |
| `qdrant`            | `6333`, `6334` | Vector database for weather document embeddings                           |
| `postgres`          | `5432`         | Relational data store for `weather-llm-api`                               |
| `nwsalerts-mariadb` | `3307`         | Relational data store for `nwsalerts`                                     |
| `nwsalerts`         | none           | Background weather ingestion, email alerts, and embedding outbox dispatch |

This stack now uses image-based service startup on `nws`: the API and worker run prebuilt Node artifacts, the browser client is served as a built SPA from nginx, and schema work runs as explicit one-shot services before the long-running containers are recreated.

## Key configuration

Copy the environment file first:

```bash
cp .env.example .env
```

To keep host-specific values from being overwritten by Git-based deploy updates,
put persistent overrides in `.env.local` (same `KEY=VALUE` format). The deploy
wrapper and image publish script load `.env` first and `.env.local` second, so
`.env.local` takes precedence when both define the same key.

Then update the values that define how the two Pis talk to each other.

| Variable                        | Recommended value for this deployment | Why it matters                                                              |
| ------------------------------- | ------------------------------------- | --------------------------------------------------------------------------- |
| `OLLAMA_BASE_URL`               | `http://192.168.7.176:11434`          | Points API generation requests at `ai-hub`                                  |
| `OLLAMA_CHAT_BASE_URL`          | optional override                     | Use only if generation is exposed on a different URL than `OLLAMA_BASE_URL` |
| `OLLAMA_CHAT_MODEL`             | `qwen3:1.7b` or your validated model  | Controls the answer-generation model                                        |
| `VITE_WEATHER_LLM_API_BASE_URL` | `http://192.168.6.87:3000`            | Browser-side API base URL used by the UI                                    |
| `CORS_ORIGIN`                   | `http://192.168.6.87:5173`            | Allows the browser UI to call the API                                       |
| `NWS_EMBEDDING_MODEL`           | `Xenova/all-MiniLM-L6-v2`             | Local embedding model downloaded by `weather-llm-api`                       |
| `QDRANT_VECTOR_SIZE`            | `384`                                 | Must match the embedding model output dimension                             |
| `QDRANT_COLLECTION_NWS_ALERTS`  | `nws_alerts_embeddings_v1`            | Main collection for stored weather vectors                                  |
| `ALERT_EMAIL_TO`                | `bvassmer@gmail.com`                  | Where important weather emails are delivered                                |

Notes:

- Use a routable IP address or standard DNS name for `OLLAMA_BASE_URL`. `.local` hostnames often resolve on the host but fail inside Docker containers.
- Keep `VITE_WEATHER_LLM_API_BASE_URL` explicit. Browser-side values are easiest to reason about when they match the real LAN address of `nws`.
- `weather-llm-api` generates embeddings in-process. Ollama on `ai-hub` is currently used for answer generation, not for weather document embeddings.
- On first boot, `weather-llm-api` downloads the embedding model into the shared cache mounted at `NWS_EMBEDDING_CACHE_DIR`. The cache is reused by both the API and worker containers.
- For image-based deploys, keep `PREFER_PREBUILT_IMAGES`, registry settings, and image refs in `.env` or `.env.local` so deploy and publish scripts resolve the same values.

### Qwen3 Considerations

- Use `OLLAMA_CHAT_MODEL=qwen3:1.7b` as the default on this stack unless you are intentionally rolling back.
- Keep `qwen2.5:1.5b` installed on `ai-hub` for rollback-only scenarios.
- Current weather services use conservative temperatures for deterministic behavior. This maps to Qwen3 non-thinking style usage.
- If you introduce explicit Qwen3 thinking-mode behavior later, update API-side generation settings to Qwen3-appropriate sampling values rather than reusing the current cold defaults.

## First-time deployment

### 1. Prepare `ai-hub`

On `ai-hub`, use the setup flow in [../rPi-5-ai/README.md](../rPi-5-ai/README.md) and [../rPi-5-ai/docs/deployment.md](../rPi-5-ai/docs/deployment.md).

Typical flow:

```bash
cd ../rPi-5-ai
sudo ./scripts/setup_pi.sh
./scripts/install_hailo_ollama.sh
sudo systemctl enable --now hailo-ai-appliance.service
./scripts/install_models.sh
./scripts/validate_ollama_compatibility.sh
```

Before continuing, verify that `ai-hub` serves the model you want to use for answer generation.

### 2. Configure the `nws` stack

On `nws`:

```bash
cd weather-llm-iac
cp .env.example .env
```

At minimum, update `.env` so the stack uses the real LAN addresses:

```bash
OLLAMA_BASE_URL=http://192.168.7.176:11434
VITE_WEATHER_LLM_API_BASE_URL=http://192.168.6.87:3000
CORS_ORIGIN=http://192.168.6.87:5173

ALERT_EMAIL_TO=bvassmer@gmail.com
ALERT_EMAIL_USER=your-smtp-user
ALERT_EMAIL_PASS=your-smtp-password
ALERT_EMAIL_FROM=your-from-address
```

If you want generation and embedding behavior to stay aligned with the current defaults, keep:

```bash
OLLAMA_CHAT_MODEL=qwen3:1.7b
NWS_EMBEDDING_MODEL=Xenova/all-MiniLM-L6-v2
QDRANT_VECTOR_SIZE=384
```

### 3. Start the stack on `nws`

```bash
docker compose up --build -d postgres qdrant nwsalerts-mariadb ollama-preflight
docker compose up --build api-migrate nwsalerts-schema
docker compose up --build -d api api-worker client nwsalerts
```

The Compose stack starts:

- MariaDB for `nwsalerts`
- PostgreSQL for `weather-llm-api`
- Qdrant
- the `nwsalerts` ingestion service
- the `weather-llm-api` API and worker
- the `weather-llm` UI

Before the API and ingestion services start, the one-shot `api-migrate` and `nwsalerts-schema` services apply the checked-in PostgreSQL migrations and the current MariaDB Prisma schema.

### 4. Ollama preflight behavior

Before `api` and `api-worker` start, the one-shot `ollama-preflight` container checks:

- the configured generation endpoint is reachable
- the configured chat model is available
- a small generation request succeeds

If that preflight fails, the API containers do not start.

## Verification

### Validate `ai-hub`

```bash
curl http://192.168.7.176:11434/api/tags
```

You should see the configured chat model in the returned model list.

### Validate the `nws` stack

```bash
curl http://192.168.6.87:3000/health
curl http://192.168.6.87:3000/health/cors
curl http://192.168.6.87:3000/nws-alerts/conversation/latest
```

Open the UI:

```text
http://192.168.6.87:5173
```

Optional search smoke test:

```bash
curl -X POST http://192.168.6.87:3000/nws-alerts/search \
	-H 'Content-Type: application/json' \
	-d '{"query":"What severe weather alerts are active in Oklahoma?","topK":5}'
```

End-to-end user test:

1. Open the UI on port `5173`.
2. Ask a weather question that should match recent alerts or outlooks.
3. Confirm the answer streams back and includes citations grounded in retrieved weather context.
4. Reload the page and confirm the latest thread rehydrates from PostgreSQL via `GET /nws-alerts/conversation/latest`.

## Operations

Follow logs for the main services:

```bash
docker compose logs -f client api api-worker nwsalerts
```

### Verified rollout patterns

Git-based rollout on `nws` is the standard path. Push code to GitHub first, then update the live Pi checkouts from GitHub and rebuild from there.

The deploy wrapper now supports two execution modes:

- Pi-local builds: the default path, which rebuilds images on `nws`.
- Prebuilt images: set `PREFER_PREBUILT_IMAGES=true` and provide image refs in `.env` to switch the wrapper to `docker-compose pull` plus recreate, while keeping the same Git-first orchestration and explicit schema steps.

### Local registry on `nws`

The preferred image-based path on the LAN is now a local Docker registry hosted on `nws`.

One-time setup on `nws`:

```bash
ssh pi@192.168.6.87 '
set -eu
cd /home/pi/development/weather-stack/weather-llm-iac
sh ./scripts/setup_local_registry_on_nws.sh
'
```

That helper configures Docker to trust `LOCAL_REGISTRY_HOST:LOCAL_REGISTRY_PORT` as an insecure LAN registry, then starts the Compose `registry` service.

### Full image rebuild workflow

This is the standard path when you have pushed code changes to GitHub and want to rebuild all three service images and deploy them.

**Prerequisites**: the Pi checkouts must be at the correct HEAD. The deploy wrapper handles git-pulling each checkout, so running it before the publish step is the simplest way to advance them.

**Step 1 — Push your changes to GitHub from the Mac (required before anything on the Pi).**

**Step 2 — SSH to `nws` and rebuild all images with `sudo`:**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 '
set -e
export GITHUB_SSH_KEY_PATH=$HOME/.ssh/id_github
# Update all live checkouts to origin/main first
cd /home/pi/development/weather-stack/weather-llm-iac
export GIT_SSH_COMMAND="ssh -i $GITHUB_SSH_KEY_PATH -o IdentitiesOnly=yes"
git pull --ff-only origin main
for repo in nwsAlerts weather-llm-api weather-llm; do
  git -C /home/pi/development/weather-stack/$repo pull --ff-only origin main
done
# Build and push all three images (sudo required for Docker socket)
sudo sh ./scripts/publish_images_to_registry.sh
'
```

`publish_images_to_registry.sh` builds `linux/arm64` images directly on the Pi from the live checkout directories and pushes them to the local registry at `192.168.6.87:5000`. It **must** be run with `sudo` on `nws`; running it without `sudo` or from a non-arm64 build machine will fail.

**Step 3 — Deploy the newly published images:**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 '
set -e
export GITHUB_SSH_KEY_PATH=$HOME/.ssh/id_github
cd /home/pi/development/weather-stack/weather-llm-iac
sh ./scripts/deploy_nws_from_git.sh full
'
```

The deploy wrapper re-pulls all Git checkouts, runs `docker-compose pull` to fetch the freshly published `:latest` images, runs schema migrations, and recreates the running containers.

**Step 4 — Verify live container health:**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 \
  'sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep weather-llm'
```

All four main containers (`weather-llm-nwsalerts`, `weather-llm-client`, `weather-llm-api`, `weather-llm-api-worker`) should show `(healthy)`.

### Avoid stale `:latest` deploys

`deploy_nws_from_git.sh` does not build images. In prebuilt-image mode it pulls what already exists in the local registry, then recreates containers. If `:latest` was not republished from current source, deploy can succeed while still running old code.

Use this checklist whenever behavior does not match the commit you pushed:

1. Confirm Pi checkouts were updated before publishing (`git pull --ff-only` in `weather-llm-iac` and app repos).
2. Run `sudo sh ./scripts/publish_images_to_registry.sh` on `nws`.
3. Confirm the publish output shows fresh build/push output for the service you changed (`weather-llm-client`, `weather-llm-api`, or `weather-llm-nwsalerts`).
4. Run `sh ./scripts/deploy_nws_from_git.sh <target>` immediately after publish (`client`, `api`, `nwsalerts`, or `full`).
5. Validate runtime behavior through endpoint checks, not only container status.

Quick target mapping:

- `weather-llm` UI change -> publish images -> `sh ./scripts/deploy_nws_from_git.sh client`
- `weather-llm-api` change -> publish images -> `sh ./scripts/deploy_nws_from_git.sh api`
- `nwsAlerts` change -> publish images -> `sh ./scripts/deploy_nws_from_git.sh nwsalerts`
- Cross-service changes -> publish images -> `sh ./scripts/deploy_nws_from_git.sh full`

Example runtime check used for SPC narrative validation:

```bash
curl -s http://192.168.6.87:3000/nws-alerts/admin/email-templates/preview \
	-X POST -H "Content-Type: application/json" -d '{}' > /tmp/preview.json
grep -q "SPC Narrative" /tmp/preview.json && echo "SPC Narrative found: Yes" || echo "SPC Narrative found: No"
```

Example runtime check for client deployments:

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 \
	'sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep weather-llm-client'
```

### `.env` for prebuilt-image mode

Set these in `/home/pi/development/weather-stack/weather-llm-iac/.env` on `nws` to enable registry-backed deploys:

```bash
PREFER_PREBUILT_IMAGES=true
LOCAL_REGISTRY_HOST=192.168.6.87
LOCAL_REGISTRY_PORT=5000
WEATHER_LLM_API_IMAGE=192.168.6.87:5000/weather-llm-api:latest
WEATHER_LLM_CLIENT_IMAGE=192.168.6.87:5000/weather-llm-client:latest
WEATHER_LLM_NWSALERTS_IMAGE=192.168.6.87:5000/weather-llm-nwsalerts:latest
```

The same wrapper still supports targeted `api`, `client`, and `nwsalerts` deploys. In prebuilt-image mode it starts the local registry first when the configured image refs point at `nws`.

One-time GitHub key copy from the Mac to `nws`:

```bash
scp ~/.ssh/github ~/.ssh/github.pub pi@192.168.6.87:/home/pi/.ssh/
ssh pi@192.168.6.87 '
set -eu
cp ~/.ssh/github ~/.ssh/id_github
cp ~/.ssh/github.pub ~/.ssh/id_github.pub
chmod 600 ~/.ssh/id_github
chmod 644 ~/.ssh/id_github.pub
ssh -i ~/.ssh/id_github -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com </dev/null || test $? -eq 1
'
```

One-time migration from plain directories to Git checkouts on `nws`:

```bash
ssh pi@192.168.6.87 '
set -eu
mkdir -p /home/pi/development/weather-stack
cd /home/pi/development/weather-stack
timestamp=$(date +%Y%m%d%H%M%S)
for dir in weather-llm-iac nwsAlerts weather-llm-api weather-llm; do
	if [ -e "$dir" ] && [ ! -d "$dir/.git" ]; then
		mv "$dir" "${dir}.pre-git-${timestamp}"
	fi
done
if [ ! -d weather-llm-iac/.git ]; then
	git clone git@github.com:bvassmer/weather-llm-iac.git weather-llm-iac
fi
cd weather-llm-iac
sh ./scripts/deploy_nws_from_git.sh full
'
```

The deploy script expects clean Git checkouts on `main`, clones missing sibling repos, and aborts if it finds a dirty checkout or a plain directory that still needs to be migrated.

Targeted Git-based deploys on `nws`:

```bash
ssh pi@192.168.6.87 '
set -eu
cd /home/pi/development/weather-stack/weather-llm-iac
sh ./scripts/deploy_nws_from_git.sh api
'
```

```bash
ssh pi@192.168.6.87 '
set -eu
cd /home/pi/development/weather-stack/weather-llm-iac
sh ./scripts/deploy_nws_from_git.sh client
'
```

```bash
ssh pi@192.168.6.87 '
set -eu
cd /home/pi/development/weather-stack/weather-llm-iac
sh ./scripts/deploy_nws_from_git.sh nwsalerts
'
```

Break-glass direct compose rebuild if the Git checkout is already current on the Pi:

```bash
cd /home/pi/development/weather-stack/weather-llm-iac
sudo docker-compose up -d --build --no-deps --force-recreate nwsalerts
```

Stop the stack:

```bash
docker compose down
```

Remove persistent volumes too:

```bash
docker compose down -v
```

Operational notes:

- `nwsalerts` is the component that polls weather sources and sends alert emails.
- `weather-llm-api` is the component that creates weather embeddings and writes them to Qdrant.
- `weather-llm` is only the user interface; all retrieval and answer generation happen behind it.
- If you change the embedding model, update `QDRANT_VECTOR_SIZE` to match the new model output dimension before writing more vectors.
- The local-registry path is intentionally LAN-local and insecure by default. If you need cross-network or untrusted-network access, switch to TLS before exposing it more broadly.
