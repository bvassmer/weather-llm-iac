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

This stack uses bind mounts and development-style startup commands (`npm install`, watch mode, live reload). It works well for a personal LAN deployment and active development, but it is not a hardened production packaging strategy.

## Key configuration

Copy the environment file first:

```bash
cp .env.example .env
```

Then update the values that define how the two Pis talk to each other.

| Variable                        | Recommended value for this deployment    | Why it matters                                                              |
| ------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------- |
| `OLLAMA_BASE_URL`               | `http://192.168.7.176:11434`             | Points API generation requests at `ai-hub`                                  |
| `OLLAMA_CHAT_BASE_URL`          | optional override                        | Use only if generation is exposed on a different URL than `OLLAMA_BASE_URL` |
| `OLLAMA_CHAT_MODEL`             | `qwen3:1.7b` or your validated model     | Controls the answer-generation model                                        |
| `VITE_WEATHER_LLM_API_BASE_URL` | `http://192.168.6.87:3000`               | Browser-side API base URL used by the UI                                    |
| `CORS_ORIGIN`                   | `http://192.168.6.87:5173`               | Allows the browser UI to call the API                                       |
| `NWS_EMBEDDING_MODEL`           | `Xenova/all-MiniLM-L6-v2`                | Local embedding model downloaded by `weather-llm-api`                       |
| `QDRANT_VECTOR_SIZE`            | `384`                                    | Must match the embedding model output dimension                             |
| `QDRANT_COLLECTION_NWS_ALERTS`  | `nws_alerts_embeddings_v1`               | Main collection for stored weather vectors                                  |
| `ALERT_EMAIL_ENABLED`           | `true` to send email, `false` to disable | Enables alert email delivery from `nwsalerts`                               |
| `ALERT_EMAIL_TO`                | `bvassmer@gmail.com`                     | Where important weather emails are delivered                                |

Notes:

- Use a routable IP address or standard DNS name for `OLLAMA_BASE_URL`. `.local` hostnames often resolve on the host but fail inside Docker containers.
- Keep `VITE_WEATHER_LLM_API_BASE_URL` explicit. Browser-side values are easiest to reason about when they match the real LAN address of `nws`.
- `weather-llm-api` generates embeddings in-process. Ollama on `ai-hub` is currently used for answer generation, not for weather document embeddings.
- On first boot, `weather-llm-api` downloads the embedding model into the shared cache mounted at `NWS_EMBEDDING_CACHE_DIR`. The cache is reused by both the API and worker containers.

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

ALERT_EMAIL_ENABLED=true
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
docker compose up --build -d
```

The Compose stack starts:

- MariaDB for `nwsalerts`
- PostgreSQL for `weather-llm-api`
- Qdrant
- the `nwsalerts` ingestion service
- the `weather-llm-api` API and worker
- the `weather-llm` UI

The `api` and `api-worker` startup commands already run `npm run prisma:generate` and `npm run prisma:migrate:deploy`, so checked-in PostgreSQL migrations are applied automatically when those containers are recreated.

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

Conversation persistence rollout from a Mac development checkout to `nws`:

```bash
cd /Users/benjaminvassmer/development/weather-llm-iac
rsync -av ../weather-llm-api/prisma/ pi@192.168.6.87:/home/pi/development/weather-stack/weather-llm-api/prisma/
rsync -av ../weather-llm-api/src/api/nws-answer/ pi@192.168.6.87:/home/pi/development/weather-stack/weather-llm-api/src/api/nws-answer/
rsync -av ../weather-llm/src/pages/PromptPage.tsx pi@192.168.6.87:/home/pi/development/weather-stack/weather-llm/src/pages/PromptPage.tsx
ssh pi@192.168.6.87 '
set -e
cd /home/pi/development/weather-stack/weather-llm-iac
sudo docker-compose up -d --no-deps --force-recreate api api-worker client
curl -f http://127.0.0.1:3000/health
curl -f http://127.0.0.1:3000/nws-alerts/conversation/latest
'
```

Client-only Prompt page rollout on `nws`:

```bash
cd /Users/benjaminvassmer/development/weather-llm-iac
rsync -av ../weather-llm/src/pages/PromptPage.tsx pi@192.168.6.87:/home/pi/development/weather-stack/weather-llm/src/pages/PromptPage.tsx
ssh pi@192.168.6.87 '
set -e
cd /home/pi/development/weather-stack/weather-llm-iac
sudo docker-compose restart client
'
```

Rebuild a single service after a code change:

```bash
docker compose up -d --build --no-deps --force-recreate nwsalerts
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
- Because this stack uses bind mounts and dev-mode commands, unexpected container startup issues are often solved by checking service logs first rather than assuming the code path changed.
