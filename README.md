# RAG + pgvector Demo — LangChain · Vercel AI SDK · NVIDIA NIM

End-to-end **RAG pipeline** over any unstructured corpus: LangChain chunking, OpenAI embeddings stored
in **pgvector**, cosine-similarity retrieval, and token-level SSE streaming via **Vercel AI SDK**.
Provider toggle switches between Anthropic, OpenAI, and **NVIDIA NIM (Nemotron)** at runtime — same
interface, configurable `base_url`.

Sister repo: [agent-orchestration-demo](https://github.com/bganguly/agent-orchestration-demo)

---

| | |
|---|---|
| **RAG pipeline** | LangChain `RecursiveCharacterTextSplitter` (800 chars / 150 overlap) → OpenAI `text-embedding-3-small` (1 536 dims) → pgvector cosine similarity |
| **Vector store** | PostgreSQL 16 + pgvector extension; `langchain-postgres` `PGVector` handles schema, IVFFlat index, and async upsert |
| **LLM streaming** | Next.js App Router API route calls FastAPI `/api/retrieve`, then pipes context into Vercel AI SDK `streamText`; tokens stream to the browser via the AI SDK data-stream protocol |
| **Provider toggle** | Anthropic `claude-3-5-haiku-20241022` (default) · OpenAI `gpt-4o-mini` · NVIDIA NIM `nvidia/llama-3.3-nemotron-super-49b-v1` — switched from the header without reloading |
| **Ingest API** | `POST /api/ingest` accepts `.txt` / `.md` file upload or raw pasted text; chunked and embedded in one call |
| **Session state** | Redis 7 (conversation history, rate-limit headroom) |
| **Backend** | FastAPI 0.115 + asyncio; `lifespan` hook initialises pgvector extension and LangChain collection on startup |
| **Frontend** | Next.js 15 App Router, React 19, TypeScript 5.7, Tailwind CSS; `useChat` from `ai/react` |
| **Infra** | Docker Compose: `pgvector/pgvector:pg16` on `:5433`, `redis:7-alpine` on `:6380` |
| **Seed data** | `scripts/seed.py` pulls six Wikipedia articles (Federal Reserve, Inflation, Interest rate, Quantitative easing, Monetary policy, GDP) via the Wikipedia REST API — no API key required |

---

## Architecture

```
Browser ──► Next.js :3010 ──► /api/retrieve ──► FastAPI :8001
              Vercel AI SDK                        LangChain pipeline
              streamText                           pgvector (postgres :5433)
              useChat hook                         OpenAI embeddings
                                                   Redis :6380

Ingest path:
  UI upload / paste ──► Next.js /api/ingest ──► FastAPI /api/ingest
                                                  LangChain splitter
                                                  OpenAI embed
                                                  pgvector upsert
```

---

## Local Dev

```bash
./scripts/local-dev.sh
```

Starts Docker Compose (postgres + redis), installs Python deps in a venv, starts FastAPI on `:8001`,
installs Node deps, starts Next.js on `:3010`.

```bash
./scripts/local-dev.sh --seed   # also pulls and ingests 6 Wikipedia articles on first run
```

Prerequisites checked at startup:
- **Docker** — for postgres + redis
- **Python 3.12+** — venv created automatically inside `backend/`
- **Node 20+** — `npm install` run automatically inside `frontend/`
- **`.env`** — created from `.env.example` on first run; fill in `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`

---

## Tear Down

```bash
./scripts/infra-down.sh   # stops and removes Docker volumes
```

---

## Deploy

```bash
./scripts/deploy.sh
```

Provisions on GCP (no local Docker required — images built via Cloud Build):

- **Artifact Registry** — Docker image repo
- **Cloud SQL PG16** — managed postgres with pgvector extension enabled on first boot
- **Cloud Run** — backend (FastAPI) and frontend (Next.js), each as independent services
- **Secret Manager** — stores DB password and API keys; injected at runtime

Prerequisites: `gcloud` CLI authenticated (`gcloud auth login`) and a project set
(`gcloud config set project <id>`). API keys are read from your local `.env` and pushed
to Secret Manager on first deploy.

```bash
./scripts/infra-down.sh          # stop local Docker
./scripts/infra-down.sh --cloud  # delete Cloud Run services + Cloud SQL instance
```

---

## Quick Test — Local

```bash
# Health
curl http://localhost:8001/health

# Ingest a snippet
curl -X POST http://localhost:8001/api/ingest \
  -F "text=The Federal Reserve sets interest rates to control inflation." \
  -F "source=test"

# Retrieve similar chunks
curl -X POST http://localhost:8001/api/retrieve \
  -H "Content-Type: application/json" \
  -d '{"query": "How does the Fed control inflation?", "k": 3}' | jq '.chunks[].score'

# Chat via Next.js (token stream — watch it arrive)
curl -X POST http://localhost:3010/api/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is the Fed?"}],"provider":"anthropic"}' \
  --no-buffer
```

---

## Live Services

| Service | Local |
|---|---|
| Next.js app | http://localhost:3010 |
| FastAPI docs | http://localhost:8001/docs |
