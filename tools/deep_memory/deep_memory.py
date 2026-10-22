"""深度记忆 v0：三层记忆（工作/情节/语义）+ 巩固 + 衰减 + 检索 + 快照回滚。
纯标准库、SQLite 落盘；不碰模型权重。密钥/红队内容在写入前拦截。"""
import json, math, re, sqlite3, time, shutil, hashlib
from collections import Counter

SECRET_PAT = re.compile(r"(hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key\s*[:=]\s*\S{12,}|secret\s*[:=]\s*\S{12,})", re.I)
BLOCK_PAT = re.compile(r"(redteam|越狱|jailbreak|免杀|破解|shellcode|exec-shell)", re.I)

def tokens(text):
    t = text.lower()
    words = re.findall(r"[a-z0-9]+", t)
    cjk = re.findall(r"[\u4e00-\u9fff]", t)
    return words + [a + b for a, b in zip(cjk, cjk[1:])] + cjk

class Rejected(ValueError):
    pass

class DeepMemory:
    def __init__(self, path=":memory:", half_life_days=30.0, now=time.time):
        self.path, self.now, self.hl = path, now, half_life_days * 86400
        self.db = sqlite3.connect(path)
        self.db.execute("""CREATE TABLE IF NOT EXISTS mem(id INTEGER PRIMARY KEY, layer TEXT, text TEXT,
            importance REAL, created REAL, last_access REAL, hits INTEGER DEFAULT 0, digest TEXT UNIQUE, meta TEXT)""")
        self.db.commit()

    # ---- 写入 ----
    def remember(self, text, importance=0.5, layer="episodic", meta=None):
        if SECRET_PAT.search(text):
            raise Rejected("含疑似密钥，拒绝写入")
        if BLOCK_PAT.search(text):
            raise Rejected("红队/破解相关内容，拒绝写入")
        d = hashlib.sha256(text.strip().encode()).hexdigest()
        t = self.now()
        cur = self.db.execute("SELECT id FROM mem WHERE digest=?", (d,)).fetchone()
        if cur:  # 重复即强化
            self.db.execute("UPDATE mem SET hits=hits+1, importance=MIN(1, importance+0.1), last_access=? WHERE id=?", (t, cur[0]))
            self.db.commit(); return cur[0]
        c = self.db.execute("INSERT INTO mem(layer,text,importance,created,last_access,digest,meta) VALUES(?,?,?,?,?,?,?)",
                            (layer, text, float(importance), t, t, d, json.dumps(meta or {}, ensure_ascii=False)))
        self.db.commit(); return c.lastrowid

    # ---- 强度 = 重要度 × 时间衰减 × (1+log 命中) ----
    def strength(self, importance, last_access, hits):
        age = max(0.0, self.now() - last_access)
        return importance * math.pow(0.5, age / self.hl) * (1 + math.log1p(hits))

    # ---- 检索：BM25 风格相关度 × 强度 ----
    def recall(self, query, k=5, layers=None):
        rows = self.db.execute("SELECT id,layer,text,importance,last_access,hits FROM mem").fetchall()
        if layers: rows = [r for r in rows if r[1] in layers]
        if not rows: return []
        q = tokens(query); docs = [Counter(tokens(r[2])) for r in rows]
        N = len(docs); avg = sum(sum(d.values()) for d in docs) / N or 1
        df = Counter(w for d in docs for w in set(d))
        out = []
        for r, d in zip(rows, docs):
            L = sum(d.values()) or 1; s = 0.0
            for w in set(q):
                if w in d:
                    idf = math.log(1 + (N - df[w] + .5) / (df[w] + .5))
                    s += idf * d[w] * 2.2 / (d[w] + 1.2 * (.25 + .75 * L / avg))
            if s > 0:
                out.append((s * (0.5 + self.strength(r[3], r[4], r[5])), r))
        out.sort(key=lambda x: -x[0]); top = out[:k]; t = self.now()
        for _, r in top:
            self.db.execute("UPDATE mem SET hits=hits+1,last_access=? WHERE id=?", (t, r[0]))
        self.db.commit()
        return [{"id": r[0], "layer": r[1], "text": r[2], "score": round(s, 4)} for s, r in top]

    # ---- 巩固：常被想起/重要的情节记忆升为语义记忆；弱记忆遗忘 ----
    def consolidate(self, promote_at=0.8, forget_below=0.05):
        promoted = forgotten = 0
        for i, layer, imp, la, hits in self.db.execute("SELECT id,layer,importance,last_access,hits FROM mem").fetchall():
            st = self.strength(imp, la, hits)
            if layer == "episodic" and (st >= promote_at or hits >= 3):
                self.db.execute("UPDATE mem SET layer='semantic' WHERE id=?", (i,)); promoted += 1
            elif layer != "semantic" and st < forget_below:
                self.db.execute("DELETE FROM mem WHERE id=?", (i,)); forgotten += 1
        self.db.commit()
        return {"promoted": promoted, "forgotten": forgotten}

    def stats(self):
        return dict(self.db.execute("SELECT layer,COUNT(*) FROM mem GROUP BY layer").fetchall())

    # ---- 快照/回滚（整库可回退）----
    def snapshot(self, dest):
        b = sqlite3.connect(dest); self.db.backup(b); b.close(); return dest

    def rollback(self, src):
        b = sqlite3.connect(src); b.backup(self.db); b.close()
