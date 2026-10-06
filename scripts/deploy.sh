#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA_FILE="$ROOT/.last-deployed-sha"
INFRA_DIR="$ROOT/infra/aws"

TARGET=""
DEPLOY_WORKSPACE=""
TF_VAR_name_prefix=""
AWS_REGION=""
BE_ECR_URI=""
BE_REPO_NAME=""
DATABASE_URL=""
PGVECTOR_CONNECTION=""
OPENAI_API_KEY=""
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
TAG=""
BACKEND_URL=""
LAMBDA_NAME=""
FRONTEND_URL=""
_CURRENT_SHA=""
_SMART_DEFAULT=2

export TF_VAR_name_prefix

# ── Helpers ───────────────────────────────────────────────────────────────────

_aws_tf_ws_count() {
  local ws="$1"
  local state_file="$ROOT/infra/aws/terraform.tfstate.d/$ws/terraform.tfstate"
  [[ -f "$state_file" ]] || { printf '0'; return; }
  python3 -c "import json; d=json.load(open('$state_file')); print(sum(len(r.get('instances',[])) for r in d.get('resources',[])))" 2>/dev/null || printf '0'
}

_env_val()  { grep "^${1}=" "$ROOT/.env" 2>/dev/null | cut -d= -f2- || true; }
_env_mask() { local v="$1"; [[ -z "$v" ]] && echo "(not set)" || echo "${v:0:8}...${v: -4}"; }
_env_write() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ROOT/.env" 2>/dev/null; then
    sed -i '' "s|^${k}=.*|${k}=${v}|" "$ROOT/.env"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ROOT/.env"
  fi
}

_vercel_set_env() {
  local k="$1" v="$2"
  [[ -z "$v" ]] && return
  command -v vercel >/dev/null 2>&1 || return
  printf '%s' "$v" | vercel env add "$k" production --yes 2>/dev/null || \
  printf '%s' "$v" | vercel env add "$k" production --force 2>/dev/null || true
}

_tf() { terraform output -raw "$1" 2>/dev/null; }

_prompt_key() {
  local _label="$1" _cur="${2:-}" _req="${3:-optional}"
  local _ans _val
  if [[ -n "$_cur" ]]; then
    printf '  Use stored %s (%s...%s) (Y/n): ' "$_label" "${_cur:0:8}" "${_cur: -4}" >&2
    read -r _ans
    _ans="${_ans:-Y}"
    if [[ ! "$_ans" =~ ^[Yy] ]]; then
      printf '  New value: ' >&2; read -rs _val; printf '\n' >&2
      printf '%s' "${_val:-$_cur}"
    else
      printf '%s' "$_cur"
    fi
  else
    if [[ "$_req" == required ]]; then
      printf '  %-24s  (required): ' "$_label" >&2
    else
      printf '  %-24s  (optional, Enter to skip): ' "$_label" >&2
    fi
    read -rs _val; printf '\n' >&2
    if [[ -z "$_val" && "$_req" == required ]]; then
      printf '  Cannot deploy without %s.\n' "$_label" >&2; exit 1
    fi
    printf '%s' "$_val"
  fi
}

_ssm_update() {
  local _pname="$1" _new="$2" _old="$3"
  [[ -z "$_new" ]] && return
  [[ "$_new" == "$_old" ]] && return
  aws ssm put-parameter --name "$_pname" --value "$_new" \
    --type SecureString --overwrite --no-cli-pager >/dev/null
  printf '  Updated SSM: %s\n' "$_pname"
}

_ecr_image_exists() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=$2" \
    --region "$AWS_REGION" >/dev/null 2>&1
}

# ── No-change guard ───────────────────────────────────────────────────────────

_check_no_change_guard() {
  _CURRENT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
  local _LAST_SHA
  _LAST_SHA=$(cat "$SHA_FILE" 2>/dev/null || echo "")
  if [[ -n "$_LAST_SHA" && "$_CURRENT_SHA" == "$_LAST_SHA" ]]; then
    printf 'Already deployed: HEAD is %s (no new commits since last deploy).\n' "${_CURRENT_SHA:0:7}"
    printf 'Continue anyway to force a redeploy? [y/N]: '
    read -r _CONT
    [[ "${_CONT:-n}" =~ ^[Yy] ]] || { printf 'Exiting.\n'; exit 0; }
    printf '\n'
  fi
}

# ── Menu ──────────────────────────────────────────────────────────────────────

_prompt_menu() {
  local _aws_lite_count
  _aws_lite_count=$(_aws_tf_ws_count lite)

  local _LAST_SHA _BASE_SHA _changed_files _has_frontend=0 _has_backend=0
  _LAST_SHA=$(cat "$SHA_FILE" 2>/dev/null || echo "")
  _CURRENT_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
  _BASE_SHA="${_LAST_SHA:-}"
  if [[ -n "$_BASE_SHA" && "$_BASE_SHA" != "$_CURRENT_SHA" ]]; then
    _changed_files=$(git -C "$ROOT" diff "${_BASE_SHA}" HEAD --name-only 2>/dev/null)
  else
    _changed_files=$(git -C "$ROOT" diff HEAD~1 HEAD --name-only 2>/dev/null)
  fi
  while IFS= read -r _f; do
    [[ "$_f" == frontend/* ]] && _has_frontend=1
    [[ "$_f" == backend/* || "$_f" == infra/* ]] && _has_backend=1
  done <<< "$_changed_files"
  local _SMART_REASON
  if (( _has_frontend && ! _has_backend )); then
    _SMART_DEFAULT=4; _SMART_REASON="last commit touched only frontend/"
  else
    _SMART_DEFAULT=2; _SMART_REASON="last commit included backend/infra changes"
  fi

  printf '\n=== rag-pgvector-demo ===\n\n'
  printf '  [1] Local      — uvicorn + npm dev, no Docker (Postgres via .env)\n'
  printf '  [2] Serverless — AWS Lambda + Neon + Vercel  (~$0/mo)'
  (( _aws_lite_count > 0 )) && printf ' [%s resources active]' "$_aws_lite_count" || printf ' [not deployed]'
  printf '\n  [3] Smoke test — verify live endpoints (no deploy)\n'
  printf '  [4] Frontend   — redeploy Vercel frontend only (skip AWS/Lambda)\n'
  printf '\nSuggested default: [%s]  (%s)\n' "$_SMART_DEFAULT" "$_SMART_REASON"
  printf 'Choice [1/2/3/4, default=%s]: ' "$_SMART_DEFAULT"
  read -r _MODE
  _MODE="${_MODE:-$_SMART_DEFAULT}"
  case "$_MODE" in
    3) exec bash "$ROOT/scripts/smoke-test.sh" ;;
    4) TARGET="frontend-only" ;;
    2) TARGET="aws"; DEPLOY_WORKSPACE="lite"; TF_VAR_name_prefix="rag-lite"
       export DEPLOY_WORKSPACE TF_VAR_name_prefix
       ;;
    *) TARGET="local" ;;
  esac
}

# ── Local ─────────────────────────────────────────────────────────────────────

_deploy_local() {
  [[ -f "$ROOT/.env" ]] || { printf 'Error: .env not found. Copy .env.example and fill in API keys and DATABASE_URL.\n'; exit 1; }
  source "$ROOT/.env"
  if [[ -z "${DATABASE_URL:-}" ]]; then
    printf '\nDATABASE_URL not set in .env.\n'
    printf '  Neon: paste your Neon connection string (postgresql://...neon.tech/ragdb?sslmode=require)\n'
    printf '  Local brew: brew install postgresql@16 && brew services start postgresql@16\n'
    printf '              DATABASE_URL=postgresql://postgres:@localhost:5432/ragdb\n\n'
    exit 1
  fi

  cd "$ROOT/backend"
  [[ -d .venv ]] || python3 -m venv .venv
  source .venv/bin/activate
  pip install -q -r requirements.txt
  cp "$ROOT/.env" "$ROOT/backend/.env" 2>/dev/null || true
  uvicorn app.main:app --host 0.0.0.0 --port 8001 --reload &
  local BACKEND_PID=$!
  printf 'Backend  → http://localhost:8001\n'

  read -rp 'Seed Wikipedia articles into the local DB? [y/N]: ' _SEED
  if [[ "${_SEED:-n}" =~ ^[Yy] ]]; then
    sleep 3
    printf 'Seeding Wikipedia articles...\n'
    python3 "$ROOT/scripts/seed.py"
  fi

  cd "$ROOT/frontend"
  [[ -d node_modules ]] || npm install
  grep -E '^(OPENAI|ANTHROPIC|OPENROUTER|BACKEND)' "$ROOT/.env" > "$ROOT/frontend/.env.local" 2>/dev/null || true
  printf 'BACKEND_URL=http://localhost:8001\n' >> "$ROOT/frontend/.env.local"
  npm run dev &
  local FRONTEND_PID=$!
  printf 'Frontend → http://localhost:3010\n'

  trap 'kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true' EXIT INT TERM
  wait "$BACKEND_PID" "$FRONTEND_PID"
}

# ── Frontend-only ─────────────────────────────────────────────────────────────

_update_api_keys_for_frontend_only() {
  printf '\nAPI keys (Enter to skip each):\n'
  for _K in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    local _CUR
    _CUR=$(_env_val "$_K")
    printf '  %-24s  %s  — update? [y/N]: ' "$_K" "$(_env_mask "$_CUR")"
    read -r _ANS
    if [[ "${_ANS:-n}" =~ ^[Yy] ]]; then
      local _NEW
      printf '  New value: '; read -rs _NEW; printf '\n'
      if [[ -n "$_NEW" ]]; then
        _env_write "$_K" "$_NEW"
        _vercel_set_env "$_K" "$_NEW"
        printf '  %s updated (.env + Vercel)\n' "$_K"
      else
        printf '  (no change)\n'
      fi
    fi
  done
  printf '\n'
}

_deploy_frontend_only() {
  _update_api_keys_for_frontend_only

  if ! command -v vercel >/dev/null 2>&1; then
    printf '\n  Vercel CLI not found — installing...\n'
    npm install -g vercel
  fi
  [[ -d "$ROOT/frontend/node_modules" ]] || (cd "$ROOT/frontend" && npm install)
  cd "$ROOT"

  printf '\n  Setting Vercel environment variables from .env (if any changed)...\n'
  for _K in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    local _V
    _V=$(_env_val "$_K")
    [[ -n "$_V" ]] && _vercel_set_env "$_K" "$_V"
  done

  printf '  Deploying frontend to Vercel...\n'
  local _VERCEL_OUT
  _VERCEL_OUT=$(mktemp /tmp/vercel-out-XXXXXX)
  vercel --prod --yes 2>&1 | tee "$_VERCEL_OUT"
  local FRONTEND_URL4
  FRONTEND_URL4=$(grep -oE 'https://[a-zA-Z0-9._-]+\.vercel\.app' "$_VERCEL_OUT" | tail -1)
  rm -f "$_VERCEL_OUT"
  printf '%s' "$_CURRENT_SHA" > "$SHA_FILE"

  printf '\nRun smoke test? [Y/n]: '
  read -r _SMOKE4
  if [[ "${_SMOKE4:-Y}" =~ ^[Yy] ]]; then
    local _BE4
    _BE4=$(_env_val "BACKEND_URL")
    [[ "$_BE4" == *localhost* ]] && _BE4=""
    bash "$ROOT/scripts/smoke-test.sh" \
      ${_BE4:+--backend-url "$_BE4"} \
      ${FRONTEND_URL4:+--frontend-url "$FRONTEND_URL4"}
  fi
}

# ── AWS auth ──────────────────────────────────────────────────────────────────

_check_aws_auth() {
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    printf '  AWS credentials not configured.\n'
    aws configure
    aws sts get-caller-identity >/dev/null 2>&1 || { printf '  Credentials still invalid — aborting.\n'; exit 1; }
  fi
  printf '  Credentials valid: %s\n' "$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

  AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  local _GH_REPO
  _GH_REPO="$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; s|.*github\.com[:/]\(.*\)$|\1|')"
  if command -v gh >/dev/null 2>&1 && [[ -n "$_GH_REPO" ]]; then
    printf '  Syncing AWS credentials to GitHub Actions secrets (%s)...\n' "$_GH_REPO"
    aws configure get aws_access_key_id     | gh secret set AWS_ACCESS_KEY_ID     --repo "$_GH_REPO"
    aws configure get aws_secret_access_key | gh secret set AWS_SECRET_ACCESS_KEY --repo "$_GH_REPO"
    printf '%s' "$AWS_REGION"               | gh secret set AWS_REGION            --repo "$_GH_REPO"
  fi
}

# ── Terraform + ECR (phase 1) ─────────────────────────────────────────────────

_setup_terraform_and_ecr() {
  cd "$INFRA_DIR"
  terraform init -upgrade -input=false
  printf '  Selecting workspace and pruning stale state...\n'
  terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null \
    || terraform workspace new "$DEPLOY_WORKSPACE"

  terraform state rm aws_codebuild_project.backend                         2>/dev/null || true
  terraform state rm aws_iam_role_policy.codebuild                         2>/dev/null || true
  terraform state rm aws_iam_role.codebuild                                2>/dev/null || true
  terraform state rm aws_s3_bucket_lifecycle_configuration.build_artifacts 2>/dev/null || true

  local _STATE_FILE="$INFRA_DIR/terraform.tfstate.d/${DEPLOY_WORKSPACE}/terraform.tfstate"
  if [[ -f "$_STATE_FILE" ]]; then
    python3 - "$_STATE_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: s = json.load(f)
for k in ('codebuild_backend_project', 'build_bucket'):
    s.get('outputs', {}).pop(k, None)
with open(sys.argv[1], 'w') as f: json.dump(s, f, indent=2)
PYEOF
  fi

  terraform apply -auto-approve -var "name_prefix=${TF_VAR_name_prefix}" \
    -target=aws_ecr_repository.backend \
    -target=aws_ecr_lifecycle_policy.backend

  printf '  Reading Terraform outputs...\n'
  BE_ECR_URI=$(_tf backend_ecr_uri)
  AWS_REGION=$(_tf aws_region || aws configure get region 2>/dev/null || echo "us-east-1")
  BE_REPO_NAME="${TF_VAR_name_prefix}-backend"
}

# ── Neon DB ───────────────────────────────────────────────────────────────────

_setup_neon_db() {
  local _OLD_DB_URL
  _OLD_DB_URL=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/database-url" \
    --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
  if [[ -n "$_OLD_DB_URL" ]]; then
    printf '  Use stored DATABASE_URL (%s...) (Y/n): ' "${_OLD_DB_URL:0:40}"
    read -r _UPD_DB
    _UPD_DB="${_UPD_DB:-Y}"
    if [[ ! "$_UPD_DB" =~ ^[Yy] ]]; then _OLD_DB_URL=""; fi
  fi
  if [[ -z "$_OLD_DB_URL" ]]; then
    printf '  Paste your Neon DATABASE_URL (postgresql://...neon.tech/...?sslmode=require):\n  > '
    read -r DATABASE_URL
    [[ -z "$DATABASE_URL" ]] && { printf '  DATABASE_URL required — aborting.\n'; exit 1; }
    aws ssm put-parameter --name "/${TF_VAR_name_prefix}/database-url" \
      --value "$DATABASE_URL" --type SecureString --overwrite --no-cli-pager >/dev/null
  else
    DATABASE_URL="$_OLD_DB_URL"
  fi
  PGVECTOR_CONNECTION="${DATABASE_URL/postgresql:\/\//postgresql+psycopg://}"
}

# ── API keys ──────────────────────────────────────────────────────────────────

_collect_api_keys() {
  local _OLD_OPENAI _OLD_ANTHROPIC _OLD_OPENROUTER
  _OLD_OPENAI=$(aws ssm get-parameter     --name "/${TF_VAR_name_prefix}/openai-key"     --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
  _OLD_ANTHROPIC=$(aws ssm get-parameter  --name "/${TF_VAR_name_prefix}/anthropic-key"  --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
  _OLD_OPENROUTER=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/openrouter-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

  OPENAI_API_KEY=$(_prompt_key       "OPENAI_API_KEY"      "$_OLD_OPENAI"      required)
  ANTHROPIC_API_KEY=$(_prompt_key    "ANTHROPIC_API_KEY"   "$_OLD_ANTHROPIC"   optional)
  OPENROUTER_API_KEY=$(_prompt_key   "OPENROUTER_API_KEY"  "$_OLD_OPENROUTER"  optional)

  _ssm_update "/${TF_VAR_name_prefix}/openai-key"      "${OPENAI_API_KEY:-}"      "$_OLD_OPENAI"
  _ssm_update "/${TF_VAR_name_prefix}/anthropic-key"   "${ANTHROPIC_API_KEY:-}"   "$_OLD_ANTHROPIC"
  _ssm_update "/${TF_VAR_name_prefix}/openrouter-key"  "${OPENROUTER_API_KEY:-}"  "$_OLD_OPENROUTER"

  TAG=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)
}

# ── Wait for ECR image + finalize Terraform ───────────────────────────────────

_wait_for_ecr_and_apply() {
  printf '  Checking ECR for image %s...\n' "$TAG"
  if ! _ecr_image_exists "$BE_REPO_NAME" "$TAG"; then
    printf '  Image %s not in ECR yet — waiting for GitHub Actions build (up to 10 min)...\n' "$TAG"
    local _ecr_elapsed=0
    until _ecr_image_exists "$BE_REPO_NAME" "$TAG"; do
      if (( _ecr_elapsed >= 600 )); then
        printf '  Timed out waiting for %s. Check Actions: https://github.com/bganguly/rag-pgvector-demo/actions\n' "$TAG"
        exit 1
      fi
      sleep 15; _ecr_elapsed=$(( _ecr_elapsed + 15 ))
      printf '  ...%ds\n' "$_ecr_elapsed"
    done
  fi
  printf '  Backend image %s found in ECR.\n' "$TAG"

  local _MANIFEST
  _MANIFEST=$(aws ecr batch-get-image --repository-name "$BE_REPO_NAME" \
    --image-ids "imageTag=${TAG}" --query 'images[0].imageManifest' \
    --output text --no-cli-pager 2>/dev/null)
  aws ecr put-image --repository-name "$BE_REPO_NAME" --image-tag latest \
    --image-manifest "$_MANIFEST" --no-cli-pager >/dev/null 2>&1 \
    && printf '  Re-tagged %s as latest.\n' "$TAG" || true

  printf '  Finalising Lambda and remaining infra...\n'
  cd "$INFRA_DIR"
  terraform state rm aws_lambda_function_url.backend >/dev/null 2>&1 || true
  terraform state rm aws_lambda_permission.public_url >/dev/null 2>&1 || true
  terraform import aws_lambda_permission.apigw \
    "${TF_VAR_name_prefix}-backend/AllowAPIGatewayInvoke" >/dev/null 2>&1 || true
  terraform apply -auto-approve -var "name_prefix=${TF_VAR_name_prefix}"
  BACKEND_URL=$(_tf backend_url)
  LAMBDA_NAME=$(_tf lambda_function_name)
}

# ── Finalize Lambda ───────────────────────────────────────────────────────────

_finalize_lambda() {
  printf '  Waiting for Lambda to be ready...\n'
  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager

  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --image-uri "${BE_ECR_URI}:latest" \
    --no-cli-pager >/dev/null
  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager

  local _ENV_FILE
  _ENV_FILE="$(mktemp /tmp/lambda-env-XXXXXX)"
  python3 - "$DATABASE_URL" "$PGVECTOR_CONNECTION" "$OPENAI_API_KEY" \
    "${ANTHROPIC_API_KEY:-}" "${OPENROUTER_API_KEY:-}" <<'PYEOF' > "$_ENV_FILE"
import json, sys
keys = ['DATABASE_URL','PGVECTOR_CONNECTION','OPENAI_API_KEY','ANTHROPIC_API_KEY','OPENROUTER_API_KEY','CORS_ORIGINS']
vals = list(sys.argv[1:]) + ['*']
env = {k: v for k, v in zip(keys, vals) if v}
print(json.dumps({'Variables': env}))
PYEOF

  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --environment "file://${_ENV_FILE}" \
    --no-cli-pager >/dev/null
  rm -f "$_ENV_FILE"
  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --no-cli-pager
  printf '  Lambda active.\n'
  printf '  Backend: %s\n' "$BACKEND_URL"
}

# ── Deploy Vercel frontend ────────────────────────────────────────────────────

_deploy_vercel() {
  if ! command -v vercel >/dev/null 2>&1; then
    printf '\n  Vercel CLI not found — installing...\n'
    npm install -g vercel
  fi
  [[ -d "$ROOT/frontend/node_modules" ]] || (cd "$ROOT/frontend" && npm install)
  cd "$ROOT"

  printf '\n  Setting Vercel environment variables...\n'
  _vercel_set_env "BACKEND_URL"        "$BACKEND_URL"
  _vercel_set_env "OPENAI_API_KEY"     "${OPENAI_API_KEY:-}"
  _vercel_set_env "ANTHROPIC_API_KEY"  "${ANTHROPIC_API_KEY:-}"
  _vercel_set_env "OPENROUTER_API_KEY" "${OPENROUTER_API_KEY:-}"

  printf '  Deploying frontend to Vercel...\n'
  local _VERCEL_OUT
  _VERCEL_OUT=$(mktemp /tmp/vercel-out-XXXXXX)
  vercel --prod --yes 2>&1 | tee "$_VERCEL_OUT"
  FRONTEND_URL=$(grep -oE 'https://[a-zA-Z0-9._-]+\.vercel\.app' "$_VERCEL_OUT" | tail -1)
  if [[ -z "$FRONTEND_URL" ]]; then
    FRONTEND_URL=$(vercel ls --prod --limit 1 2>/dev/null | grep -oE 'https://[a-zA-Z0-9._-]+\.vercel\.app' | head -1)
  fi
  rm -f "$_VERCEL_OUT"

  sed -i '' "s|\[Live demo →\]([^)]*)|[Live demo →](${FRONTEND_URL})|" "$ROOT/README.md"
  git -C "$ROOT" add README.md
  git -C "$ROOT" commit -m "chore: update live demo URL after frontend redeploy" >/dev/null 2>&1 || true
  git -C "$ROOT" push >/dev/null 2>&1 || true
}

# ── Persist results ───────────────────────────────────────────────────────────

_persist_results() {
  printf '%s' "$_CURRENT_SHA" > "$SHA_FILE"

  printf '\nRAG + pgvector Demo live (serverless)\n'
  printf '  App:      %s\n' "$FRONTEND_URL"
  printf '  API:      %s\n' "$BACKEND_URL"
  printf '  Cost:     ~$0/mo  (Lambda + Neon + Vercel free tiers)\n'
  printf '  Tear down: ./scripts/infra-down.sh --aws\n'

  printf '\nRun smoke test? [Y/n]: '
  read -r _SMOKE
  if [[ "${_SMOKE:-Y}" =~ ^[Yy] ]]; then
    bash "$ROOT/scripts/smoke-test.sh" --backend-url "$BACKEND_URL" --frontend-url "$FRONTEND_URL"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

_check_no_change_guard
_prompt_menu

case "$TARGET" in
  local)
    _deploy_local
    ;;
  frontend-only)
    _deploy_frontend_only
    ;;
  aws)
    printf '\n--- AWS Serverless ---\n'
    printf '  Backend:  Lambda (container image, 1 GB, 15 min timeout)\n'
    printf '  Database: Neon serverless Postgres + pgvector  (~$0/mo free tier)\n'
    printf '  Frontend: Vercel                               (~$0/mo free tier)\n'
    printf '  Cost est: ~$0/mo  (Lambda free tier covers demo traffic)\n\n'
    printf '[1/5] Checking AWS credentials...\n'
    _check_aws_auth
    printf '\n[2/5] Provisioning bootstrap infra (ECR, IAM)...\n'
    _setup_terraform_and_ecr
    printf '\n[3/5] Neon database setup...\n'
    _setup_neon_db
    printf '\n[4/5] API keys...\n'
    _collect_api_keys
    printf '\n'
    _wait_for_ecr_and_apply
    printf '\n[5/5] Updating Lambda config and deploying frontend to Vercel...\n'
    _finalize_lambda
    _deploy_vercel
    _persist_results
    ;;
esac
