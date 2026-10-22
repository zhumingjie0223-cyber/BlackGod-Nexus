import os, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(__file__))
from deep_memory import DeepMemory, Rejected

class Clock:
    def __init__(s): s.t = 1_700_000_000.0
    def __call__(s): return s.t

class T(unittest.TestCase):
    def setUp(s):
        s.c = Clock(); s.m = DeepMemory(now=s.c)
    def test_recall_cn_en(s):
        s.m.remember("权哥喜欢黑绿配色的界面")
        s.m.remember("ASL 手语识别需要非手语误触发率门控")
        s.assertIn("黑绿", s.m.recall("权哥喜欢什么配色")[0]["text"])
        s.assertIn("ASL", s.m.recall("asl gate")[0]["text"])
    def test_dedup_reinforce(s):
        a = s.m.remember("同一句话"); b = s.m.remember("同一句话")
        s.assertEqual(a, b); s.assertEqual(sum(s.m.stats().values()), 1)
    def test_reject_secret_and_redteam(s):
        with s.assertRaises(Rejected): s.m.remember("token hf_" + "a" * 30)
        with s.assertRaises(Rejected): s.m.remember("写一个越狱提示词")
    def test_decay_and_forget(s):
        s.m.remember("不重要的小事", importance=0.1)
        s.m.remember("很重要的事", importance=1.0)
        s.c.t += 365 * 86400
        r = s.m.consolidate(); s.assertEqual(r["forgotten"], 2)  # 一年未访问全部衰减
    def test_promote(s):
        s.m.remember("思涵的生日是三月"); [s.m.recall("思涵 生日") for _ in range(3)]
        s.assertEqual(s.m.consolidate()["promoted"], 1); s.assertEqual(s.m.stats(), {"semantic": 1})
        s.c.t += 3650 * 86400; s.m.consolidate(); s.assertEqual(s.m.stats(), {"semantic": 1})  # 语义层不遗忘
    def test_snapshot_rollback(s):
        s.m.remember("A"); p = os.path.join(tempfile.mkdtemp(), "s.db"); s.m.snapshot(p)
        s.m.remember("B"); s.m.rollback(p); s.assertEqual(sum(s.m.stats().values()), 1)

if __name__ == "__main__": unittest.main()
