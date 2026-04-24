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
- On `nws`, keep `/home/pi/development/weather-stack/weather-llm-iac`, `/home/pi/development/weather-stack/nwsAlerts`, `/home/pi/development/weather-stack/weather-llm-api`, and `/home/pi/development/weather-stack/weather-llm` as Git checkouts on `main`; do not deploy by syncing source files into plain directories.
- On `nws`, use `sudo docker-compose ...`; plain `docker-compose` has hit Docker socket permission failures.
- `nwsalerts` targeted deploys are only safe when `nwsalerts-mariadb` is already healthy because startup runs `prisma db push`.

## Deployment Routing

- Changes in `weather-llm`, `weather-llm-api`, `nwsAlerts`, or `weather-llm-iac` deploy to `nws`.
- Changes in `rPi-5-ai` deploy to `ai-hub`.
- Changes in `wx-modules` are not deployed alone. Rebuild and redeploy the consumer repo on `nws` after updating the shared package.

## Deploy Commands

- Git-based full `nws` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh full`
- Git-based UI deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh client`
- Git-based API deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh api`
- Git-based `nwsalerts` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sh ./scripts/deploy_nws_from_git.sh nwsalerts`
- Break-glass raw full `nws` stack: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up --build -d`
- Break-glass raw UI deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate client`
- Break-glass raw API deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate api api-worker`
- Break-glass raw `nwsalerts` deploy: `cd /home/pi/development/weather-stack/weather-llm-iac && sudo docker-compose up -d --build --no-deps --force-recreate nwsalerts`
- `ai-hub` repo sync target: `/home/bvassmer/dev/rPiAiHub`
- `ai-hub` nginx apply: `sudo cp config/nginx/ai-appliance.conf /etc/nginx/sites-available/ai-appliance.conf && sudo nginx -t && sudo systemctl reload nginx`

## Validation

- `nws` UI: `curl -I http://192.168.6.87:5173`
- `nws` API: `curl http://192.168.6.87:3000/health`
- `nws` latest conversation bootstrap: `curl http://192.168.6.87:3000/nws-alerts/conversation/latest`
- `ai-hub` models: `curl http://127.0.0.1:11434/api/tags`
- `ai-hub` services: `systemctl is-active hailo-ai-appliance.service` and `systemctl is-active nginx`

## References

- See `README.md` in this repo for the full two-Pi topology and environment variables.
- See `../rPi-5-ai/README.md` for ai-hub setup details.
- See `../nwsAlerts/README.md` and `../weather-llm-api/README.md` for component-specific behavior.
