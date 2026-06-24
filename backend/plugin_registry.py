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
