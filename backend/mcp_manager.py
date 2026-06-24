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
