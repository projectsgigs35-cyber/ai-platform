# AI Platform — Ollama Edition

A full-stack, multi-agent AI platform that runs **100% locally and free** using [Ollama](https://ollama.com) — no API keys, no per-token costs, no internet dependency once models are downloaded.

It replicates the architecture of production AI systems (like OpenAI's Assistants API or Anthropic's tool-use pipeline) using six distinct layers: **Hooks → Router → Agents → RAG → MCP → Plugins**.

---

## Table of Contents

- [What This Project Does](#what-this-project-does)
- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Running the Project](#running-the-project)
- [How Each Layer Works](#how-each-layer-works)
- [Using the UI](#using-the-ui)
- [Changing the Ollama Model](#changing-the-ollama-model)
- [API Reference](#api-reference)
- [Troubleshooting](#troubleshooting)
- [Extending the Platform](#extending-the-platform)

---

## What This Project Does

This is a chat-based AI platform with three specialized agents (Research, Coding, Data) that:

- Routes every message to the right agent automatically, based on keyword/intent detection
- Retrieves relevant context from uploaded documents (RAG) before answering
- Can call tools — calculator, code execution, weather, web search, file system, database — via a plugin/MCP system
- Runs entirely on your machine through Ollama, so there's no OpenAI/Anthropic API bill
- Has a polished dark-themed React UI with five tabs: Chat, Agents, Knowledge Base, Plugins, and Architecture (a live visual explainer of the system itself)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1 — React Frontend (WebSocket / Ollama HTTP)      │
└────────────────────────┬──────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Layer 2 — Hooks (Pre-hook → Router → Post-hook)          │
│  Rate limiting, content filtering, intent classification │
└────────────────────────┬──────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Layer 3 — Agents (Orchestrator + specialized agents)     │
│  Research Agent · Coding Agent · Data Agent · Custom      │
└──────┬──────────────────┬──────────────────┬──────────────┘
       ▼                  ▼                  ▼
┌─────────────┐   ┌─────────────────┐  ┌──────────────┐
│ Layer 4 RAG │   │ Layer 5 — MCP    │  │ Layer 6       │
│ ChromaDB    │   │ FileSystem,Web,  │  │ Plugins       │
│ vector store│   │ Database, Custom │  │ calc, weather │
└─────────────┘   └─────────────────┘  └──────────────┘
                         ▼
                ┌──────────────────┐
                │  Ollama (local)   │
                │  phi3 / llama3.1  │
                └──────────────────┘
```

Every user message flows top to bottom; the response (and any tool calls made along the way) flows back up and streams into the chat UI in real time.

---

## Project Structure

```
ai-platform/
├── .env                          # Ollama URL + model config
├── .gitignore
├── backend/
│   ├── main.py                   # FastAPI app, WebSocket endpoint, REST routes
│   ├── orchestrator.py           # Talks to Ollama, manages agent loop + tool calls
│   ├── agent_config.py           # Defines research/coding/data agents
│   ├── hooks.py                  # PreHook (rate limit/filter), Router, PostHook
│   ├── rag_engine.py             # Document chunking, embedding, ChromaDB queries
│   ├── mcp_manager.py            # FileSystem / Web / Database / CustomAPI tool servers
│   ├── plugin_registry.py        # Calculator, weather, code_exec, summarizer plugins
│   └── requirements.txt
└── frontend/
    ├── package.json
    ├── public/
    │   └── index.html
    └── src/
        ├── index.js
        └── App.jsx                # Entire UI — chat, agents, RAG, plugins, architecture tabs
```

---

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| **Python 3.10+** | Backend (FastAPI) | `sudo apt install python3 python3-pip` |
| **Node.js + npm** | Frontend (React) | `sudo apt install nodejs npm` |
| **Ollama** | Runs the LLM locally, free | `curl -fsSL https://ollama.com/install.sh \| sh` |

You'll also need at least one Ollama model pulled. Recommended for low-spec machines:
```bash
ollama pull phi3:mini      # ~2.2GB, fast, good for CPU-only machines
```
Or for better quality (needs more RAM/CPU, or a GPU):
```bash
ollama pull llama3.1       # ~4.9GB, supports tool-calling natively
```

---

## Installation

```bash
# 1. Clone your repo (after you've pushed it to GitHub)
git clone https://github.com/YOUR_USERNAME/REPO_NAME.git
cd REPO_NAME

# 2. Backend dependencies
cd backend
pip3 install -r requirements.txt --break-system-packages
cd ..

# 3. Frontend dependencies
cd frontend
npm install --legacy-peer-deps
cd ..
```

---

## Running the Project

You need **three things running simultaneously**: Ollama, the backend, and the frontend.

### Terminal 1 — Ollama
```bash
ollama serve
```
(Often already running as a system service after install — check with `systemctl status ollama`.)

### Terminal 2 — Backend
```bash
cd ai-platform/backend
uvicorn main:app --reload --port 8000
```
Backend will be live at `http://localhost:8000`. Check it's healthy:
```bash
curl http://localhost:8000/health
```

### Terminal 3 — Frontend
```bash
cd ai-platform/frontend
npm start
```
This opens `http://localhost:3000` automatically in your browser.

---

## How Each Layer Works

### Layer 2 — Hooks (`hooks.py`)
- **PreHook**: rate-limits each session to 20 requests/minute, blocks messages matching jailbreak patterns (`ignore.*instructions`, `jailbreak`, `DAN mode`), and logs every request with a hash.
- **RequestRouter**: scores the message against regex patterns for `code`, `data`, `search`, `rag` intents, then maps the winning intent to an agent (`coding_agent`, `data_agent`, `research_agent`).
- **PostHook**: records response length and estimated token count for auditing.

### Layer 3 — Agents (`orchestrator.py`, `agent_config.py`)
Each agent is just a system prompt + a list of allowed tools:

| Agent | Purpose | Default temperature |
|---|---|---|
| `research_agent` | Web search + document Q&A, cites sources | 0.3 |
| `coding_agent` | Writes/explains/debugs code | 0.2 |
| `data_agent` | Analyzes data, flags patterns | 0.2 |

The **Orchestrator** builds the conversation, sends it to Ollama's `/api/chat` endpoint with streaming enabled, and if Ollama responds with a tool call, the orchestrator executes that tool and feeds the result back into the conversation before generating the final answer.

### Layer 4 — RAG (`rag_engine.py`)
1. Uploaded text is split into 400-character chunks with 80-character overlap
2. Each chunk gets a (toy) hash-based embedding vector
3. Vectors are stored in **ChromaDB** (falls back to an in-memory cosine-similarity store if ChromaDB isn't installed)
4. On every query, the question is embedded the same way and the top-k most similar chunks are retrieved and prepended to the agent's system prompt as context

> Note: the embedding function here is a simple hashing trick for demo purposes, not a real neural embedding model. For production-quality retrieval, swap `_embed()` in `rag_engine.py` for a real embedding model (e.g. `nomic-embed-text` via Ollama).

### Layer 5 — MCP (`mcp_manager.py`)
Model Context Protocol servers expose tools an agent can call:
- **FileSystemMCP** — `read_file`, `write_file`, `list_directory` (sandboxed to a temp directory)
- **WebSearchMCP** — `web_search` (returns mock results; plug in a real API key for live search)
- **DatabaseMCP** — `query_db` (SELECT-only, SQL-injection-safe), `describe_db`
- **CustomAPIMCP** — `call_api` for any REST endpoint you register

### Layer 6 — Plugins (`plugin_registry.py`)
In-process Python functions agents can call directly:
- `calculator` — safely evaluates math via AST parsing (never raw `eval()`)
- `code_exec` — runs Python in a restricted sandbox
- `weather` — returns mock weather data (swap in an OpenWeatherMap key for real data)
- `summarizer` — extractive text summarization

Anyone can register a new plugin at runtime via `POST /plugins/register`.

---

## Using the UI

| Tab | What it does |
|---|---|
| **Chat** | Main conversation. Right panel shows live pipeline events (hooks firing, routing decisions, tool calls) as they happen. |
| **Agents** | View built-in agents and create custom ones with your own system prompt, temperature, and persona. |
| **Knowledge** | Upload `.txt`/`.md`/`.json` files or paste raw text to build a RAG knowledge base the agents will search before answering. |
| **Plugins** | View registered tools and register new custom ones. |
| **Architecture** | Interactive breakdown of all 6 layers with code excerpts — useful for understanding or demoing the system. |

---

## Changing the Ollama Model

Edit `.env` in the project root:
```env
OLLAMA_MODEL=llama3.1
```

And update the frontend default in `frontend/src/App.jsx`:
```js
const model = window.OLLAMA_MODEL || "llama3.1";
```

Other good free models to try:
```bash
ollama pull mistral          # fast, general-purpose 7B
ollama pull codellama         # best for the coding_agent
ollama pull mistral-nemo      # supports tool-calling
ollama pull phi3:mini         # tiny, good for low-spec/CPU-only machines
```

> **Tool-calling note**: only models that natively support function/tool calling (e.g. `llama3.1`, `mistral-nemo`) will trigger the calculator/weather/code_exec plugins automatically. Models like `phi3:mini` or `llama3` will still answer normally but won't invoke tools.

---

## API Reference

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Health check, lists active layers |
| `GET` | `/agents` | List all agents |
| `POST` | `/agents/configure` | Create/update an agent |
| `GET` | `/plugins` | List all plugins |
| `POST` | `/plugins/register` | Register a new plugin |
| `POST` | `/rag/ingest` | Upload a document (multipart file) into the knowledge base |
| `GET` | `/rag/documents` | List ingested documents |
| `WS` | `/ws` | Main chat WebSocket — send `{"text": "..."}`, receive streamed events |

---

## Troubleshooting

**`ModuleNotFoundError: No module named 'fastapi'`**
```bash
pip3 install -r backend/requirements.txt --break-system-packages
```

**`Cannot find module 'ajv/dist/compile/codegen'`** (frontend)
```bash
cd frontend
rm -rf node_modules package-lock.json
npm install --legacy-peer-deps
```

**`Error: max retries exceeded ... dial tcp: lookup ... no such host`** (Ollama pull fails)
This is a DNS/network issue. Try:
```bash
sudo bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
ollama pull phi3:mini
```
Or just pull a smaller model — `phi3:mini` downloads from different infrastructure and often succeeds even when `llama3.1` fails.

**Frontend shows "Could not reach Ollama"**
Check Ollama is running:
```bash
curl http://localhost:11434
sudo systemctl status ollama
sudo systemctl start ollama   # if inactive
```

**`uvicorn: command not found`**
```bash
sudo apt install uvicorn
# or
pip3 install uvicorn --break-system-packages
```

---

## Extending the Platform

- **Add a new agent**: add an entry to `DEFAULT_AGENTS` in `agent_config.py`, or create one live via the Agents tab in the UI.
- **Add a new plugin**: write a function in `plugin_registry.py` following the `calculator_plugin` pattern, then add it to `BUILTIN_PLUGINS`.
- **Add a real web search**: replace the mock results in `WebSearchMCP.call()` in `mcp_manager.py` with a real API call (Brave Search, Tavily, SerpAPI, etc.)
- **Use real embeddings**: swap the hash-based `_embed()` function in `rag_engine.py` for a call to Ollama's embedding endpoint (`nomic-embed-text` model) for genuinely accurate retrieval.
- **Persist conversation history**: currently history lives in memory per WebSocket session; wire it to the `conversations` SQLite table already scaffolded in `mcp_manager.py`'s `DatabaseMCP`.

---

## License

Use this however you like — it's your project to build on.
