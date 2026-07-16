#!/usr/bin/env bash
# infra-down.sh — tear down local, GCP Cloud Run, or AWS Lambda resources
# Local:  ./scripts/infra-down.sh
# GCP:    ./scripts/infra-down.sh --cloud
# AWS:    ./scripts/infra-down.sh --aws [lite]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"

if [[ "${1:-}" == "--aws" ]]; then
  DEPLOY_WORKSPACE="${2:-lite}"
  TF_VAR_name_prefix="rag-${DEPLOY_WORKSPACE}"
  INFRA_DIR="$ROOT/infra/aws"

  printf 'Tearing down AWS resources for %s...\n' "$TF_VAR_name_prefix"
  cd "$INFRA_DIR"
  terraform init -upgrade -input=false >/dev/null
  terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null || { printf 'Workspace %s not found — nothing to destroy.\n' "$DEPLOY_WORKSPACE"; exit 0; }
  terraform destroy -auto-approve -var "name_prefix=${TF_VAR_name_prefix}"

  printf '\nRemoving SSM parameters...\n'
  for _param in database-url openai-key anthropic-key nvidia-key; do
    aws ssm delete-parameter --name "/${TF_VAR_name_prefix}/${_param}" --no-cli-pager 2>/dev/null && \
      printf '  deleted /%s/%s\n' "$TF_VAR_name_prefix" "$_param" || true
  done

  if command -v vercel >/dev/null 2>&1; then
    printf '\nRemoving Vercel project (rag-pgvector-demo)...\n'
    vercel remove rag-pgvector-demo --yes 2>/dev/null || printf '  (Vercel project not found or already removed)\n'
  fi

  PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
  if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
    bash "$PORTFOLIO_SET_LIVE" --tier "$DEPLOY_WORKSPACE" --down rag
  fi
  printf 'AWS infrastructure torn down.\n'

elif [[ "${1:-}" == "--cloud" ]]; then
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
  printf 'GCP infrastructure torn down.\n'

else
  printf 'Stopping local processes...\n'
  pkill -f "uvicorn app.main:app" 2>/dev/null || true
  pkill -f "next dev"             2>/dev/null || true
  printf 'Local processes stopped.\n'
fi
