#!/usr/bin/env bash
# infra-down.sh — tear down local Docker infra (default) or GCP cloud resources
# Local:  ./scripts/infra-down.sh
# Cloud:  ./scripts/infra-down.sh --cloud
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"

if [[ "${1:-}" == "--cloud" ]]; then
  [[ -f "$ENV_FILE" ]] || { printf '.env.gcp not found — nothing to tear down.\n'; exit 0; }
  source "$ENV_FILE"
  printf 'Tearing down GCP resources for project %s...\n' "$GCP_PROJECT"

  gcloud run services delete rag-frontend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
  gcloud run services delete rag-backend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true

  if [[ -n "${DB_INSTANCE:-}" ]]; then
    printf 'Deleting Cloud SQL instance %s...\n' "$DB_INSTANCE"
    gcloud sql instances delete "$DB_INSTANCE" \
      --project="$GCP_PROJECT" --quiet 2>/dev/null || true
  fi

  rm -f "$ENV_FILE"
  printf 'Cloud infrastructure torn down.\n'
else
  docker compose -f "$ROOT/docker-compose.yml" down -v
  printf 'Local infrastructure torn down.\n'
fi
