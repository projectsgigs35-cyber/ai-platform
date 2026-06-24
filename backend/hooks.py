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
