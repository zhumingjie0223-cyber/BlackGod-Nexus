"""唯一进化学习 dry-run 闭环（box 上，用玩具模型代替 v5，不碰 Mac 权重）。
笔记 → 问答 → 安全过滤 → 双源交叉验证 → 门控题去重 → 批次(≥min_batch，含~15%回放)
→ 门前评测 → 单矩阵 SGD+梯度裁剪 → 门后评测 → 退步即回滚。"""
import hashlib, re
import numpy as np

SECRET = re.compile(r"(hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|PRIVATE KEY|api[_-]?key\s*[:=])", re.I)
BLOCK = re.compile(r"(redteam|越狱|jailbreak|免杀|破解|shellcode)", re.I)
norm = lambda s: re.sub(r"\W+", "", s.lower())

def notes_to_qa(notes):
    """笔记格式 {'q','a','source'}；同一问题聚合各来源的答案。"""
    agg = {}
    for n in notes:
        item = agg.setdefault(norm(n["q"]), {"q": n["q"], "answers": {}})
        item["answers"].setdefault(norm(n["a"]), (n["a"], set()))[1].add(n["source"])
    return agg

def build_batch(notes, gate_questions, replay, min_batch=200, replay_ratio=0.15, min_sources=2):
    gate = {norm(g) for g in gate_questions}
    rep = {"secret": 0, "redteam": 0, "unverified": 0, "gate_overlap": 0}
    out = []
    for key, item in notes_to_qa(notes).items():
        best_a, srcs = max(item["answers"].values(), key=lambda x: len(x[1]))
        txt = item["q"] + best_a
        if SECRET.search(txt): rep["secret"] += 1; continue
        if BLOCK.search(txt): rep["redteam"] += 1; continue
        if len(srcs) < min_sources: rep["unverified"] += 1; continue
        if key in gate: rep["gate_overlap"] += 1; continue
        out.append({"q": item["q"], "a": best_a, "sources": sorted(srcs)})
    n_rep = min(len(replay), int(round(len(out) * replay_ratio / (1 - replay_ratio))))
    rep.update(fresh=len(out), replay=n_rep, ready=len(out) >= min_batch)
    return out + list(replay[:n_rep]), rep

class ToyModel:
    """玩具模型：哈希嵌入 → 一块矩阵 W（代表某层 MLP down_proj）→ 给答案打分。"""
    def __init__(s, dim=64, seed=0):
        s.dim = dim; s.W = np.random.default_rng(seed).normal(0, .05, (dim, dim))
    def emb(s, t):
        v = np.zeros(s.dim)
        for tok in re.findall(r"\w", t.lower()):
            v[int(hashlib.md5(tok.encode()).hexdigest(), 16) % s.dim] += 1
        return v / (np.linalg.norm(v) or 1)
    def score(s, q, a): return float(s.emb(a) @ s.W @ s.emb(q))
    def answer(s, q, choices): return max(choices, key=lambda c: s.score(q, c))

def evaluate(model, gate):
    return [model.answer(g["q"], g["choices"]) == g["gold"] for g in gate]

def sgd_single_matrix(model, batch, lr=0.5, clip=1.0, epochs=3):
    for _ in range(epochs):
        G = sum(np.outer(model.emb(ex["a"]), model.emb(ex["q"])) for ex in batch) / max(1, len(batch))
        n = np.linalg.norm(G)
        if n > clip: G = G * clip / n
        model.W += lr * G

def run_round(model, batch, gate_sets, soft_drop=0.02, **kw):
    """门前评测 → 单矩阵更新 → 门后评测；出现负翻转或软分下降超阈值即回滚。"""
    base = {k: evaluate(model, v) for k, v in gate_sets.items()}
    backup = model.W.copy()
    sgd_single_matrix(model, batch, **kw)
    after = {k: evaluate(model, v) for k, v in gate_sets.items()}
    flips = {k: sum(b and not a for b, a in zip(base[k], after[k])) for k in gate_sets}
    soft = {k: (sum(after[k]) - sum(base[k])) / max(1, len(base[k])) for k in gate_sets}
    ok = all(v == 0 for v in flips.values()) and all(v >= -soft_drop for v in soft.values())
    if not ok: model.W = backup
    return {"verdict": "PASS" if ok else "FAIL", "negative_flips": flips, "soft_delta": soft,
            "rolled_back": not ok, "w_delta_norm": float(np.linalg.norm(model.W - backup))}
