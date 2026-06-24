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
