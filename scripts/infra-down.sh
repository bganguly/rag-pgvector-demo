#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEPLOY_WORKSPACE="lite"
TF_VAR_name_prefix="rag-lite"
INFRA_DIR="$ROOT/infra/aws"

TARGET=""
_BEFORE=""
_last_destroyed=()

# ── Helpers ───────────────────────────────────────────────────────────────────

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

_group_stats() {
  local init_file="${1:-}"
  local state_file="$INFRA_DIR/terraform.tfstate.d/$DEPLOY_WORKSPACE/terraform.tfstate"
  python3 - "$state_file" "$init_file" <<'PYEOF'
import json, sys
state_path = sys.argv[1]
init_path  = sys.argv[2] if len(sys.argv) > 2 else ''
GROUPS = [
  ('db',    ['aws_db_instance','aws_db_subnet_group']),
  ('sg',    ['aws_security_group']),
  ('ecs',   ['aws_ecs_cluster','aws_ecs_service','aws_ecs_task_definition']),
  ('cf',    ['aws_cloudfront_distribution']),
  ('ecr',   ['aws_ecr_repository','aws_ecr_lifecycle_policy']),
  ('alb',   ['aws_lb','aws_lb_listener','aws_lb_target_group']),
  ('vpc',   ['aws_vpc','aws_subnet','aws_internet_gateway','aws_route_table','aws_route_table_association']),
  ('iam',   ['aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment']),
  ('cb',    ['aws_codebuild_project']),
  ('s3',    ['aws_s3_bucket','aws_s3_bucket_lifecycle_configuration']),
  ('logs',  ['aws_cloudwatch_log_group']),
]
try:
  d = json.load(open(state_path))
except Exception:
  print('0|'); sys.exit()
counts = {}
total  = 0
for r in d.get('resources', []):
  n = len(r.get('instances', []))
  if n: counts[r['type']] = counts.get(r['type'], 0) + n; total += n
init = {}
if init_path:
  try:
    for line in open(init_path):
      if ':' in line: k, v = line.strip().split(':', 1); init[k] = int(v)
  except Exception: pass
parts = []
for label, types in GROUPS:
  cur = sum(counts.get(t, 0) for t in types)
  ini = init.get(label, cur)
  if ini > 0: parts.append(f'{label}:{cur}/{ini}')
print(f'{total}|' + '  '.join(parts))
PYEOF
}

_print_progress() {
  local elapsed="$1" frame="$2" log_file="$3" init_file="$4"
  local raw groups total completed line
  raw=$(_group_stats "$init_file")
  total="${raw%%|*}"
  groups="${raw#*|}"
  completed=$(grep -E ': Destruction complete' "$log_file" 2>/dev/null \
    | grep -oE '^[^:]+' | sed 's/^[[:space:]]*//' | sort -u || true)
  if [[ -n "$completed" ]]; then
    while IFS= read -r line; do
      if [[ -n "$line" ]] && ! printf '%s\n' "${_last_destroyed[@]:-}" | grep -qxF "$line"; then
        _last_destroyed+=("$line")
        printf '\r\033[K  \033[32m✓\033[0m %s\n' "$line"
      fi
    done <<< "$completed"
  fi
  printf '\r\033[K  %s  [%3ds]  %s/%s remaining  —  %s' \
    "$frame" "$elapsed" "$total" "$_BEFORE" "$groups"
}

# ── Preflight / menu ──────────────────────────────────────────────────────────

_run_preflight() {
  printf '\n=== rag-pgvector-demo — tear down ===\n\n'
  printf '  [1] Local   — stop uvicorn + Next.js processes\n'
  printf '  [2] AWS     — destroy Lambda, ECR, CodeBuild, S3, VPC (workspace: lite)\n'
  printf '\nChoice [1/2]: '
  read -r _MODE
  case "$_MODE" in
    1) TARGET="local" ;;
    2) TARGET="aws" ;;
    *) red 'Invalid choice.'; exit 1 ;;
  esac
}

# ── Local teardown ────────────────────────────────────────────────────────────

_teardown_local() {
  bold 'Stopping local processes...'
  pkill -f "uvicorn app.main:app" 2>/dev/null && green '  uvicorn stopped' || dim '  uvicorn not running'
  pkill -f "next dev"             2>/dev/null && green '  Next.js stopped' || dim '  Next.js not running'
  green 'Done.'
}

# ── AWS teardown ──────────────────────────────────────────────────────────────

_teardown_aws() {
  bold "AWS teardown — workspace: $DEPLOY_WORKSPACE"

  if ! command -v terraform >/dev/null 2>&1; then
    red 'terraform not found in PATH — install from https://developer.hashicorp.com/terraform/install'
    exit 1
  fi
  if ! command -v aws >/dev/null 2>&1; then
    red 'aws CLI not found in PATH'; exit 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    red 'AWS credentials not configured — run: aws configure'; exit 1
  fi
  dim "  Credentials: $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)"

  bold '\nInitialising Terraform...'
  cd "$INFRA_DIR"
  if ! terraform init -upgrade -input=false; then
    red 'terraform init failed — check provider connectivity and .terraform.lock.hcl'; exit 1
  fi

  if ! terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null; then
    red "Workspace '$DEPLOY_WORKSPACE' not found — nothing to destroy."; exit 0
  fi

  local STATE_FILE="$INFRA_DIR/terraform.tfstate.d/$DEPLOY_WORKSPACE/terraform.tfstate"
  local INIT_FILE
  INIT_FILE="$(mktemp /tmp/tf-init-XXXXXX)"
  local _RAW
  _RAW=$(_group_stats "")
  _BEFORE="${_RAW%%|*}"

  python3 - "$STATE_FILE" "$INIT_FILE" <<'PYEOF'
import json, sys
state_path, out_path = sys.argv[1], sys.argv[2]
GROUPS = [
  ('db',    ['aws_db_instance','aws_db_subnet_group']),
  ('sg',    ['aws_security_group']),
  ('ecs',   ['aws_ecs_cluster','aws_ecs_service','aws_ecs_task_definition']),
  ('cf',    ['aws_cloudfront_distribution']),
  ('ecr',   ['aws_ecr_repository','aws_ecr_lifecycle_policy']),
  ('alb',   ['aws_lb','aws_lb_listener','aws_lb_target_group']),
  ('vpc',   ['aws_vpc','aws_subnet','aws_internet_gateway','aws_route_table','aws_route_table_association']),
  ('iam',   ['aws_iam_role','aws_iam_role_policy','aws_iam_role_policy_attachment']),
  ('cb',    ['aws_codebuild_project']),
  ('s3',    ['aws_s3_bucket','aws_s3_bucket_lifecycle_configuration']),
  ('logs',  ['aws_cloudwatch_log_group']),
]
try: d = json.load(open(state_path))
except: d = {}
counts = {}
for r in d.get('resources', []):
  n = len(r.get('instances', []))
  if n: counts[r['type']] = counts.get(r['type'], 0) + n
with open(out_path, 'w') as f:
  for label, types in GROUPS:
    c = sum(counts.get(t, 0) for t in types)
    if c > 0: f.write(f'{label}:{c}\n')
PYEOF

  if [[ "$_BEFORE" == "0" ]]; then
    green 'Workspace is already empty — nothing to destroy.'
    rm -f "$INIT_FILE"; return
  fi

  printf '\n  Resources currently in state: %s\n' "$_BEFORE"
  printf '  This will destroy: ECS, ALB, RDS, CloudFront, VPC, ECR, CodeBuild, S3\n'
  printf '\n  Proceed? [Y/n]: '
  read -r _CONFIRM
  [[ "${_CONFIRM:-y}" =~ ^[Yy]$ ]] || { red 'Aborted.'; rm -f "$INIT_FILE"; exit 1; }

  bold '\nFlushing ECR images...'
  for _repo in "${TF_VAR_name_prefix}-backend" "${TF_VAR_name_prefix}-frontend"; do
    local _ids
    _ids=$(aws ecr list-images --repository-name "$_repo" \
      --query 'imageIds[*]' --output json --no-cli-pager 2>/dev/null || echo '[]')
    if [[ "$_ids" != "[]" && "$_ids" != "" ]]; then
      aws ecr batch-delete-image --repository-name "$_repo" \
        --image-ids "$_ids" --no-cli-pager >/dev/null 2>&1 \
        && green "  $_repo — images deleted" || dim "  $_repo — delete skipped"
    else
      dim "  $_repo — already empty"
    fi
  done

  bold '\nRunning terraform destroy...'
  local LOG_FILE
  LOG_FILE="$(mktemp /tmp/tf-destroy-XXXXXX)"
  terraform destroy -auto-approve -var "name_prefix=${TF_VAR_name_prefix}" \
    >"$LOG_FILE" 2>&1 &
  local TF_PID=$!

  local _spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local _si=0 _elapsed=0

  while kill -0 "$TF_PID" 2>/dev/null; do
    local _frame="${_spinner_frames[$(( _si % ${#_spinner_frames[@]} ))]}"
    _print_progress "$_elapsed" "$_frame" "$LOG_FILE" "$INIT_FILE"
    _si=$(( _si + 1 ))
    _elapsed=$(( _elapsed + 3 ))
    sleep 3
  done

  local _TF_EXIT=0
  wait "$TF_PID" || _TF_EXIT=$?
  printf '\n'
  rm -f "$INIT_FILE"

  if [[ "$_TF_EXIT" -ne 0 ]]; then
    red 'terraform destroy failed. Last 30 lines of output:'
    tail -30 "$LOG_FILE"
    red "\nFull log: $LOG_FILE"
    exit 1
  fi

  local _AFTER_RAW _AFTER
  _AFTER_RAW=$(_group_stats "")
  _AFTER="${_AFTER_RAW%%|*}"
  if [[ "$_AFTER" -gt 0 ]]; then
    red "Destroy completed but $_AFTER resources still in state — check AWS console."
    red "Log: $LOG_FILE"
    exit 1
  fi
  rm -f "$LOG_FILE"
  green "  All resources destroyed (was $_BEFORE, now 0)."

  bold '\nRemoving SSM parameters...'
  for _param in database-url openai-key anthropic-key nvidia-key; do
    aws ssm delete-parameter \
      --name "/${TF_VAR_name_prefix}/${_param}" \
      --no-cli-pager 2>/dev/null \
      && green "  deleted /${TF_VAR_name_prefix}/${_param}" \
      || dim  "  /${TF_VAR_name_prefix}/${_param} not found"
  done

  if command -v vercel >/dev/null 2>&1; then
    bold '\nRemoving Vercel project...'
    vercel remove rag-pgvector-demo --yes 2>/dev/null \
      && green '  Vercel project removed' \
      || dim  '  Vercel project not found or already removed'
  fi

  local PORTFOLIO_SET_LIVE
  PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
  if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
    bash "$PORTFOLIO_SET_LIVE" --tier "$DEPLOY_WORKSPACE" --down rag
  fi

  green '\nAWS infrastructure torn down.'
}

# ── Main ──────────────────────────────────────────────────────────────────────

_run_preflight
if [[ "$TARGET" == "local" ]]; then
  _teardown_local
else
  _teardown_aws
fi
