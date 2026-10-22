"""技能市场自测。密钥对在运行时生成到临时目录，不入库。运行: python3 -m unittest -v test_skill_market"""
import json, multiprocessing as mp, os, shutil, subprocess, sys, tempfile, threading, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skill_market as sm
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

EH = {"testset_lock_sha256": "a" * 64, "gate_config_sha256": "b" * 64, "gate_report_sha256": "c" * 64}
CAPS = [{"id": "skill.storage.own"}, {"id": "network.fetch", "domains": ["api.example.com"]}]
def _w(p, mode, s):
    with open(p, mode) as f:
        f.write(s)


gate_pass = lambda m, d: sm.PASS


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="skm-")
        self.key = Ed25519PrivateKey.generate()
        self.other = Ed25519PrivateKey.generate()
        self.store = sm.SkillStore(os.path.join(self.tmp, "store"), [self.key.public_key()])

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make(self, ver="1.0.0", caps=CAPS, eh=EH, key=None, name=None, extra_files=None, pid="demo.skill"):
        key = key or self.key
        d = os.path.join(self.tmp, name or f"pkg-{ver}")
        os.makedirs(os.path.join(d, "steps"))
        _w(os.path.join(d, "skill.json"), "w", json.dumps({"name": "demo", "v": ver}))
        _w(os.path.join(d, "steps", "1.md"), "w", "step one\n")
        for p, c in (extra_files or {}).items():
            _w(os.path.join(d, p), "w", c)
        m = sm.build_manifest(d, pack_id=pid, version=ver, group="skills", capabilities=caps,
                              eval_hash=eh, author_pub=key.public_key())
        sm.write_manifest(d, sm.sign_manifest(m, key))
        return d

    def resign(self, d, mutate):
        m = json.loads(sm._rb(os.path.join(d, "manifest.json")))
        m.pop("signature"); mutate(m)
        sm.write_manifest(d, sm.sign_manifest(m, self.key))

    def act(self, d, eh=EH, gates=gate_pass):
        return self.store.activate(d, expected_eval_hash=eh, run_gates=gates)


class T(Base):
    def test_01_normal_pass(self):
        r = self.act(self.make()); self.assertEqual(r.verdict, sm.PASS, r.reason)
        self.assertEqual(self.store.pointer("demo.skill"), {"current": "1.0.0", "previous": None})

    def test_02_tampered_file_fail(self):
        d = self.make(); _w(os.path.join(d, "steps", "1.md"), "a", "x")
        r = self.act(d); self.assertEqual((r.verdict, r.reason), (sm.FAIL, "哈希不符: steps/1.md"))

    def test_03_other_signer_fail(self):
        r = self.act(self.make(key=self.other)); self.assertEqual((r.verdict, r.reason), (sm.FAIL, "签名者不在信任根中"))

    def test_03b_forged_fingerprint_fail(self):
        d = self.make()
        m = json.loads(sm._rb(os.path.join(d, "manifest.json"))); m.pop("signature")
        sm.write_manifest(d, sm.sign_manifest(m, self.other))  # 指纹仍是信任根，签名却是别人
        r = self.act(d); self.assertEqual((r.verdict, r.reason), (sm.FAIL, "签名校验失败"))

    def test_03c_manifest_edit_breaks_sig(self):
        d = self.make(); m = json.loads(sm._rb(os.path.join(d, "manifest.json")))
        m["version"] = "9.9.9"; sm.write_manifest(d, m)
        self.assertEqual(self.act(d).verdict, sm.FAIL)

    def test_04_missing_eval_hash_not_ready(self):
        r = self.act(self.make(eh=None)); self.assertEqual(r.verdict, sm.NOT_READY)
        self.assertIsNone(self.store.pointer("demo.skill")["current"])

    def test_05_eval_hash_mismatch_fail(self):
        r = self.act(self.make(), eh=dict(EH, gate_report_sha256="d" * 64))
        self.assertEqual((r.verdict, r.reason), (sm.FAIL, "eval_hash 不符: gate_report_sha256"))

    def test_06_gate_fail_pointer_unchanged(self):
        self.assertEqual(self.act(self.make("1.0.0")).verdict, sm.PASS)
        before = self.store.pointer("demo.skill")
        for g in (sm.FAIL, sm.NOT_READY):
            r = self.act(self.make("1.1.0", name=f"p-{g}"), gates=lambda m, d, g=g: g)
            self.assertEqual(r.verdict, g)
            self.assertEqual(self.store.pointer("demo.skill"), before)
        self.assertFalse(os.path.exists(self.store.version_dir("demo.skill", "1.1.0")))

    def test_06b_gate_exception_fail(self):
        def boom(m, d): raise RuntimeError("x")
        self.assertEqual(self.act(self.make(), gates=boom).verdict, sm.FAIL)

    def test_07_dangerous_caps_fail(self):
        cases = [[{"id": "shell.exec"}], [{"id": "allowDangerous"}], [{"id": "ui.render", "domains": ["allowDangerous.com"]}],
                 [{"id": "skill.storage.other"}], [{"id": "network.fetch"}], [{"id": "network.fetch", "domains": []}],
                 [{"id": "network.fetch", "domains": ["*.example.com"]}], [{"id": "camera.raw"}],
                 [{"id": "ui.render", "allowDangerous": True}]]
        for i, c in enumerate(cases):
            r = self.act(self.make(caps=c, name=f"cap{i}"))
            self.assertEqual(r.verdict, sm.FAIL, c)
        self.assertNotIn("allowDangerous", sm.ALLOWED_CAPABILITIES)

    def test_08_path_traversal_fail(self):
        for i, bad in enumerate(["../evil", "/etc/passwd", "steps/../../x", "a//b", "C:/x"]):
            d = self.make(name=f"trav{i}")
            self.resign(d, lambda m: m["files"].append({"path": bad, "sha256": "0" * 64, "size": 0}))
            r = self.act(d); self.assertEqual(r.verdict, sm.FAIL, bad); self.assertIn("路径", r.reason)

    def test_09_symlink_fail(self):
        d = self.make(); os.symlink("/etc/hostname", os.path.join(d, "link"))
        r = self.act(d); self.assertEqual(r.verdict, sm.FAIL); self.assertIn("符号链接", r.reason)
        d2 = self.make(name="dirlink"); os.symlink(self.tmp, os.path.join(d2, "steps", "up"))
        self.assertEqual(self.act(d2).verdict, sm.FAIL)

    def test_10_extra_file_fail(self):
        d = self.make(); _w(os.path.join(d, "extra.bin"), "w", "x")
        r = self.act(d); self.assertEqual((r.verdict, r.reason), (sm.FAIL, "多余文件: ['extra.bin']"))

    def test_10b_missing_file_fail(self):
        d = self.make(); os.remove(os.path.join(d, "skill.json"))
        self.assertEqual(self.act(d).reason, "缺文件: ['skill.json']")

    def test_11_rollback(self):
        self.assertEqual(self.act(self.make("1.0.0")).verdict, sm.PASS)
        self.assertEqual(self.act(self.make("1.1.0")).verdict, sm.PASS)
        self.assertEqual(self.store.pointer("demo.skill"), {"current": "1.1.0", "previous": "1.0.0"})
        r = self.store.rollback("demo.skill"); self.assertEqual(r.verdict, sm.PASS)
        self.assertEqual(self.store.pointer("demo.skill"), {"current": "1.0.0", "previous": "1.1.0"})
        self.assertTrue(os.path.isfile(os.path.join(self.store.version_dir("demo.skill", "1.0.0"), "skill.json")))
        self.assertEqual(self.store.rollback("nope").verdict, sm.FAIL)
        log = [json.loads(l) for l in sm._rb(self.store.log_path).decode().splitlines()]
        self.assertEqual([(x["action"], x["verdict"]) for x in log],
                         [("activate", "PASS"), ("activate", "PASS"), ("rollback", "PASS"), ("rollback", "FAIL")])
        self.assertTrue(all({"time", "pack_id", "version", "verdict", "reason"} <= set(x) for x in log))

    def test_12_crash_mid_switch(self):
        self.assertEqual(self.act(self.make("1.0.0")).verdict, sm.PASS)
        d = self.make("1.1.0")
        # 子进程在 os.replace（指针提交点）之前被硬杀，模拟崩溃
        code = ("import os,sys;sys.path.insert(0,%r);import skill_market as sm\n"
                "from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey as P\n"
                "os.replace=lambda *a:os._exit(9)\n"
                "s=sm.SkillStore(%r,[P.from_public_bytes(bytes.fromhex(%r))])\n"
                "s.activate(%r,expected_eval_hash=%r,run_gates=lambda m,d:'PASS')\n") % (
            os.path.dirname(os.path.abspath(sm.__file__)), self.store.root,
            sm.pubkey_raw(self.key.public_key()).hex(), d, EH)
        p = subprocess.run([sys.executable, "-c", code])
        self.assertEqual(p.returncode, 9)
        self.assertEqual(self.store.pointer("demo.skill"), {"current": "1.0.0", "previous": None})
        self.assertEqual([f for f in os.listdir(os.path.join(self.store.root, "pointers")) if f.startswith(".ptr-")] != [], True)  # 临时文件残留但无害
        # 恢复后可正常激活（清理未被引用的残留版本目录）
        self.assertEqual(self.act(d).verdict, sm.PASS)
        self.assertEqual(self.store.pointer("demo.skill"), {"current": "1.1.0", "previous": "1.0.0"})

    def test_13_concurrent_no_half_state(self):
        vers = [f"1.{i}.0" for i in range(8)]
        pkgs = [self.make(v) for v in vers]
        stop = threading.Event(); bad = []
        def reader():
            p = os.path.join(self.store.root, "pointers", "demo.skill.json")
            while not stop.is_set():
                try:
                    x = json.loads(sm._rb(p))
                    if set(x) != {"current", "previous"} or x["current"] not in vers:
                        bad.append(x)
                    elif not os.path.isfile(os.path.join(self.store.version_dir("demo.skill", x["current"]), "skill.json")):
                        bad.append(("dir-missing", x))
                except FileNotFoundError:
                    pass
                except Exception as e:
                    bad.append(repr(e))
        t = threading.Thread(target=reader); t.start()
        with mp.get_context("fork").Pool(4) as pool:
            res = pool.starmap(_proc_activate, [(self.store.root, sm.pubkey_raw(self.key.public_key()), d) for d in pkgs])
        stop.set(); t.join()
        self.assertEqual(sorted(res), ["PASS"] * 8)
        self.assertEqual(bad, [])
        ptr = self.store.pointer("demo.skill")
        self.assertIn(ptr["current"], vers); self.assertIn(ptr["previous"], vers)
        kept = sorted(os.listdir(os.path.join(self.store.root, "versions", "demo.skill")))
        self.assertEqual(kept, sorted([ptr["current"], ptr["previous"]]))
        self.assertEqual(len(sm._rb(self.store.log_path).splitlines()), 8)

    def test_14_canonical_vector(self):
        self.assertEqual(sm.canonical_json({"b": 1, "a": {"d": "0.5", "c": [1, 2]}, "_comment": "x"}),
                         b'{"a":{"c":[1,2],"d":"0.5"},"b":1}')
        with self.assertRaises(sm.Reject):
            sm.canonical_json({"x": 0.5})


def _proc_activate(root, pub, d):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    s = sm.SkillStore(root, [Ed25519PublicKey.from_public_bytes(pub)])
    return s.activate(d, expected_eval_hash=EH, run_gates=gate_pass).verdict


if __name__ == "__main__":
    unittest.main(verbosity=2)
