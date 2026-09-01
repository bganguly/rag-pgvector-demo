#!/usr/bin/env bash
# smoke-test.sh — verify deployed RAG pgvector demo endpoints
# Usage: ./scripts/smoke-test.sh [--backend-url URL] [--frontend-url URL]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKEND_URL=""
FRONTEND_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-url)  BACKEND_URL="$2";  shift 2 ;;
    --frontend-url) FRONTEND_URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Derive URLs from Terraform state if not provided
if [[ -z "$BACKEND_URL" || -z "$FRONTEND_URL" ]]; then
  _STATE="$ROOT/infra/aws/terraform.tfstate.d/lite/terraform.tfstate"
  if [[ -f "$_STATE" ]]; then
    _tf_out() {
      python3 -c "
import json, sys
with open('$_STATE') as f: d = json.load(f)
print(d.get('outputs', {}).get(sys.argv[1], {}).get('value', ''))
" "$1" 2>/dev/null
    }
    [[ -z "$BACKEND_URL"  ]] && BACKEND_URL=$(_tf_out backend_url)
    [[ -z "$FRONTEND_URL" ]] && FRONTEND_URL=$(_tf_out frontend_url)
  fi
fi

# Final fallback to known deployed values
BACKEND_URL="${BACKEND_URL:-https://9y3yanp443.execute-api.us-east-1.amazonaws.com}"
FRONTEND_URL="${FRONTEND_URL:-https://rag-pgvector-gangulybikramjit-4435s-projects.vercel.app}"

BACKEND_URL="${BACKEND_URL%/}"
FRONTEND_URL="${FRONTEND_URL%/}"

PASS=0; FAIL=0

_check() {
  local label="$1" status="$2" expect="$3" body="$4"
  if [[ "$status" == "$expect" ]] && { [[ -z "${5:-}" ]] || echo "$body" | grep -q "${5}"; }; then
    printf '  \033[32m✓\033[0m %s\n' "$label"
    PASS=$(( PASS + 1 ))
  else
    local _miss="${5:+ missing: ${5}}"
    printf '  \033[31m✗\033[0m %s  (HTTP %s%s)\n' "$label" "$status" "$_miss"
    FAIL=$(( FAIL + 1 ))
  fi
}

printf '\n=== smoke test: rag-pgvector-demo ===\n'
printf '  backend:  %s\n' "$BACKEND_URL"
printf '  frontend: %s\n\n' "$FRONTEND_URL"

# 1. Backend health
> /tmp/_st_body
_H=$(curl -s -o /tmp/_st_body -w '%{http_code}' --max-time 30 "${BACKEND_URL}/health" || echo "000"); _R="${_H:0:3}"
_check "GET /health → 200 {status:ok}" "$_R" "200" "$(cat /tmp/_st_body)" '"ok"'

# 2. Frontend app loads
_H=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${FRONTEND_URL}/" || echo "000"); _R="${_H:0:3}"
_check "GET / (frontend) → 200" "$_R" "200" ""

# 3. API explorer page loads
> /tmp/_st_body
_H=$(curl -s -o /tmp/_st_body -w '%{http_code}' --max-time 15 "${FRONTEND_URL}/api-explorer.html" || echo "000"); _R="${_H:0:3}"
_check "GET /api-explorer.html → 200" "$_R" "200" "$(cat /tmp/_st_body)" 'base-url-input'

# 4. POST /api/ingest — real Wikipedia article (Federal Reserve)
printf '  Fetching Wikipedia: Federal_Reserve...\n'
_WIKI_TEXT=$(curl -s --max-time 15 \
  "https://en.wikipedia.org/w/api.php?action=query&titles=Federal_Reserve&prop=extracts&explaintext=true&format=json&origin=*" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
pages = d.get('query', {}).get('pages', {})
print(list(pages.values())[0].get('extract', ''))
" 2>/dev/null)
if [[ -z "$_WIKI_TEXT" ]]; then
  printf '  \033[33m⚠\033[0m  Wikipedia fetch failed — skipping ingest/retrieve checks\n'
  FAIL=$(( FAIL + 1 ))
else
  > /tmp/_st_body
  _H=$(curl -s -o /tmp/_st_body -w '%{http_code}' --max-time 60 \
    -X POST "${BACKEND_URL}/api/ingest" \
    -F "text=${_WIKI_TEXT}" \
    -F "source=wikipedia/Federal_Reserve" || echo "000"); _R="${_H:0:3}"
  _CHUNKS=$(python3 -c "import json,sys; print(json.load(open('/tmp/_st_body')).get('chunks',0))" 2>/dev/null || echo 0)
  if [[ "$_R" == "200" && "$_CHUNKS" -gt 1 ]]; then
    printf '  \033[32m✓\033[0m POST /api/ingest → 200  (%s chunks)\n' "$_CHUNKS"
    PASS=$(( PASS + 1 ))
  else
    printf '  \033[31m✗\033[0m POST /api/ingest → HTTP %s  chunks=%s\n' "$_R" "$_CHUNKS"
    FAIL=$(( FAIL + 1 ))
  fi

  # 5. POST /api/retrieve — query against ingested Wikipedia content
  > /tmp/_st_body
  _H=$(curl -s -o /tmp/_st_body -w '%{http_code}' --max-time 30 \
    -X POST "${BACKEND_URL}/api/retrieve" \
    -H "Content-Type: application/json" \
    -d '{"query":"How does the Federal Reserve control inflation?","k":3}' || echo "000"); _R="${_H:0:3}"
  _RET_COUNT=$(python3 -c "import json,sys; print(len(json.load(open('/tmp/_st_body')).get('chunks',[])))" 2>/dev/null || echo 0)
  if [[ "$_R" == "200" && "$_RET_COUNT" -gt 0 ]]; then
    printf '  \033[32m✓\033[0m POST /api/retrieve → 200  (%s results)\n' "$_RET_COUNT"
    PASS=$(( PASS + 1 ))
  else
    printf '  \033[31m✗\033[0m POST /api/retrieve → HTTP %s  results=%s\n' "$_R" "$_RET_COUNT"
    FAIL=$(( FAIL + 1 ))
  fi
fi

rm -f /tmp/_st_body

printf '\n'
if (( FAIL == 0 )); then
  printf '\033[32m✓ All %d checks passed.\033[0m\n\n' "$PASS"
  exit 0
else
  printf '\033[31m✗ %d/%d checks failed.\033[0m\n\n' "$FAIL" "$(( PASS + FAIL ))"
  exit 1
fi
