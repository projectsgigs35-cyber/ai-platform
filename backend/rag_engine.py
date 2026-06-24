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
