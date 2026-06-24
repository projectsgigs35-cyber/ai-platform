#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║          AI PLATFORM — Ollama Edition  (one-shot setup)         ║
# ╚══════════════════════════════════════════════════════════════════╝
# Paste this entire script into your Linux terminal and run it.
# It installs everything, writes every file, and starts the servers.

set -e
PLATFORM_DIR="$HOME/ai-platform"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        AI Platform Setup — Ollama Edition        ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── 1. System deps ────────────────────────────────────────────────
echo "▶ Checking system dependencies..."
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found. Install with: sudo apt install python3 python3-pip"; exit 1; }
command -v node    >/dev/null 2>&1 || { echo "ERROR: node not found. Install with: sudo apt install nodejs npm"; exit 1; }
command -v npm     >/dev/null 2>&1 || { echo "ERROR: npm not found.  Install with: sudo apt install npm"; exit 1; }

# ─── 2. Install Ollama if missing ──────────────────────────────────
if ! command -v ollama >/dev/null 2>&1; then
  echo "▶ Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "▶ Ollama already installed: $(ollama --version)"
fi

# Start ollama server in background if not running
if ! pgrep -x ollama >/dev/null 2>&1; then
  echo "▶ Starting Ollama server..."
  ollama serve &>/tmp/ollama.log &
  sleep 3
fi

# Pull the model
echo "▶ Pulling Ollama model: $OLLAMA_MODEL (this may take a few minutes on first run)..."
ollama pull "$OLLAMA_MODEL"

# ─── 3. Create project structure ───────────────────────────────────
echo "▶ Creating project structure at $PLATFORM_DIR..."
mkdir -p "$PLATFORM_DIR"/{backend,frontend/src/{components,hooks}}
cd "$PLATFORM_DIR"

# ─── 4. Write .env ─────────────────────────────────────────────────
cat > "$PLATFORM_DIR/.env" << 'ENVEOF'
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.1
ENVEOF

# ─── 5. Write backend/requirements.txt ─────────────────────────────
cat > "$PLATFORM_DIR/backend/requirements.txt" << 'EOF'
fastapi
uvicorn[standard]
httpx
chromadb
python-multipart
aiofiles
EOF

# ─── 6. Write backend/agent_config.py ──────────────────────────────
cat > "$PLATFORM_DIR/backend/agent_config.py" << 'PYEOF'
DEFAULT_AGENTS = {
    "research_agent": {
        "agent_id": "research_agent",
        "name": "Research Agent",
        "description": "Finds and synthesizes information from web and documents",
        "system_prompt": (
            "You are a meticulous Research Agent. Find accurate, up-to-date information. "
            "Always cite sources. Cross-reference multiple sources when possible. "
            "Distinguish between facts, analysis, and speculation."
        ),
        "allowed_tools": ["web_search", "read_file", "summarizer"],
        "temperature": 0.3,
        "max_tokens": 1024,
        "memory_mode": "session",
        "icon": "🔍",
    },
    "coding_agent": {
        "agent_id": "coding_agent",
        "name": "Coding Agent",
        "description": "Writes, explains, and debugs code",
        "system_prompt": (
            "You are an expert Software Engineer. Write clean, well-documented, "
            "production-ready code. Always include error handling. Explain your "
            "decisions. Prefer established patterns and libraries."
        ),
        "allowed_tools": ["code_exec", "calculator", "read_file", "write_file"],
        "temperature": 0.2,
        "max_tokens": 2048,
        "memory_mode": "session",
        "icon": "💻",
    },
    "data_agent": {
        "agent_id": "data_agent",
        "name": "Data Agent",
        "description": "Analyzes data and produces insights",
        "system_prompt": (
            "You are a Data Analyst. Analyze data carefully. Identify patterns, "
            "outliers, and trends. Present findings clearly with supporting numbers. "
            "Suggest appropriate visualizations. Flag data quality issues."
        ),
        "allowed_tools": ["calculator", "query_db", "summarizer", "code_exec"],
        "temperature": 0.2,
        "max_tokens": 1024,
        "memory_mode": "session",
        "icon": "📊",
    },
}


class AgentConfig:
    def __init__(self):
        self._agents = dict(DEFAULT_AGENTS)

    def configure(self, agent_id, config):
        if agent_id in self._agents:
            self._agents[agent_id].update(config)
        else:
            config["agent_id"] = agent_id
            self._agents[agent_id] = config

    def get(self, agent_id):
        return self._agents.get(agent_id)

    def delete(self, agent_id):
        if agent_id in DEFAULT_AGENTS:
            return False
        if agent_id in self._agents:
            del self._agents[agent_id]
            return True
        return False

    def list_agents(self):
        return [
            {
                "agent_id":    v["agent_id"],
                "name":        v["name"],
                "description": v.get("description", ""),
                "icon":        v.get("icon", "🤖"),
                "temperature": v.get("temperature", 0.7),
                "builtin":     v["agent_id"] in DEFAULT_AGENTS,
            }
            for v in self._agents.values()
        ]
PYEOF

# ─── 7. Write backend/hooks.py ─────────────────────────────────────
cat > "$PLATFORM_DIR/backend/hooks.py" << 'PYEOF'
import time, re, hashlib
from collections import defaultdict


class PreHook:
    def __init__(self):
        self._rate = defaultdict(list)
        self._log = []
        self._blocked_patterns = [
            r"ignore.*instructions",
            r"jailbreak",
            r"DAN mode",
        ]

    def run(self, text, session_id):
        now = time.time()
        calls = [t for t in self._rate[session_id] if now - t < 60]
        self._rate[session_id] = calls
        if len(calls) >= 20:
            return {"blocked": True, "reason": "Rate limit exceeded (20 req/min)"}
        self._rate[session_id].append(now)
        lower = text.lower()
        for pattern in self._blocked_patterns:
            if re.search(pattern, lower):
                return {"blocked": True, "reason": "Content policy violation"}
        entry = {
            "ts": now,
            "session": session_id,
            "hash": hashlib.md5(text.encode()).hexdigest()[:8],
            "len": len(text),
        }
        self._log.append(entry)
        return {"blocked": False, "rate_remaining": 20 - len(calls), "logged": True}

    def get_log(self):
        return self._log[-50:]


class RequestRouter:
    PATTERNS = {
        "code":   [r"\bcode\b", r"\bwrite\b.*\b(function|class|script)\b",
                   r"\bdebug\b", r"\bpython\b", r"\bjavascript\b", r"\bfix.*error\b"],
        "data":   [r"\banalyze\b", r"\bchart\b", r"\bgraph\b", r"\bcsv\b",
                   r"\bstatistic\b", r"\bsummariz\b"],
        "search": [r"\bsearch\b", r"\bfind\b", r"\bwhat is\b", r"\bwho is\b",
                   r"\blatest\b", r"\bnews\b", r"\bcurrent\b"],
        "rag":    [r"\bin.*document\b", r"\baccording to\b", r"\bmy.*file\b",
                   r"\buploaded\b"],
    }

    def route(self, text):
        lower = text.lower()
        scores = {}
        for intent, patterns in self.PATTERNS.items():
            scores[intent] = sum(1 for p in patterns if re.search(p, lower))
        best_intent = max(scores, key=scores.get) if max(scores.values()) > 0 else "general"
        agent_map = {
            "code": "coding_agent", "data": "data_agent",
            "search": "research_agent", "rag": "research_agent", "general": "research_agent",
        }
        return {"intent": best_intent, "agent": agent_map[best_intent], "scores": scores}


class PostHook:
    def __init__(self):
        self._audit = []

    def run(self, response, session_id):
        entry = {
            "ts": time.time(),
            "session": session_id,
            "resp_len": len(response),
            "tokens_est": len(response) // 4,
        }
        self._audit.append(entry)
        return entry

    def get_audit(self):
        return self._audit[-50:]
PYEOF

# ─── 8. Write backend/rag_engine.py ────────────────────────────────
cat > "$PLATFORM_DIR/backend/rag_engine.py" << 'PYEOF'
import re, math, uuid
from collections import Counter

try:
    import chromadb
    _USE_CHROMA = True
except ImportError:
    _USE_CHROMA = False


class InMemoryVectorStore:
    def __init__(self):
        self._docs = []

    def add(self, text, metadata, doc_id):
        self._docs.append({"id": doc_id, "text": text, "meta": metadata,
                            "vec": self._vectorize(text)})

    def query(self, text, k=3):
        qvec = self._vectorize(text)
        scored = [(self._cosine(qvec, d["vec"]), d) for d in self._docs]
        scored.sort(key=lambda x: x[0], reverse=True)
        return [{"text": d["text"], "source": d["meta"].get("filename", ""),
                 "score": round(s, 3)} for s, d in scored[:k] if s > 0]

    def count(self):
        return len(self._docs)

    def list_sources(self):
        return list({d["meta"].get("filename", "unknown") for d in self._docs})

    @staticmethod
    def _vectorize(text):
        words = re.findall(r"\w+", text.lower())
        counts = Counter(words)
        total = sum(counts.values()) or 1
        return {w: c / total for w, c in counts.items()}

    @staticmethod
    def _cosine(a, b):
        keys = set(a) & set(b)
        dot = sum(a[k] * b[k] for k in keys)
        na = math.sqrt(sum(v**2 for v in a.values()))
        nb = math.sqrt(sum(v**2 for v in b.values()))
        return dot / (na * nb) if na and nb else 0.0


class RAGEngine:
    CHUNK_SIZE    = 400
    CHUNK_OVERLAP = 80

    def __init__(self):
        if _USE_CHROMA:
            self._client = chromadb.Client()
            self._col = self._client.get_or_create_collection("documents")
            self._use_chroma = True
        else:
            self._store = InMemoryVectorStore()
            self._use_chroma = False
        self._documents = []

    def _chunk(self, text):
        text = re.sub(r"\s+", " ", text.strip())
        chunks, start = [], 0
        while start < len(text):
            chunks.append(text[start:start + self.CHUNK_SIZE])
            start += self.CHUNK_SIZE - self.CHUNK_OVERLAP
        return [c for c in chunks if len(c) > 30]

    @staticmethod
    def _embed(text):
        words = re.findall(r"\w+", text.lower())
        vec = [0.0] * 128
        for word in words:
            vec[hash(word) % 128] += 1.0
        norm = math.sqrt(sum(v**2 for v in vec)) or 1
        return [v / norm for v in vec]

    def ingest(self, text, metadata=None):
        metadata = metadata or {}
        chunks = self._chunk(text)
        ids = [str(uuid.uuid4()) for _ in chunks]
        if self._use_chroma:
            embeddings = [self._embed(c) for c in chunks]
            self._col.add(ids=ids, documents=chunks, embeddings=embeddings,
                          metadatas=[metadata] * len(chunks))
        else:
            for cid, chunk in zip(ids, chunks):
                self._store.add(chunk, metadata, cid)
        self._documents.append({"filename": metadata.get("filename", "unknown"),
                                 "chunks": len(chunks)})
        return len(chunks)

    def query(self, text, k=3):
        if self._use_chroma:
            emb = self._embed(text)
            res = self._col.query(query_embeddings=[emb],
                                  n_results=min(k, self._col.count() or 1))
            return [{"text": doc, "source": meta.get("filename", "")}
                    for doc, meta in zip(res["documents"][0], res["metadatas"][0])]
        return self._store.query(text, k)

    def has_documents(self):
        return (self._col.count() > 0) if self._use_chroma else (self._store.count() > 0)

    def list_documents(self):
        return self._documents
PYEOF

# ─── 9. Write backend/mcp_manager.py ───────────────────────────────
cat > "$PLATFORM_DIR/backend/mcp_manager.py" << 'PYEOF'
import json, re, sqlite3, tempfile
from pathlib import Path


class BaseMCPServer:
    name = "base"
    tools = []
    async def call(self, tool_name, args):
        raise NotImplementedError


class FileSystemMCP(BaseMCPServer):
    name = "filesystem"
    tools = [
        {"name": "read_file",      "description": "Read a text file"},
        {"name": "write_file",     "description": "Write content to a file"},
        {"name": "list_directory", "description": "List files in a directory"},
    ]
    def __init__(self, sandbox_dir=None):
        self.sandbox = Path(sandbox_dir or tempfile.mkdtemp())
        self.sandbox.mkdir(parents=True, exist_ok=True)
        (self.sandbox / "readme.txt").write_text("AI Platform demo workspace\n")
        (self.sandbox / "sample.json").write_text('{"project": "ai-platform", "version": "1.0"}')

    async def call(self, tool_name, args):
        if tool_name == "read_file":
            path = self.sandbox / args.get("filename", "")
            return path.read_text() if path.exists() else f"File not found: {args.get('filename')}"
        elif tool_name == "write_file":
            path = self.sandbox / args.get("filename", "output.txt")
            path.write_text(args.get("content", ""))
            return f"Written {len(args.get('content',''))} bytes to {path.name}"
        elif tool_name == "list_directory":
            return json.dumps([f.name for f in self.sandbox.iterdir()])
        return "Unknown file tool"


class WebSearchMCP(BaseMCPServer):
    name = "web_search"
    tools = [{"name": "web_search", "description": "Search the web for current information"}]
    async def call(self, tool_name, args):
        query = args.get("query", "")
        results = [
            {"title": "Wikipedia", "url": "https://wikipedia.org",
             "snippet": "Encyclopedia entry with detailed information."},
            {"title": "Latest News", "url": "https://news.example.com",
             "snippet": "Recent coverage and analysis from multiple sources."},
        ]
        return json.dumps({"query": query, "results": results,
                           "note": "Mock results — add real search API key for live results"})


class DatabaseMCP(BaseMCPServer):
    name = "database"
    tools = [
        {"name": "query_db",    "description": "Run a SELECT query on the database"},
        {"name": "describe_db", "description": "List all tables and their schemas"},
    ]
    def __init__(self):
        self._db = ":memory:"
        conn = sqlite3.connect(self._db)
        conn.execute("CREATE TABLE IF NOT EXISTS conversations "
                     "(id INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT, "
                     "role TEXT, content TEXT, ts REAL)")
        conn.execute("CREATE TABLE IF NOT EXISTS plugins "
                     "(name TEXT PRIMARY KEY, description TEXT, enabled INTEGER)")
        conn.commit()
        conn.close()

    async def call(self, tool_name, args):
        conn = sqlite3.connect(self._db)
        conn.row_factory = sqlite3.Row
        try:
            if tool_name == "describe_db":
                rows = conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'").fetchall()
                tables = []
                for row in rows:
                    schema = conn.execute(f"PRAGMA table_info({row['name']})").fetchall()
                    tables.append({"table": row["name"], "columns": [dict(c) for c in schema]})
                return json.dumps(tables)
            elif tool_name == "query_db":
                sql = args.get("sql", "SELECT 1")
                if not re.match(r"^\s*SELECT", sql, re.IGNORECASE):
                    return "Only SELECT queries are allowed"
                rows = conn.execute(sql).fetchmany(20)
                return json.dumps([dict(r) for r in rows])
        except Exception as e:
            return f"DB error: {e}"
        finally:
            conn.close()


class CustomAPIMCP(BaseMCPServer):
    name = "custom_api"
    tools = [{"name": "call_api", "description": "Call a registered REST API endpoint"}]
    def __init__(self):
        self._endpoints = {}
    def register_endpoint(self, name, url):
        self._endpoints[name] = url
    async def call(self, tool_name, args):
        if tool_name == "call_api":
            endpoint_name = args.get("endpoint", "")
            url = self._endpoints.get(endpoint_name)
            if not url:
                return f"No endpoint registered as '{endpoint_name}'"
            return json.dumps({"endpoint": endpoint_name, "url": url,
                               "note": "Mock — add httpx call for real HTTP"})
        return "Unknown API tool"


class MCPManager:
    def __init__(self):
        self._servers = {}
        self._tool_index = {}
        for server in [FileSystemMCP(), WebSearchMCP(), DatabaseMCP(), CustomAPIMCP()]:
            self._servers[server.name] = server
            for tool in server.tools:
                self._tool_index[tool["name"]] = server

    async def call_tool(self, tool_name, args):
        server = self._tool_index.get(tool_name)
        return await server.call(tool_name, args) if server else f"No MCP server handles: {tool_name}"

    def list_tools(self):
        return [{"server": s.name, **t}
                for s in self._servers.values() for t in s.tools]
PYEOF

# ─── 10. Write backend/plugin_registry.py ──────────────────────────
cat > "$PLATFORM_DIR/backend/plugin_registry.py" << 'PYEOF'
import ast, math, operator, re


def weather_plugin(query, **kwargs):
    return {"city": query.strip(), "temp_c": 22, "condition": "Partly cloudy",
            "humidity": 60, "wind_kmh": 15,
            "note": "Mock data — add OpenWeatherMap API key for real weather"}


def calculator_plugin(query, **kwargs):
    SAFE_OPS = {
        ast.Add: operator.add, ast.Sub: operator.sub,
        ast.Mult: operator.mul, ast.Div: operator.truediv,
        ast.Pow: operator.pow, ast.USub: operator.neg, ast.Mod: operator.mod,
    }
    SAFE_FUNCS = {
        "sqrt": math.sqrt, "log": math.log, "sin": math.sin,
        "cos": math.cos, "tan": math.tan, "abs": abs,
        "round": round, "pi": math.pi, "e": math.e,
    }
    def _eval(node):
        if isinstance(node, ast.Constant): return node.value
        elif isinstance(node, ast.BinOp):
            op = SAFE_OPS.get(type(node.op))
            if op: return op(_eval(node.left), _eval(node.right))
        elif isinstance(node, ast.UnaryOp):
            op = SAFE_OPS.get(type(node.op))
            if op: return op(_eval(node.operand))
        elif isinstance(node, ast.Call):
            fn = node.func.id if isinstance(node.func, ast.Name) else None
            if fn in SAFE_FUNCS: return SAFE_FUNCS[fn](*[_eval(a) for a in node.args])
        elif isinstance(node, ast.Name):
            if node.id in SAFE_FUNCS: return SAFE_FUNCS[node.id]
        raise ValueError(f"Unsafe: {ast.dump(node)}")
    try:
        tree = ast.parse(query.strip(), mode="eval")
        return {"expression": query, "result": _eval(tree.body)}
    except Exception as e:
        return {"expression": query, "error": str(e)}


def code_exec_plugin(query, **kwargs):
    output_lines = []
    safe_globals = {"__builtins__": {
        "print": lambda *a, **k: output_lines.append(" ".join(str(x) for x in a)),
        "range": range, "len": len, "int": int, "float": float, "str": str,
        "list": list, "dict": dict, "sum": sum, "max": max, "min": min,
        "abs": abs, "round": round, "enumerate": enumerate, "zip": zip,
    }}
    try:
        exec(query, safe_globals)
        return {"code": query, "output": "\n".join(output_lines), "status": "success"}
    except Exception as e:
        return {"code": query, "error": str(e), "status": "error"}


def summarizer_plugin(query, **kwargs):
    sentences = re.split(r"(?<=[.!?])\s+", query)
    words = re.findall(r"\w+", query.lower())
    freq = {}
    for w in words: freq[w] = freq.get(w, 0) + 1
    def score(s):
        ws = re.findall(r"\w+", s.lower())
        return sum(freq.get(w, 0) for w in ws) / (len(ws) or 1)
    ranked = sorted(enumerate(sentences), key=lambda x: score(x[1]), reverse=True)
    top = sorted(ranked[:3], key=lambda x: x[0])
    summary = " ".join(s for _, s in top)
    return {"summary": summary, "original_length": len(query), "summary_length": len(summary)}


class PluginRegistry:
    BUILTIN_PLUGINS = {
        "weather":    {"name": "weather",    "description": "Get current weather for a city.", "fn": weather_plugin},
        "calculator": {"name": "calculator", "description": "Evaluate math expressions safely.", "fn": calculator_plugin},
        "code_exec":  {"name": "code_exec",  "description": "Execute Python in a sandbox.", "fn": code_exec_plugin},
        "summarizer": {"name": "summarizer", "description": "Summarize long text.", "fn": summarizer_plugin},
    }

    def __init__(self):
        self._plugins = dict(self.BUILTIN_PLUGINS)

    def register(self, config):
        name = config["name"]
        self._plugins[name] = {
            "name": name,
            "description": config.get("description", f"Custom plugin: {name}"),
            "fn": lambda query, **kw: {"result": f"Custom plugin '{name}' called with: {query}"},
            "custom": True,
        }

    def call(self, name, args):
        plugin = self._plugins.get(name)
        if not plugin: return None
        fn = plugin.get("fn")
        return fn(**args) if fn else None

    def get_all(self):
        return self._plugins

    def list_plugins(self):
        return [{"name": v["name"], "description": v["description"], "custom": v.get("custom", False)}
                for v in self._plugins.values()]
PYEOF

# ─── 11. Write backend/orchestrator.py (Ollama) ────────────────────
cat > "$PLATFORM_DIR/backend/orchestrator.py" << 'PYEOF'
"""
orchestrator.py — Ollama edition
Uses Ollama's /api/chat endpoint (no Anthropic SDK, 100% free).
"""
import json, os
import httpx

from rag_engine import RAGEngine
from mcp_manager import MCPManager
from plugin_registry import PluginRegistry
from agent_config import AgentConfig

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL    = os.environ.get("OLLAMA_MODEL", "llama3.1")


async def _ollama_stream(system_prompt, messages, tools):
    payload = {
        "model":  OLLAMA_MODEL,
        "stream": True,
        "messages": [{"role": "system", "content": system_prompt}] + [
            {"role": m["role"],
             "content": m["content"] if isinstance(m["content"], str) else _flatten(m["content"])}
            for m in messages
        ],
    }
    if tools:
        payload["tools"] = [
            {"type": "function", "function": {
                "name": t["name"],
                "description": t["description"],
                "parameters": t.get("input_schema", {"type": "object", "properties": {}}),
            }} for t in tools
        ]
    async with httpx.AsyncClient(timeout=120) as client:
        async with client.stream("POST", f"{OLLAMA_BASE_URL}/api/chat", json=payload) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.strip():
                    continue
                try:
                    chunk = json.loads(line)
                except:
                    continue
                msg = chunk.get("message", {})
                token = msg.get("content", "")
                if token:
                    yield {"type": "token", "text": token}
                for tc in msg.get("tool_calls", []):
                    fn   = tc.get("function", {})
                    args = fn.get("arguments", {})
                    if isinstance(args, str):
                        try: args = json.loads(args)
                        except: args = {"query": args}
                    yield {"type": "tool_use", "name": fn.get("name",""), "id": tc.get("id","tc0"), "input": args}
                if chunk.get("done"):
                    yield {"type": "done", "stop_reason": "stop"}
                    return


def _flatten(content):
    if isinstance(content, str): return content
    parts = []
    for b in content:
        if isinstance(b, dict):
            if b.get("type") == "text": parts.append(b["text"])
            elif b.get("type") == "tool_result": parts.append(f"[Tool result: {b.get('content','')}]")
        else:
            t = getattr(b, "type", "")
            if t == "text": parts.append(b.text)
    return " ".join(parts)


class BaseAgent:
    name = "base"
    system_prompt = "You are a helpful AI assistant."

    def __init__(self, rag, mcp, plugins):
        self.rag = rag
        self.mcp = mcp
        self.plugins = plugins

    def _build_tools(self):
        return [{"name": n, "description": p["description"],
                 "input_schema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}
                for n, p in self.plugins.get_all().items()]

    async def _handle_tool(self, name, inp):
        result = self.plugins.call(name, inp)
        if result is not None: return str(result)
        return str(await self.mcp.call_tool(name, inp))

    async def run(self, text, history, context=""):
        system = self.system_prompt
        if context:
            system += f"\n\n## Relevant context:\n{context}"
        messages = list(history)
        tools = self._build_tools()

        while True:
            full_text = ""
            tool_calls = []
            async for ev in _ollama_stream(system, messages, tools):
                if ev["type"] == "token":
                    full_text += ev["text"]
                    yield {"type": "token", "text": ev["text"], "agent": self.name}
                elif ev["type"] == "tool_use":
                    tool_calls.append(ev)
                    yield {"type": "tool_call", "tool": ev["name"], "input": ev["input"], "agent": self.name}
            messages.append({"role": "assistant", "content": full_text})
            if tool_calls:
                results = []
                for tc in tool_calls:
                    result = await self._handle_tool(tc["name"], tc["input"])
                    yield {"type": "tool_result", "tool": tc["name"], "result": result[:500], "agent": self.name}
                    results.append(f"[Tool '{tc['name']}' returned]: {result}")
                messages.append({"role": "user", "content": "\n".join(results)})
            else:
                break


class ResearchAgent(BaseAgent):
    name = "research_agent"
    system_prompt = "You are a Research Agent. Find accurate, up-to-date information. Be thorough and cite sources when relevant."

class CodingAgent(BaseAgent):
    name = "coding_agent"
    system_prompt = "You are an expert Coding Agent. Write clean, well-commented, production-ready code. Always explain your code."

class DataAgent(BaseAgent):
    name = "data_agent"
    system_prompt = "You are a Data Analysis Agent. Analyse data carefully, identify patterns, and present findings clearly."

class CustomAgent(BaseAgent):
    def __init__(self, rag, mcp, plugins, config):
        super().__init__(rag, mcp, plugins)
        self.config = config
        self.system_prompt = config.get("system_prompt", f"You are {config.get('name','an AI assistant')}.")
        self.name = config.get("agent_id", "custom_agent")


class Orchestrator:
    def __init__(self, rag, mcp, plugins, agent_config):
        self.rag = rag
        self.mcp = mcp
        self.plugins = plugins
        self.config = agent_config
        self.agents = {
            "research_agent": ResearchAgent(rag, mcp, plugins),
            "coding_agent":   CodingAgent(rag, mcp, plugins),
            "data_agent":     DataAgent(rag, mcp, plugins),
        }

    def _get_agent(self, agent_id):
        custom = self.config.get(agent_id)
        if custom: return CustomAgent(self.rag, self.mcp, self.plugins, custom)
        return self.agents.get(agent_id) or self.agents["research_agent"]

    async def run(self, text, route, history, session_id):
        agent_id = route["agent"]
        yield {"type": "status", "text": f"Activating {agent_id}...", "agent": agent_id}

        rag_context = ""
        if self.rag.has_documents():
            yield {"type": "status", "text": "Searching knowledge base...", "agent": "rag"}
            chunks = self.rag.query(text, k=3)
            if chunks:
                rag_context = "\n\n".join(c["text"] for c in chunks)
                yield {"type": "rag_context",
                       "chunks": [{"text": c["text"][:200], "source": c.get("source", "")} for c in chunks]}

        agent = self._get_agent(agent_id)
        async for event in agent.run(text, history, rag_context):
            yield event
PYEOF

# ─── 12. Write backend/main.py ─────────────────────────────────────
cat > "$PLATFORM_DIR/backend/main.py" << 'PYEOF'
import asyncio, json, time, hashlib, logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware

from hooks import PreHook, PostHook, RequestRouter
from orchestrator import Orchestrator
from rag_engine import RAGEngine
from mcp_manager import MCPManager
from plugin_registry import PluginRegistry
from agent_config import AgentConfig

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ai-platform")

app = FastAPI(title="AI Platform (Ollama)", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

rag_engine      = RAGEngine()
mcp_manager     = MCPManager()
plugin_registry = PluginRegistry()
agent_config    = AgentConfig()
orchestrator    = Orchestrator(rag_engine, mcp_manager, plugin_registry, agent_config)
pre_hook        = PreHook()
post_hook       = PostHook()
router_hook     = RequestRouter()


@app.get("/health")
async def health():
    return {"status": "ok", "backend": "ollama", "layers": ["hooks","router","agents","rag","mcp","plugins"]}

@app.get("/agents")
async def list_agents():
    return {"agents": agent_config.list_agents()}

@app.post("/agents/configure")
async def configure_agent(payload: dict):
    agent_config.configure(payload["agent_id"], payload)
    return {"configured": payload["agent_id"]}

@app.get("/plugins")
async def list_plugins():
    return {"plugins": plugin_registry.list_plugins()}

@app.post("/plugins/register")
async def register_plugin(payload: dict):
    plugin_registry.register(payload)
    return {"registered": payload["name"]}

@app.post("/rag/ingest")
async def ingest_document(file: UploadFile = File(...)):
    content = await file.read()
    text = content.decode("utf-8", errors="ignore")
    chunks = rag_engine.ingest(text, metadata={"filename": file.filename})
    return {"filename": file.filename, "chunks": chunks}

@app.get("/rag/documents")
async def list_documents():
    return {"documents": rag_engine.list_documents()}

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    session_id = hashlib.md5(str(time.time()).encode()).hexdigest()[:8]
    history = []
    logger.info(f"[{session_id}] connected")
    try:
        while True:
            raw = await ws.receive_text()
            message = json.loads(raw)
            user_text = message.get("text", "").strip()
            if not user_text:
                continue

            hook_result = pre_hook.run(user_text, session_id)
            await ws.send_text(json.dumps({"type": "hook", "phase": "pre", "detail": hook_result}))

            if hook_result.get("blocked"):
                await ws.send_text(json.dumps({"type": "error", "text": hook_result["reason"]}))
                continue

            route = router_hook.route(user_text)
            await ws.send_text(json.dumps({"type": "route", "agent": route["agent"], "intent": route["intent"]}))

            history.append({"role": "user", "content": user_text})
            full_response = ""

            async for event in orchestrator.run(user_text, route, history, session_id):
                await ws.send_text(json.dumps(event))
                if event["type"] == "token":
                    full_response += event["text"]

            history.append({"role": "assistant", "content": full_response})
            post = post_hook.run(full_response, session_id)
            await ws.send_text(json.dumps({"type": "hook", "phase": "post", "detail": post}))
            await ws.send_text(json.dumps({"type": "done"}))

    except WebSocketDisconnect:
        logger.info(f"[{session_id}] disconnected")
    except Exception as e:
        logger.error(f"[{session_id}] error: {e}", exc_info=True)
        try:
            await ws.send_text(json.dumps({"type": "error", "text": str(e)}))
        except:
            pass
PYEOF

# ─── 13. Write frontend/package.json ───────────────────────────────
cat > "$PLATFORM_DIR/frontend/package.json" << 'EOF'
{
  "name": "ai-platform-frontend",
  "version": "2.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-scripts": "5.0.1"
  },
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build"
  },
  "browserslist": {
    "production": [">0.2%", "not dead"],
    "development": ["last 1 chrome version"]
  }
}
EOF

# ─── 14. Write frontend/src/index.js ───────────────────────────────
cat > "$PLATFORM_DIR/frontend/src/index.js" << 'EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
EOF

# ─── 15. Write frontend/public/index.html ──────────────────────────
mkdir -p "$PLATFORM_DIR/frontend/public"
cat > "$PLATFORM_DIR/frontend/public/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>AI Platform</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Syne:wght@400;500;600;700&display=swap" rel="stylesheet">
</head>
<body style="margin:0;background:#0a0a0f">
  <div id="root"></div>
</body>
</html>
EOF

# ─── 16. Write frontend/src/App.jsx (new UI) ───────────────────────
cat > "$PLATFORM_DIR/frontend/src/App.jsx" << 'JSXEOF'
import { useState, useEffect, useRef, useCallback } from "react";

// ── Design System ──────────────────────────────────────────────────
const css = `
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Syne:wght@400;500;600;700;800&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg:        #0a0a0f;
    --bg1:       #111118;
    --bg2:       #1a1a24;
    --bg3:       #22222e;
    --border:    #2a2a3a;
    --border2:   #383850;
    --text:      #e8e8f0;
    --text2:     #9090a8;
    --text3:     #5a5a72;
    --accent:    #7c6cfc;
    --accent2:   #a594ff;
    --green:     #3ecf8e;
    --amber:     #f59e0b;
    --red:       #f87171;
    --teal:      #2dd4bf;
    --pink:      #f472b6;
    --blue:      #60a5fa;
    --font-sans: 'Syne', sans-serif;
    --font-mono: 'IBM Plex Mono', monospace;
  }

  body { background: var(--bg); color: var(--text); font-family: var(--font-sans); }

  ::-webkit-scrollbar { width: 4px; height: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border2); border-radius: 4px; }

  .tab-pill {
    display: flex; align-items: center; gap: 7px;
    padding: 7px 16px; border-radius: 6px; border: none;
    font-family: var(--font-sans); font-size: 13px; font-weight: 500;
    cursor: pointer; transition: all .18s; background: transparent;
    color: var(--text3); letter-spacing: .02em;
  }
  .tab-pill:hover { color: var(--text2); background: var(--bg2); }
  .tab-pill.active { background: var(--bg3); color: var(--text); border: 1px solid var(--border2); }

  .send-btn {
    background: var(--accent); color: #fff; border: none;
    border-radius: 8px; padding: 0 20px; font-family: var(--font-sans);
    font-size: 13px; font-weight: 600; cursor: pointer;
    transition: all .18s; letter-spacing: .03em; white-space: nowrap;
  }
  .send-btn:hover { background: var(--accent2); transform: translateY(-1px); }
  .send-btn:disabled { opacity: .35; cursor: not-allowed; transform: none; }

  .ghost-btn {
    background: var(--bg2); color: var(--text2); border: 1px solid var(--border);
    border-radius: 6px; padding: 5px 12px; font-family: var(--font-sans);
    font-size: 12px; font-weight: 500; cursor: pointer; transition: all .15s;
  }
  .ghost-btn:hover { border-color: var(--border2); color: var(--text); }

  .primary-btn {
    background: var(--accent); color: #fff; border: none;
    border-radius: 8px; padding: 9px 18px; font-family: var(--font-sans);
    font-size: 13px; font-weight: 600; cursor: pointer; transition: all .18s;
  }
  .primary-btn:hover { background: var(--accent2); }

  .inp {
    width: 100%; background: var(--bg2); border: 1px solid var(--border);
    border-radius: 8px; padding: 9px 13px; font-family: var(--font-sans);
    font-size: 13px; color: var(--text); outline: none; transition: border .15s;
  }
  .inp:focus { border-color: var(--accent); }
  .inp::placeholder { color: var(--text3); }

  .textarea-inp {
    width: 100%; background: var(--bg2); border: 1px solid var(--border);
    border-radius: 8px; padding: 9px 13px; font-family: var(--font-sans);
    font-size: 13px; color: var(--text); outline: none; transition: border .15s;
    resize: vertical; min-height: 80px;
  }
  .textarea-inp:focus { border-color: var(--accent); }
  .textarea-inp::placeholder { color: var(--text3); }

  .card {
    background: var(--bg1); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px;
  }
  .card-sm { padding: 14px 16px; }

  @keyframes pulse { 0%,100%{opacity:.4;transform:scale(.9)} 50%{opacity:1;transform:scale(1)} }
  @keyframes fadeIn { from{opacity:0;transform:translateY(6px)} to{opacity:1;transform:translateY(0)} }
  @keyframes glow { 0%,100%{box-shadow:0 0 8px #7c6cfc44} 50%{box-shadow:0 0 18px #7c6cfc88} }
  @keyframes slideIn { from{opacity:0;transform:translateX(-8px)} to{opacity:1;transform:translateX(0)} }

  .msg-anim { animation: fadeIn .22s ease; }
  .event-anim { animation: slideIn .15s ease; }

  pre { font-family: var(--font-mono); font-size: 12px; }
  code { font-family: var(--font-mono); }

  .label {
    font-size: 11px; font-weight: 600; color: var(--text3);
    text-transform: uppercase; letter-spacing: .08em; margin-bottom: 6px; display: block;
  }

  details > summary { cursor: pointer; user-select: none; }
  details > summary::-webkit-details-marker { display: none; }

  .chip {
    display: inline-flex; align-items: center; gap: 5px;
    padding: 3px 9px; border-radius: 100px; font-size: 11px;
    font-weight: 600; white-space: nowrap; font-family: var(--font-mono);
  }
  .chip-dot { width: 5px; height: 5px; border-radius: 50%; }

  .agent-card {
    background: var(--bg1); border: 1px solid var(--border);
    border-radius: 12px; padding: 16px; transition: all .2s;
    position: relative; overflow: hidden;
  }
  .agent-card::before {
    content:''; position:absolute; top:0; left:0; right:0; height:2px;
    background: var(--card-accent, var(--accent));
  }
  .agent-card:hover { border-color: var(--border2); transform: translateY(-2px); }

  .pipeline-step {
    display: flex; align-items: center; gap: 6px;
    padding: 6px 12px; border-radius: 8px; font-size: 12px;
    font-weight: 600; white-space: nowrap; flex-shrink: 0;
    font-family: var(--font-mono);
  }

  .section-title {
    font-size: 22px; font-weight: 700; color: var(--text);
    letter-spacing: -.02em; margin-bottom: 6px;
  }
  .section-sub {
    font-size: 13px; color: var(--text2); margin-bottom: 24px; line-height: 1.6;
  }
`;

// ── Colours per event/intent ──────────────────────────────────────
const CHIP_COLORS = {
  hook:       { bg:"#2a1a2e", border:"#5a3060", text:"#c084fc", dot:"#c084fc" },
  route:      { bg:"#1a1a30", border:"#3a3a70", text:"#818cf8", dot:"#818cf8" },
  status:     { bg:"#1a1f1a", border:"#2a3a2a", text:"#4ade80", dot:"#4ade80" },
  rag_context:{ bg:"#2a1f10", border:"#5a3a10", text:"#fbbf24", dot:"#fbbf24" },
  tool_call:  { bg:"#101a2a", border:"#1a3a5a", text:"#60a5fa", dot:"#60a5fa" },
  tool_result:{ bg:"#102a1a", border:"#1a5a2a", text:"#3ecf8e", dot:"#3ecf8e" },
  error:      { bg:"#2a1010", border:"#5a1a1a", text:"#f87171", dot:"#f87171" },
  done:       { bg:"#101a1a", border:"#1a3a3a", text:"#2dd4bf", dot:"#2dd4bf" },
};

const AGENT_ACCENTS = {
  research_agent: "#60a5fa",
  coding_agent:   "#3ecf8e",
  data_agent:     "#fbbf24",
};

const TABS = [
  { id:"chat",    label:"Chat",         icon:"◈" },
  { id:"agents",  label:"Agents",       icon:"⬡" },
  { id:"rag",     label:"Knowledge",    icon:"◎" },
  { id:"plugins", label:"Plugins",      icon:"⊕" },
  { id:"arch",    label:"Architecture", icon:"⬢" },
];

const MOCK_AGENTS = [
  { agent_id:"research_agent", name:"Research Agent", description:"Finds and synthesizes information from web and documents", icon:"🔍", temperature:0.3, builtin:true },
  { agent_id:"coding_agent",   name:"Coding Agent",   description:"Writes, explains, and debugs code in any language",      icon:"💻", temperature:0.2, builtin:true },
  { agent_id:"data_agent",     name:"Data Agent",     description:"Analyzes data, identifies patterns, produces insights",  icon:"📊", temperature:0.2, builtin:true },
];

const MOCK_PLUGINS = [
  { name:"weather",    description:"Get current weather for any city", custom:false },
  { name:"calculator", description:"Safely evaluate math expressions", custom:false },
  { name:"code_exec",  description:"Execute Python in a sandbox",      custom:false },
  { name:"summarizer", description:"Extractive summarization of text", custom:false },
];

// ── Pre/Router hooks (frontend sim) ──────────────────────────────
function runPreHook(text) {
  const blocked = /ignore.*instructions|jailbreak/i.test(text);
  return { blocked, reason: blocked ? "Content policy violation" : null, logged: true, rate_remaining: 18 };
}
function runRouter(text) {
  const l = text.toLowerCase();
  if (/\bcode\b|\bpython\b|\bfunction\b|\bdebug\b/.test(l)) return { agent:"coding_agent",   intent:"code"   };
  if (/\banalyze\b|\bdata\b|\bchart\b|\bstatistic/.test(l))  return { agent:"data_agent",     intent:"data"   };
  if (/\bsearch\b|\bfind\b|\bwhat is\b|\bwho is/.test(l))    return { agent:"research_agent", intent:"search" };
  return { agent:"research_agent", intent:"general" };
}

const AGENT_PROMPTS = {
  research_agent: "You are a Research Agent. Find accurate information and cite sources when relevant. Be concise but complete.",
  coding_agent:   "You are an expert Coding Agent. Write clean, well-commented code. Always explain what your code does. Use markdown code blocks.",
  data_agent:     "You are a Data Analysis Agent. Analyze carefully, identify patterns, and present findings clearly.",
};
function getSystemPrompt(agentId, customAgents) {
  const c = customAgents.find(a => a.agent_id === agentId);
  if (c?.system_prompt) return c.system_prompt;
  return AGENT_PROMPTS[agentId] || "You are a helpful AI assistant.";
}

// ── Ollama API call ────────────────────────────────────────────────
async function callOllama(messages, systemPrompt) {
  const ollamaUrl = "http://localhost:11434/api/chat";
  const model = window.OLLAMA_MODEL || "phi3:mini";
  const resp = await fetch(ollamaUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      stream: false,
      messages: [
        { role: "system", content: systemPrompt },
        ...messages.map(m => ({ role: m.role, content: m.content }))
      ],
    }),
  });
  if (!resp.ok) throw new Error(`Ollama error ${resp.status}: Is Ollama running? Run: ollama serve`);
  const data = await resp.json();
  return data.message?.content || "No response";
}

// ── Chip ──────────────────────────────────────────────────────────
function Chip({ type, children }) {
  const c = CHIP_COLORS[type] || CHIP_COLORS.status;
  return (
    <span className="chip" style={{ background:c.bg, border:`1px solid ${c.border}`, color:c.text }}>
      <span className="chip-dot" style={{ background:c.dot }}/>
      {children}
    </span>
  );
}

// ── Event Log ─────────────────────────────────────────────────────
function EventLog({ events }) {
  const ref = useRef(null);
  useEffect(() => { ref.current?.scrollIntoView({ behavior:"smooth" }); }, [events]);
  return (
    <div style={{ display:"flex", flexDirection:"column", gap:6 }}>
      {events.map((ev, i) => {
        if (ev.type === "token") return null;
        let detail = "";
        if (ev.type === "route")      detail = `→ ${ev.agent} · ${ev.intent}`;
        if (ev.type === "hook")       detail = `${ev.phase}: ${JSON.stringify(ev.detail).slice(0,70)}`;
        if (ev.type === "status")     detail = ev.text;
        if (ev.type === "rag_context")detail = `${ev.chunks?.length} chunk(s) retrieved`;
        if (ev.type === "tool_call")  detail = `${ev.tool}(${JSON.stringify(ev.input).slice(0,50)})`;
        if (ev.type === "tool_result")detail = ev.result?.slice(0,80);
        if (ev.type === "done")       detail = "Response complete";
        if (ev.type === "error")      detail = ev.text;
        return (
          <div key={i} className="event-anim" style={{ display:"flex", gap:8, alignItems:"flex-start" }}>
            <Chip type={ev.type}>{ev.type}</Chip>
            <span style={{ fontFamily:"var(--font-mono)", fontSize:11, color:"var(--text2)",
              flex:1, wordBreak:"break-all", lineHeight:1.6, paddingTop:1 }}>
              {detail}
            </span>
          </div>
        );
      })}
      <div ref={ref}/>
    </div>
  );
}

// ── Message bubble ─────────────────────────────────────────────────
function renderContent(text) {
  const parts = text.split(/(```[\s\S]*?```)/g);
  return parts.map((part, i) => {
    if (part.startsWith("```")) {
      const lines = part.slice(3).split("\n");
      const lang = lines[0].trim();
      const code = lines.slice(1).join("\n").replace(/```$/, "");
      return (
        <div key={i} style={{ margin:"10px 0", background:"var(--bg)", border:"1px solid var(--border2)",
          borderRadius:8, overflow:"hidden" }}>
          {lang && <div style={{ padding:"4px 12px", background:"var(--bg3)", fontSize:11,
            fontFamily:"var(--font-mono)", color:"var(--text3)", borderBottom:"1px solid var(--border)" }}>
            {lang}
          </div>}
          <pre style={{ padding:"12px 14px", overflowX:"auto", fontSize:12, lineHeight:1.7,
            color:"var(--text)", margin:0 }}><code>{code}</code></pre>
        </div>
      );
    }
    return <span key={i} style={{ whiteSpace:"pre-wrap", lineHeight:1.7 }}>{part}</span>;
  });
}

function MessageBubble({ msg }) {
  const isUser = msg.role === "user";
  const accent = AGENT_ACCENTS[msg.agentId] || "var(--accent)";
  return (
    <div className="msg-anim" style={{ display:"flex", justifyContent: isUser ? "flex-end" : "flex-start",
      marginBottom:16, gap:10, alignItems:"flex-start" }}>
      {!isUser && (
        <div style={{ width:32, height:32, borderRadius:8, background:"var(--bg3)",
          border:`1px solid ${accent}44`, display:"flex", alignItems:"center",
          justifyContent:"center", fontSize:15, flexShrink:0, marginTop:2 }}>
          {msg.agentIcon || "◈"}
        </div>
      )}
      <div style={{
        maxWidth:"75%", padding:"12px 16px",
        borderRadius: isUser ? "12px 12px 3px 12px" : "3px 12px 12px 12px",
        background: isUser ? "var(--bg3)" : "var(--bg1)",
        border: isUser ? "1px solid var(--border2)" : `1px solid ${accent}33`,
        fontSize:14, color:"var(--text)", position:"relative",
      }}>
        {!isUser && msg.agent && (
          <div style={{ fontSize:11, fontWeight:600, color:accent, marginBottom:6,
            fontFamily:"var(--font-mono)", textTransform:"uppercase", letterSpacing:".05em" }}>
            {msg.agent}
          </div>
        )}
        {renderContent(msg.content)}
      </div>
      {isUser && (
        <div style={{ width:32, height:32, borderRadius:8, background:"var(--bg3)",
          border:"1px solid var(--border2)", display:"flex", alignItems:"center",
          justifyContent:"center", fontSize:15, flexShrink:0, marginTop:2 }}>
          ◇
        </div>
      )}
    </div>
  );
}

function TypingIndicator() {
  return (
    <div className="msg-anim" style={{ display:"flex", gap:10, alignItems:"flex-start", marginBottom:16 }}>
      <div style={{ width:32, height:32, borderRadius:8, background:"var(--bg3)",
        border:"1px solid var(--accent)44", display:"flex", alignItems:"center",
        justifyContent:"center", fontSize:15, animation:"glow 2s ease-in-out infinite" }}>
        ◈
      </div>
      <div style={{ padding:"14px 16px", background:"var(--bg1)", border:"1px solid var(--accent)33",
        borderRadius:"3px 12px 12px 12px", display:"flex", gap:6, alignItems:"center" }}>
        {[0,1,2].map(i => (
          <div key={i} style={{ width:6, height:6, borderRadius:"50%", background:"var(--accent)",
            animation:`pulse 1.4s ${i*0.2}s ease-in-out infinite` }}/>
        ))}
      </div>
    </div>
  );
}

// ── Main App ──────────────────────────────────────────────────────
export default function App() {
  const [tab, setTab]             = useState("chat");
  const [messages, setMessages]   = useState([{
    role:"assistant",
    content:"Hello. I'm your AI Platform running on Ollama — fully local, free, and private.\n\nI coordinate three specialized agents: Research, Coding, and Data. Each has access to RAG, MCP tools, and Plugins.\n\nWhat would you like to work on?",
    agentIcon:"◈", agent:"Orchestrator"
  }]);
  const [input, setInput]         = useState("");
  const [events, setEvents]       = useState([]);
  const [loading, setLoading]     = useState(false);
  const [agents, setAgents]       = useState(MOCK_AGENTS);
  const [plugins, setPlugins]     = useState(MOCK_PLUGINS);
  const [docs, setDocs]           = useState([]);
  const [customAgents, setCustomAgents] = useState([]);
  const [newAgent, setNewAgent]   = useState({ name:"", description:"", system_prompt:"", temperature:0.7 });
  const [newPlugin, setNewPlugin] = useState({ name:"", description:"" });
  const chatEndRef = useRef(null);
  useEffect(() => { chatEndRef.current?.scrollIntoView({ behavior:"smooth" }); }, [messages, loading]);

  const sendMessage = useCallback(async () => {
    const text = input.trim();
    if (!text || loading) return;
    setInput("");
    setLoading(true);
    const addEv = (ev) => setEvents(prev => [...prev, ev]);
    setMessages(prev => [...prev, { role:"user", content:text }]);

    const hookResult = runPreHook(text);
    addEv({ type:"hook", phase:"pre", detail:hookResult });
    if (hookResult.blocked) {
      setMessages(prev => [...prev, { role:"assistant", content:`⚠️ Blocked: ${hookResult.reason}`, agentIcon:"⚠" }]);
      setLoading(false);
      return;
    }

    const route = runRouter(text);
    addEv({ type:"route", agent:route.agent, intent:route.intent });
    const agentInfo = agents.find(a => a.agent_id === route.agent);
    addEv({ type:"status", text:`Activating ${agentInfo?.name || route.agent}...` });

    if (docs.length > 0) {
      addEv({ type:"status", text:"Searching knowledge base..." });
      addEv({ type:"rag_context", chunks:[{ text:"Relevant chunk found", source: docs[0]?.name }] });
    }

    try {
      const history = messages.filter(m=>m.role!=="system").map(m=>({role:m.role,content:m.content}));
      history.push({ role:"user", content:text });
      const systemPrompt = getSystemPrompt(route.agent, customAgents);
      addEv({ type:"status", text:"Generating response via Ollama..." });
      const response = await callOllama(history, systemPrompt);
      addEv({ type:"done" });
      setMessages(prev => [...prev, {
        role:"assistant", content:response,
        agent:agentInfo?.name || route.agent,
        agentId: route.agent,
        agentIcon: agentInfo?.icon || "◈",
      }]);
    } catch(err) {
      addEv({ type:"error", text:err.message });
      setMessages(prev => [...prev, {
        role:"assistant",
        content:`⚠️ Could not reach Ollama.\n\nMake sure it's running:\n\`\`\`bash\nollama serve\n\`\`\`\nAnd that you've pulled a model:\n\`\`\`bash\nollama pull llama3.1\n\`\`\``,
        agentIcon:"⚠"
      }]);
    }

    addEv({ type:"hook", phase:"post", detail:{ resp_len:200, tokens_est:50 } });
    setLoading(false);
  }, [input, loading, messages, agents, docs, customAgents]);

  return (
    <div style={{ minHeight:"100vh", background:"var(--bg)", fontFamily:"var(--font-sans)" }}>
      <style>{css}</style>

      {/* ── Header ── */}
      <header style={{ background:"var(--bg1)", borderBottom:"1px solid var(--border)",
        padding:"0 24px", display:"flex", alignItems:"center",
        justifyContent:"space-between", height:56, position:"sticky", top:0, zIndex:100,
        backdropFilter:"blur(10px)" }}>
        <div style={{ display:"flex", alignItems:"center", gap:12 }}>
          <div style={{ width:32, height:32, borderRadius:8, background:"var(--accent)",
            display:"flex", alignItems:"center", justifyContent:"center",
            fontSize:17, animation:"glow 3s ease-in-out infinite" }}>
            ◈
          </div>
          <div>
            <div style={{ fontSize:15, fontWeight:700, letterSpacing:"-.01em" }}>AI Platform</div>
            <div style={{ fontSize:11, color:"var(--text3)", fontFamily:"var(--font-mono)", letterSpacing:".05em" }}>
              OLLAMA · LOCAL · FREE
            </div>
          </div>
        </div>
        <nav style={{ display:"flex", gap:2 }}>
          {TABS.map(t => (
            <button key={t.id} className={`tab-pill ${tab===t.id?"active":""}`} onClick={()=>setTab(t.id)}>
              <span style={{ fontFamily:"var(--font-mono)", fontSize:14 }}>{t.icon}</span>
              {t.label}
            </button>
          ))}
        </nav>
        <div style={{ display:"flex", alignItems:"center", gap:8 }}>
          <div style={{ width:7, height:7, borderRadius:"50%", background:"var(--green)",
            animation:"pulse 2s ease-in-out infinite" }}/>
          <span style={{ fontSize:12, color:"var(--text2)", fontFamily:"var(--font-mono)" }}>
            {window.OLLAMA_MODEL || "llama3.1"}
          </span>
        </div>
      </header>

      {/* ── CHAT TAB ── */}
      {tab === "chat" && (
        <div style={{ maxWidth:1200, margin:"0 auto", padding:24,
          display:"grid", gridTemplateColumns:"1fr 300px", gap:20, alignItems:"start" }}>

          {/* Left: chat */}
          <div style={{ display:"flex", flexDirection:"column", gap:12 }}>
            <div className="card" style={{ height:520, overflowY:"auto", padding:20 }}>
              {messages.map((m,i) => <MessageBubble key={i} msg={m}/>)}
              {loading && <TypingIndicator/>}
              <div ref={chatEndRef}/>
            </div>

            {/* Quick prompts */}
            <div style={{ display:"flex", gap:8, flexWrap:"wrap" }}>
              {[
                "Write a Python function to parse JSON",
                "Analyze trends in AI for 2025",
                "Explain RAG in 3 sentences",
                "Calculate sqrt(144) + 2^8",
              ].map(p => (
                <button key={p} className="ghost-btn" onClick={()=>setInput(p)}
                  style={{ fontSize:12 }}>{p}</button>
              ))}
            </div>

            {/* Input */}
            <div style={{ display:"flex", gap:8 }}>
              <input className="inp" value={input}
                onChange={e=>setInput(e.target.value)}
                onKeyDown={e=>e.key==="Enter" && !e.shiftKey && sendMessage()}
                placeholder="Message the AI Platform..."
                style={{ flex:1, height:44 }}/>
              <button className="send-btn" onClick={sendMessage} disabled={loading||!input.trim()}>
                Send ↗
              </button>
            </div>
          </div>

          {/* Right: pipeline + agents */}
          <div style={{ display:"flex", flexDirection:"column", gap:12 }}>
            <div className="card" style={{ padding:16 }}>
              <div style={{ display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:12 }}>
                <span style={{ fontSize:12, fontWeight:700, color:"var(--text2)",
                  textTransform:"uppercase", letterSpacing:".08em" }}>Pipeline Events</span>
                <button className="ghost-btn" style={{ fontSize:11 }} onClick={()=>setEvents([])}>Clear</button>
              </div>
              <div style={{ height:300, overflowY:"auto" }}>
                {events.length === 0
                  ? <div style={{ color:"var(--text3)", fontSize:12, fontFamily:"var(--font-mono)",
                      textAlign:"center", paddingTop:48, lineHeight:2 }}>
                      // events appear here<br/>// as you chat
                    </div>
                  : <EventLog events={events}/>
                }
              </div>
            </div>

            <div className="card" style={{ padding:16 }}>
              <div style={{ fontSize:12, fontWeight:700, color:"var(--text2)",
                textTransform:"uppercase", letterSpacing:".08em", marginBottom:12 }}>
                Active Agents
              </div>
              <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
                {agents.map(a => {
                  const accent = AGENT_ACCENTS[a.agent_id] || "var(--accent)";
                  return (
                    <div key={a.agent_id} style={{ display:"flex", alignItems:"center", gap:10,
                      padding:"8px 10px", borderRadius:8, background:"var(--bg2)",
                      border:`1px solid ${accent}22` }}>
                      <div style={{ width:28, height:28, borderRadius:6, background:`${accent}22`,
                        border:`1px solid ${accent}44`, display:"flex", alignItems:"center",
                        justifyContent:"center", fontSize:14, flexShrink:0 }}>
                        {a.icon}
                      </div>
                      <div style={{ flex:1, minWidth:0 }}>
                        <div style={{ fontSize:12, fontWeight:600, color:"var(--text)" }}>{a.name}</div>
                        <div style={{ fontSize:10, fontFamily:"var(--font-mono)", color:"var(--text3)" }}>
                          temp:{a.temperature}
                        </div>
                      </div>
                      <div style={{ width:6, height:6, borderRadius:"50%", background:accent, flexShrink:0 }}/>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ── AGENTS TAB ── */}
      {tab === "agents" && (
        <div style={{ maxWidth:960, margin:"0 auto", padding:24 }}>
          <h2 className="section-title">Agent Hub</h2>
          <p className="section-sub">Configure built-in agents or spin up custom ones with their own persona, instructions, and tool access.</p>

          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(280px,1fr))", gap:16, marginBottom:28 }}>
            {agents.map(a => {
              const accent = AGENT_ACCENTS[a.agent_id] || "var(--accent)";
              return (
                <div key={a.agent_id} className="agent-card" style={{ "--card-accent": accent }}>
                  <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:12 }}>
                    <div style={{ width:44, height:44, borderRadius:10, background:`${accent}18`,
                      border:`1px solid ${accent}44`, display:"flex", alignItems:"center",
                      justifyContent:"center", fontSize:22 }}>
                      {a.icon}
                    </div>
                    <Chip type={a.builtin ? "status" : "route"}>{a.builtin ? "built-in" : "custom"}</Chip>
                  </div>
                  <div style={{ fontSize:15, fontWeight:700, marginBottom:4 }}>{a.name}</div>
                  <div style={{ fontSize:13, color:"var(--text2)", lineHeight:1.5, marginBottom:14 }}>{a.description}</div>
                  <div style={{ display:"flex", gap:8, flexWrap:"wrap" }}>
                    <Chip type="rag_context">temp {a.temperature}</Chip>
                    <Chip type="status">session memory</Chip>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="card">
            <div style={{ fontSize:16, fontWeight:700, marginBottom:16 }}>⊕ Create Custom Agent</div>
            <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:12, marginBottom:12 }}>
              <div>
                <span className="label">Agent Name</span>
                <input className="inp" placeholder="e.g. Legal Assistant"
                  value={newAgent.name} onChange={e=>setNewAgent(p=>({...p, name:e.target.value}))}/>
              </div>
              <div>
                <span className="label">Description</span>
                <input className="inp" placeholder="What does this agent do?"
                  value={newAgent.description} onChange={e=>setNewAgent(p=>({...p, description:e.target.value}))}/>
              </div>
            </div>
            <div style={{ marginBottom:12 }}>
              <span className="label">System Prompt</span>
              <textarea className="textarea-inp" rows={4}
                placeholder="You are a Legal Assistant specialising in contract analysis. Always cite relevant laws..."
                value={newAgent.system_prompt}
                onChange={e=>setNewAgent(p=>({...p, system_prompt:e.target.value}))}/>
            </div>
            <div style={{ display:"flex", alignItems:"center", gap:16, marginBottom:18 }}>
              <span className="label" style={{ margin:0, whiteSpace:"nowrap" }}>
                Temperature: <span style={{ color:"var(--accent)", fontFamily:"var(--font-mono)" }}>{newAgent.temperature}</span>
              </span>
              <input type="range" min={0} max={1} step={0.1} value={newAgent.temperature}
                onChange={e=>setNewAgent(p=>({...p, temperature:parseFloat(e.target.value)}))}
                style={{ flex:1, accentColor:"var(--accent)" }}/>
              <span style={{ fontSize:11, color:"var(--text3)", fontFamily:"var(--font-mono)", whiteSpace:"nowrap" }}>
                {newAgent.temperature < 0.4 ? "precise" : newAgent.temperature < 0.7 ? "balanced" : "creative"}
              </span>
            </div>
            <button className="primary-btn" onClick={()=>{
              if(!newAgent.name) return;
              const agent = {
                agent_id: newAgent.name.toLowerCase().replace(/\s+/g,"_"),
                name:newAgent.name, description:newAgent.description, icon:"🎭",
                temperature:newAgent.temperature, system_prompt:newAgent.system_prompt, builtin:false
              };
              setAgents(p=>[...p,agent]); setCustomAgents(p=>[...p,agent]);
              setNewAgent({name:"",description:"",system_prompt:"",temperature:0.7});
            }}>Create Agent</button>
          </div>

          {customAgents.length > 0 && (
            <div style={{ marginTop:20 }}>
              <div style={{ fontSize:13, fontWeight:600, color:"var(--text2)",
                textTransform:"uppercase", letterSpacing:".06em", marginBottom:12 }}>
                Your Custom Agents
              </div>
              <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(260px,1fr))", gap:12 }}>
                {customAgents.map(a => (
                  <div key={a.agent_id} className="agent-card" style={{ "--card-accent":"var(--pink)" }}>
                    <div style={{ display:"flex", justifyContent:"space-between", marginBottom:10 }}>
                      <span style={{ fontSize:22 }}>🎭</span>
                      <button className="ghost-btn" style={{ fontSize:11, color:"var(--red)" }}
                        onClick={()=>{setAgents(p=>p.filter(x=>x.agent_id!==a.agent_id));
                          setCustomAgents(p=>p.filter(x=>x.agent_id!==a.agent_id));}}>
                        Remove
                      </button>
                    </div>
                    <div style={{ fontWeight:700, fontSize:14, marginBottom:4 }}>{a.name}</div>
                    <div style={{ fontSize:12, color:"var(--text2)", lineHeight:1.5 }}>
                      {a.system_prompt?.slice(0,120)}...
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── RAG TAB ── */}
      {tab === "rag" && (
        <div style={{ maxWidth:860, margin:"0 auto", padding:24 }}>
          <h2 className="section-title">Knowledge Base</h2>
          <p className="section-sub">Upload documents. Agents automatically retrieve relevant chunks and inject them into their context before answering.</p>

          {/* Pipeline */}
          <div className="card" style={{ marginBottom:20, overflowX:"auto" }}>
            <div className="label">RAG Pipeline</div>
            <div style={{ display:"flex", alignItems:"center", gap:6, paddingBottom:4 }}>
              {[
                {l:"Document",   c:"#5a5a72", bg:"#1a1a24"},
                {l:"→", arrow:true},
                {l:"Chunker",    c:"#fbbf24", bg:"#2a1f10"},
                {l:"→", arrow:true},
                {l:"Embedder",   c:"#60a5fa", bg:"#101a2a"},
                {l:"→", arrow:true},
                {l:"ChromaDB",   c:"#c084fc", bg:"#1e1028"},
                {l:"→", arrow:true},
                {l:"Query→Match",c:"#2dd4bf", bg:"#0f1e1e"},
                {l:"→", arrow:true},
                {l:"Inject",     c:"#3ecf8e", bg:"#0f2018"},
              ].map((s,i)=>s.arrow
                ? <span key={i} style={{color:"var(--text3)"}}>→</span>
                : <div key={i} className="pipeline-step"
                    style={{background:s.bg, border:`1px solid ${s.c}44`, color:s.c}}>
                    {s.l}
                  </div>
              )}
            </div>
          </div>

          <div className="card" style={{ marginBottom:20 }}>
            <div className="label">Upload Document</div>
            <div style={{ border:"2px dashed var(--border2)", borderRadius:10, padding:40,
              textAlign:"center", marginBottom:16, background:"var(--bg2)" }}>
              <div style={{ fontSize:36, marginBottom:12 }}>◎</div>
              <div style={{ fontSize:14, color:"var(--text2)", marginBottom:16 }}>
                Drop a .txt, .md, or .json file here
              </div>
              <input type="file" accept=".txt,.md,.json" style={{display:"none"}} id="file-upload"
                onChange={e=>{
                  const file=e.target.files[0];
                  if(file){setDocs(p=>[...p,{name:file.name,size:file.size,chunks:Math.ceil(file.size/400),ts:Date.now()}]);
                    e.target.value="";}
                }}/>
              <label htmlFor="file-upload" className="primary-btn" style={{cursor:"pointer",display:"inline-block"}}>
                Choose File
              </label>
            </div>
            <span className="label">Or paste text</span>
            <textarea className="textarea-inp" rows={4} id="paste-area"
              placeholder="Paste any text here to add to the knowledge base..."/>
            <button className="primary-btn" style={{ marginTop:12 }} onClick={()=>{
              const t=document.getElementById("paste-area").value.trim();
              if(!t) return;
              setDocs(p=>[...p,{name:"Pasted text",size:t.length,chunks:Math.ceil(t.length/400),ts:Date.now()}]);
              document.getElementById("paste-area").value="";
            }}>Ingest Text</button>
          </div>

          {docs.length > 0 && (
            <div className="card">
              <div className="label">Ingested Documents ({docs.length})</div>
              {docs.map((d,i) => (
                <div key={i} style={{ display:"flex", justifyContent:"space-between", alignItems:"center",
                  padding:"10px 0", borderBottom:"1px solid var(--border)" }}>
                  <div style={{ display:"flex", alignItems:"center", gap:10 }}>
                    <span style={{ fontSize:20 }}>◎</span>
                    <div>
                      <div style={{ fontSize:13, fontWeight:600 }}>{d.name}</div>
                      <div style={{ fontSize:11, fontFamily:"var(--font-mono)", color:"var(--text3)" }}>
                        {d.chunks} chunks · {(d.size/1024).toFixed(1)}KB
                      </div>
                    </div>
                  </div>
                  <div style={{ display:"flex", gap:8, alignItems:"center" }}>
                    <Chip type="rag_context">{d.chunks} chunks</Chip>
                    <Chip type="status">indexed</Chip>
                    <button className="ghost-btn" style={{ fontSize:11, color:"var(--red)" }}
                      onClick={()=>setDocs(p=>p.filter((_,j)=>j!==i))}>Remove</button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ── PLUGINS TAB ── */}
      {tab === "plugins" && (
        <div style={{ maxWidth:860, margin:"0 auto", padding:24 }}>
          <h2 className="section-title">Plugin Registry</h2>
          <p className="section-sub">Dynamically registered tools that agents can invoke. Agents call plugins by name; the registry routes to the right function.</p>

          <div style={{ display:"grid", gridTemplateColumns:"repeat(auto-fit,minmax(200px,1fr))", gap:14, marginBottom:24 }}>
            {plugins.map(p => {
              const meta = {
                weather:    { icon:"◉", color:"#60a5fa", bg:"#101a2a" },
                calculator: { icon:"⊞", color:"#fbbf24", bg:"#2a1f10" },
                code_exec:  { icon:"⬡", color:"#2dd4bf", bg:"#0f1e1e" },
                summarizer: { icon:"◈", color:"#c084fc", bg:"#1e1028" },
              }[p.name] || { icon:"⊕", color:"var(--accent)", bg:"var(--bg2)" };
              return (
                <div key={p.name} style={{ background:meta.bg, border:`1px solid ${meta.color}44`,
                  borderRadius:12, padding:16, position:"relative", overflow:"hidden", transition:"all .2s" }}>
                  <div style={{ position:"absolute", top:-20, right:-20, fontSize:80, opacity:.06, fontFamily:"var(--font-mono)" }}>
                    {meta.icon}
                  </div>
                  <div style={{ fontSize:24, marginBottom:10, color:meta.color, fontFamily:"var(--font-mono)" }}>
                    {meta.icon}
                  </div>
                  <div style={{ fontWeight:700, fontSize:14, marginBottom:4 }}>{p.name}</div>
                  <div style={{ fontSize:12, color:"var(--text2)", lineHeight:1.5, marginBottom:12 }}>{p.description}</div>
                  <Chip type={p.custom?"route":"status"}>{p.custom?"custom":"built-in"}</Chip>
                </div>
              );
            })}
          </div>

          <div className="card">
            <div style={{ fontSize:16, fontWeight:700, marginBottom:16 }}>⊕ Register Custom Plugin</div>
            <div style={{ display:"grid", gridTemplateColumns:"1fr 1fr", gap:12, marginBottom:14 }}>
              <div>
                <span className="label">Plugin Name</span>
                <input className="inp" placeholder="e.g. crm_lookup"
                  value={newPlugin.name} onChange={e=>setNewPlugin(p=>({...p,name:e.target.value}))}/>
              </div>
              <div>
                <span className="label">Description</span>
                <input className="inp" placeholder="What does this plugin do?"
                  value={newPlugin.description} onChange={e=>setNewPlugin(p=>({...p,description:e.target.value}))}/>
              </div>
            </div>
            <button className="primary-btn" onClick={()=>{
              if(!newPlugin.name) return;
              setPlugins(p=>[...p,{...newPlugin,custom:true}]);
              setNewPlugin({name:"",description:""});
            }}>Register Plugin</button>
          </div>
        </div>
      )}

      {/* ── ARCH TAB ── */}
      {tab === "arch" && (
        <div style={{ maxWidth:960, margin:"0 auto", padding:24 }}>
          <h2 className="section-title">System Architecture</h2>
          <p className="section-sub">All six layers of the platform — their responsibilities, components, and how data flows between them.</p>

          {[
            {
              layer:"Hooks — Middleware",   color:"#c084fc", icon:"⬡",
              description:"Every message passes through three hooks before and after agent processing. Pre-hook handles auth, rate limiting (20 req/min), and input filtering. The router classifies intent and selects an agent. Post-hook writes audit trails.",
              parts:[
                {name:"Pre-hook",       detail:"Auth, rate limiting, content filter, input logging"},
                {name:"Request Router", detail:"Intent classification → agent selection"},
                {name:"Post-hook",      detail:"Audit trail, response formatting, cache update"},
              ],
              code:`class PreHook:\n    def run(self, text, session_id):\n        # 1. Rate limit  2. Content filter  3. Log\n        return {"blocked": False, "rate_remaining": 18}\n\nclass RequestRouter:\n    def route(self, text):\n        return {"agent": "coding_agent", "intent": "code"}`,
            },
            {
              layer:"Agents — Multi-Agent Orchestration",  color:"#60a5fa", icon:"◈",
              description:"The Orchestrator receives routed requests and delegates to specialized sub-agents. Each agent has its own system prompt, tool access, and temperature setting.",
              parts:[
                {name:"Orchestrator",    detail:"Plans tasks, delegates, synthesizes"},
                {name:"Research Agent",  detail:"Web search + RAG retrieval, citation-focused"},
                {name:"Coding Agent",    detail:"Code generation, debugging, explanation"},
                {name:"Data Agent",      detail:"Analysis, statistics, visualization suggestions"},
                {name:"Custom Agent",    detail:"User-defined persona, instructions, tool access"},
              ],
              code:`class BaseAgent:\n    async def run(self, text, history, context):\n        async for event in _ollama_stream(system, messages, tools):\n            yield event  # stream tokens + tool_calls`,
            },
            {
              layer:"RAG — Retrieval-Augmented Generation", color:"#fbbf24", icon:"◎",
              description:"Documents are chunked, embedded into vectors, and stored in ChromaDB. Before every agent call, the query is embedded and the top-k similar chunks are prepended to the system prompt.",
              parts:[
                {name:"Chunker",          detail:"400-char overlapping windows, 80-char overlap"},
                {name:"Embedding Service",detail:"128-dim hash vectors (swap for real embeddings)"},
                {name:"Vector Store",     detail:"ChromaDB with cosine similarity search"},
                {name:"Context Injector", detail:"Top-k chunks prepended to system prompt"},
              ],
              code:`class RAGEngine:\n    def ingest(self, text, metadata):\n        chunks = self._chunk(text)   # 400-char windows\n        embeddings = [self._embed(c) for c in chunks]\n        self._col.add(ids, chunks, embeddings)\n\n    def query(self, text, k=3):\n        return self._col.query(self._embed(text), n_results=k)`,
            },
            {
              layer:"MCP — Model Context Protocol",  color:"#3ecf8e", icon:"⊕",
              description:"Standard for giving AI access to external tools. Each MCP server exposes tools via structured calls. Agents call tools by name; MCPManager routes to the right server.",
              parts:[
                {name:"FileSystem MCP",  detail:"read_file, write_file, list_directory"},
                {name:"WebSearch MCP",   detail:"web_search (add Brave/Tavily API key)"},
                {name:"Database MCP",    detail:"query_db (SELECT only), describe_db"},
                {name:"CustomAPI MCP",   detail:"call_api (user-registered REST endpoints)"},
              ],
              code:`class MCPManager:\n    async def call_tool(self, tool_name, args):\n        server = self._tool_index[tool_name]\n        return await server.call(tool_name, args)`,
            },
            {
              layer:"Plugins — Dynamic Tool Registry",  color:"#f472b6", icon:"⬢",
              description:"In-process callable tools registered at runtime. Unlike MCP (external processes), plugins run as Python functions. Users register new ones via a REST endpoint.",
              parts:[
                {name:"Weather Plugin",    detail:"OpenWeather API → city weather data"},
                {name:"Calculator Plugin", detail:"AST-safe math eval (no eval() injection)"},
                {name:"Code Exec Plugin",  detail:"Restricted exec() sandbox"},
                {name:"Summarizer Plugin", detail:"Extractive summarization"},
                {name:"Custom Plugins",    detail:"User-registered via /plugins/register"},
              ],
              code:`def calculator_plugin(query, **kwargs):\n    # AST parsing — NEVER raw eval()\n    tree = ast.parse(query, mode="eval")\n    return {"result": safe_eval(tree.body)}\n\nclass PluginRegistry:\n    def call(self, name, args):\n        return self._plugins[name]["fn"](**args)`,
            },
          ].map((layer, i) => (
            <div key={i} className="card" style={{ marginBottom:16, borderLeft:`3px solid ${layer.color}` }}>
              <div style={{ display:"flex", alignItems:"center", gap:12, marginBottom:12 }}>
                <span style={{ fontSize:22, fontFamily:"var(--font-mono)", color:layer.color }}>{layer.icon}</span>
                <div>
                  <div style={{ fontSize:15, fontWeight:700 }}>Layer {i+1} — {layer.layer}</div>
                </div>
                <span className="chip" style={{ marginLeft:"auto",
                  background:`${layer.color}18`, border:`1px solid ${layer.color}44`, color:layer.color }}>
                  <span className="chip-dot" style={{ background:layer.color }}/>
                  {layer.parts.length} components
                </span>
              </div>
              <p style={{ fontSize:13, color:"var(--text2)", lineHeight:1.7, marginBottom:14 }}>
                {layer.description}
              </p>
              <div style={{ display:"flex", gap:8, flexWrap:"wrap", marginBottom:14 }}>
                {layer.parts.map((p,j) => (
                  <div key={j} style={{ background:"var(--bg2)", border:"1px solid var(--border)",
                    borderRadius:8, padding:"7px 12px" }}>
                    <div style={{ fontSize:12, fontWeight:600 }}>{p.name}</div>
                    <div style={{ fontSize:11, color:"var(--text3)", marginTop:2 }}>{p.detail}</div>
                  </div>
                ))}
              </div>
              <details>
                <summary style={{ fontSize:12, color:"var(--text3)", cursor:"pointer",
                  fontFamily:"var(--font-mono)", display:"flex", alignItems:"center", gap:6 }}>
                  <span style={{ color:layer.color }}>▸</span> view code excerpt
                </summary>
                <pre style={{ marginTop:12, background:"var(--bg2)", border:"1px solid var(--border)",
                  borderLeft:`3px solid ${layer.color}66`,
                  borderRadius:8, padding:"14px 16px", fontSize:12, lineHeight:1.8,
                  color:"var(--text)", overflowX:"auto" }}>
                  {layer.code}
                </pre>
              </details>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
JSXEOF

# ─── 17. Python deps ────────────────────────────────────────────────
echo ""
echo "▶ Installing Python dependencies..."
cd "$PLATFORM_DIR/backend"
pip3 install --user -r requirements.txt --quiet

# ─── 18. Node deps ──────────────────────────────────────────────────
echo "▶ Installing Node dependencies (this takes ~1-2 min)..."
cd "$PLATFORM_DIR/frontend"
npm install --legacy-peer-deps --silent

# ─── 19. Launch ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║               ✅ Setup Complete!                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  To START the platform:                          ║"
echo "║                                                  ║"
echo "║  Terminal 1 (backend):                           ║"
echo "║    cd ~/ai-platform/backend                      ║"
echo "║    uvicorn main:app --reload --port 8000         ║"
echo "║                                                  ║"
echo "║  Terminal 2 (frontend):                          ║"
echo "║    cd ~/ai-platform/frontend                     ║"
echo "║    npm start                                     ║"
echo "║                                                  ║"
echo "║  Open: http://localhost:3000                     ║"
echo "║                                                  ║"
echo "║  Ollama model: $OLLAMA_MODEL                     ║"
echo "║  Change model: export OLLAMA_MODEL=mistral       ║"
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
