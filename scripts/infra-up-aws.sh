#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra/aws"

cd "$INFRA_DIR"
terraform init -upgrade -input=false

terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null \
  || terraform workspace new "$DEPLOY_WORKSPACE"

terraform apply -auto-approve \
  -var "name_prefix=${TF_VAR_name_prefix}"
