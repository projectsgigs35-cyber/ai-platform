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
OLLAMA_MODEL    = os.environ.get("OLLAMA_MODEL", "phi3:mini")


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
