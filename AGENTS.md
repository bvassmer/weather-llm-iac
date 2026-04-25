# Weather Stack Agent Guide

## Topology

- `nws` (`pi@192.168.6.87`) is the weather stack host. Its Compose entrypoint is `/home/pi/development/weather-stack/weather-llm-iac`.
- `ai-hub` (`bvassmer@192.168.7.176`) is the AI host. Use `ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ai_hub bvassmer@192.168.7.176` and treat `/home/bvassmer/dev/rPiAiHub` as the live checkout.

## Application Components

- `weather-llm`: React and Vite browser client, served from `nws` on port `5173`.
- `weather-llm-api`: NestJS API and `api-worker`, served from `nws` on port `3000`. It owns answer generation, retrieval, embeddings, Postgres, and Qdrant integration.
- `nwsAlerts`: background weather ingestion service on `nws`. It writes normalized products to MariaDB and pushes embedding work toward `weather-llm-api`.
- `wx-modules`: shared packages used by ingestion, forecasting, and graphing code. Module changes are deployed through whichever app consumes them.
- `rPi-5-ai`: scripts and configs for the `ai-hub` appliance. It owns `hailo-ai-appliance.service`, nginx, and the Ollama-compatible endpoint on port `11434`.
- `weather-llm-iac`: authoritative two-Pi deployment repo and Docker Compose entrypoint for the `nws` host.

## Cross-Host Rules

- Keep browser and container URLs explicit. Use `http://192.168.6.87:3000` for `VITE_WEATHER_LLM_API_BASE_URL` and a routable IP such as `http://192.168.7.176:11434` for `OLLAMA_BASE_URL`.
- Do not rely on `.local` hostnames inside containers. Use a routable LAN IP or normal DNS name.
- The steady-state deploy method for both Pis is GitHub-first: push changes to GitHub, SSH to the live Git checkout on the target Pi, and run the repo-managed deploy wrapper there.
- On `nws`, keep `/home/pi/development/weather-stack/weather-llm-iac`, `/home/pi/development/weather-stack/nwsAlerts`, `/home/pi/development/weather-stack/weather-llm-api`, and `/home/pi/development/weather-stack/weather-llm` as Git checkouts on `main`; do not deploy by syncing source files into plain directories.
- On `ai-hub`, keep `/home/bvassmer/dev/rPiAiHub` as a Git checkout on `main`; do not deploy by copying files into `/etc` or the repo checkout outside the wrapper flow unless you are doing break-glass recovery.
- On `nws`, use `sudo docker-compose ...`; plain `docker-compose` has hit Docker socket permission failures.
- On `nws`, the preferred prebuilt-image path is the local registry on `192.168.6.87:5000` (configurable via `.env`), managed by `weather-llm-iac`.
- `nwsalerts` targeted deploys are only safe when `nwsalerts-mariadb` is already healthy because startup runs `prisma db push`.
- `ai-hub` is not currently a Docker Compose deployment target. Keep it on the Git-plus-systemd wrapper flow even when `nws` uses the local image registry.

## Deployment Routing

- Changes in `weather-llm`, `weather-llm-api`, `nwsAlerts`, or `weather-llm-iac` deploy to `nws`.
- Changes in `rPi-5-ai` deploy to `ai-hub`.
- Changes in `wx-modules` are not deployed alone. Rebuild and redeploy the consumer repo on `nws` after updating the shared package.

## Image Rebuild Workflow

Use this when you have pushed code changes to GitHub and need to rebuild and redeploy all three service images.

**Step 1 — Push your changes to GitHub from the Mac first.**

**Step 2 — SSH to `nws` and rebuild all images (must use `sudo`):**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 '
set -e
export GITHUB_SSH_KEY_PATH=$HOME/.ssh/id_github
export GIT_SSH_COMMAND="ssh -i $GITHUB_SSH_KEY_PATH -o IdentitiesOnly=yes"
cd /home/pi/development/weather-stack/weather-llm-iac
git pull --ff-only origin main
for repo in nwsAlerts weather-llm-api weather-llm; do
  git -C /home/pi/development/weather-stack/$repo pull --ff-only origin main
done
sudo sh ./scripts/publish_images_to_registry.sh
'
```

`publish_images_to_registry.sh` builds `linux/arm64` images from the live Pi checkouts and pushes them to `192.168.6.87:5000`. It must be run with `sudo` on `nws`; without `sudo` it will fail with a Docker socket permission error.

**Step 3 — Deploy the newly published images:**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 \
  'export GITHUB_SSH_KEY_PATH=$HOME/.ssh/id_github; cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh full'
```

**Step 4 — Verify live container health:**

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_weather_stack_pi pi@192.168.6.87 \
  'sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep weather-llm'
```

All four main containers (`weather-llm-nwsalerts`, `weather-llm-client`, `weather-llm-api`, `weather-llm-api-worker`) should show `(healthy)`.

## Stale Image Troubleshooting

- `deploy_nws_from_git.sh` updates Git checkouts and recreates services, but does not rebuild registry images.
- If a deploy succeeds but behavior is old, assume `:latest` in the local registry is stale.
- Resolve by running a fresh publish on `nws` after pulling latest checkouts:
  - `sudo sh /home/pi/development/weather-stack/weather-llm-iac/scripts/publish_images_to_registry.sh`
  - then `sh ./scripts/deploy_nws_from_git.sh <target>`
- Validate by endpoint behavior (for example, preview payload grep checks), not only by container health.

## Deploy Commands

- Git-based full `nws` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh full`
- Git-based `nws` registry deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh registry`
- Git-based UI deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh client`
- Git-based API deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh api`
- Git-based `nwsalerts` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh nwsalerts`
- Rebuild and push all images to local registry (must use `sudo`): `export GITHUB_SSH_KEY_PATH=$HOME/.ssh/id_github && sudo sh /home/pi/development/weather-stack/weather-llm-iac/scripts/publish_images_to_registry.sh`
- Git-based `ai-hub` full deploy: `cd /home/bvassmer/dev/rPiAiHub && sh ./scripts/deploy_ai_hub_from_git.sh full`
- Git-based `ai-hub` appliance deploy: `cd /home/bvassmer/dev/rPiAiHub && sh ./scripts/deploy_ai_hub_from_git.sh appliance`
- Git-based `ai-hub` nginx deploy: `cd /home/bvassmer/dev/rPiAiHub && sh ./scripts/deploy_ai_hub_from_git.sh nginx`
- Git-based `ai-hub` validation: `cd /home/bvassmer/dev/rPiAiHub && sh ./scripts/deploy_ai_hub_from_git.sh validate`
- Break-glass raw full `nws` stack: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up --build -d`
- Break-glass raw UI deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate client`
- Break-glass raw API deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate api api-worker`
- Break-glass raw `nwsalerts` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate nwsalerts`
- Break-glass `ai-hub` nginx apply: `sudo cp config/nginx/ai-appliance.conf /etc/nginx/sites-available/ai-appliance.conf && sudo nginx -t && sudo systemctl reload nginx`

## Validation

- `nws` UI: `curl -I http://192.168.6.87:5173`
- `nws` API: `curl http://192.168.6.87:3000/health`
- `nws` latest conversation bootstrap: `curl http://192.168.6.87:3000/nws-alerts/conversation/latest`
- `nws` live container health: `sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep weather-llm`
- `ai-hub` models: `curl http://127.0.0.1:11434/api/tags`
- `ai-hub` services: `systemctl is-active hailo-ai-appliance.service` and `systemctl is-active nginx`

## References

- See `README.md` in this repo for the full two-Pi topology and environment variables.
- See `../rPi-5-ai/README.md` for ai-hub setup details.
- See `../nwsAlerts/README.md` and `../weather-llm-api/README.md` for component-specific behavior.
