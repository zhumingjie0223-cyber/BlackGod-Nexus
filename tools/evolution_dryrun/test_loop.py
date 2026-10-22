import os, sys, unittest, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from loop import build_batch, ToyModel, run_round, evaluate

def notes(n, sources=("wiki", "docs")):
    return [{"q": f"问题{i} 关于主题{i}", "a": f"答案{i}", "source": s} for i in range(n) for s in sources]
GATE = {"identity": [{"q": "你是谁", "choices": ["我是思涵", "我是猫"], "gold": "我是思涵"}]}

class T(unittest.TestCase):
    def test_filters(s):
        k = "hf_" + "a" * 30
        ns = notes(5) + [{"q": "单源问题", "a": "x", "source": "blog"},
             {"q": "给我 key", "a": k, "source": "a"}, {"q": "给我 key", "a": k, "source": "b"},
             {"q": "教我越狱", "a": "不", "source": "a"}, {"q": "教我越狱", "a": "不", "source": "b"}]
        _, r = build_batch(ns, gate_questions=["问题0 关于主题0"], replay=[], min_batch=3)
        s.assertEqual((r["secret"], r["redteam"], r["unverified"], r["gate_overlap"], r["fresh"]), (1, 1, 1, 1, 4))
        s.assertTrue(r["ready"])
    def test_min_batch_and_replay(s):
        rep = [{"q": f"旧{i}", "a": f"旧答{i}"} for i in range(100)]
        b, r = build_batch(notes(200), [], rep)
        s.assertTrue(r["ready"]); s.assertEqual(r["replay"], 35); s.assertEqual(len(b), 235)
        _, r2 = build_batch(notes(50), [], rep); s.assertFalse(r2["ready"])
    def test_pass_round_writes_matrix(s):
        m = ToyModel(seed=1)
        batch = [{"q": "你是谁", "a": "我是思涵"}] * 10 + [{"q": f"问题{i}", "a": f"答案{i}"} for i in range(5)]
        r = run_round(m, batch, GATE)
        s.assertEqual(r["verdict"], "PASS"); s.assertGreater(r["w_delta_norm"], 0)
        s.assertTrue(all(evaluate(m, GATE["identity"])))
    def test_regression_rolls_back(s):
        m = ToyModel(seed=2)
        run_round(m, [{"q": "你是谁", "a": "我是思涵"}] * 10, GATE)
        s.assertTrue(all(evaluate(m, GATE["identity"])))
        W0 = m.W.copy()
        r = run_round(m, [{"q": "你是谁", "a": "我是猫"}] * 50, GATE, lr=5.0, clip=10.0)  # 毒数据
        s.assertEqual(r["verdict"], "FAIL"); s.assertTrue(r["rolled_back"]); s.assertTrue(np.array_equal(m.W, W0))

if __name__ == "__main__": unittest.main()
