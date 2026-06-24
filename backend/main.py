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
