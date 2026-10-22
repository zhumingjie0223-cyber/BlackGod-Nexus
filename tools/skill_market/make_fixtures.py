"""生成 Swift/Python 共享的判定 fixture（运行时生成到指定临时目录，密钥不落仓库）。

用法: python3 make_fixtures.py <输出目录>
输出: <out>/cases.json = {"trusted_pubkeys_hex": [...], "expected_eval_hash": {...},
                          "cases": [{"name", "package", "expected_eval_hash", "verdict", "reason"}]}
verdict/reason 由 Python 参考实现实际跑出（gate 恒 PASS），Swift 端须逐字一致。
"""
import json, os, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import skill_market as sm
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

EH = {"testset_lock_sha256": "a" * 64, "gate_config_sha256": "b" * 64, "gate_report_sha256": "c" * 64}
CAPS = [{"id": "skill.storage.own"}, {"id": "network.fetch", "domains": ["api.example.com"]}]


def _w(p, s, mode="w"):
    with open(p, mode) as f:
        f.write(s)


def main(out):
    os.makedirs(out, exist_ok=True)
    key, other = Ed25519PrivateKey.generate(), Ed25519PrivateKey.generate()
    pkgs = os.path.join(out, "packages")

    def make(name, caps=CAPS, eh=EH, k=key, mutate=None):
        d = os.path.join(pkgs, name)
        os.makedirs(os.path.join(d, "steps"))
        _w(os.path.join(d, "skill.json"), json.dumps({"name": "demo"}))
        _w(os.path.join(d, "steps", "1.md"), "step one\n")
        m = sm.build_manifest(d, pack_id="demo.skill", version="1.0.0", group="skills",
                              capabilities=caps, eval_hash=eh, author_pub=k.public_key())
        if mutate:
            mutate(m)
        sm.write_manifest(d, sm.sign_manifest(m, k))
        return d

    cases = []
    def add(name, d, expected=EH):
        cases.append({"name": name, "package": os.path.relpath(d, out), "expected_eval_hash": expected})

    add("normal_pass", make("normal_pass"))
    d = make("tampered_file"); _w(os.path.join(d, "steps", "1.md"), "x", "a"); add("tampered_file", d)
    add("other_signer", make("other_signer", k=other))
    add("missing_eval_hash", make("missing_eval_hash", eh=None))
    add("eval_hash_mismatch", make("eval_hash_mismatch"), dict(EH, gate_report_sha256="d" * 64))
    add("dangerous_shell", make("dangerous_shell", caps=[{"id": "shell.exec"}]))
    add("dangerous_allow", make("dangerous_allow", caps=[{"id": "allowDangerous"}]))
    add("network_no_domain", make("network_no_domain", caps=[{"id": "network.fetch"}]))
    add("unknown_capability", make("unknown_capability", caps=[{"id": "camera.raw"}]))
    for i, bad in enumerate(["../evil", "/etc/passwd", "steps/../../x"]):
        add(f"path_traversal_{i}", make(f"path_traversal_{i}", mutate=lambda m, b=bad: m["files"].append(
            {"path": b, "sha256": "0" * 64, "size": 0})))
    d = make("extra_file"); _w(os.path.join(d, "extra.bin"), "x"); add("extra_file", d)
    d = make("symlink"); os.symlink("/etc/hostname", os.path.join(d, "link")); add("symlink", d)

    store_root = tempfile.mkdtemp(prefix="skm-fx-store-")
    try:
        for c in cases:
            # 每个用例独立 store，互不影响
            s = sm.SkillStore(os.path.join(store_root, c["name"]), [key.public_key()])
            r = s.activate(os.path.join(out, c["package"]), expected_eval_hash=c["expected_eval_hash"],
                           run_gates=lambda m, d: sm.PASS)
            c["verdict"], c["reason"] = r.verdict, r.reason
    finally:
        shutil.rmtree(store_root, ignore_errors=True)
    doc = {"trusted_pubkeys_hex": [sm.pubkey_raw(key.public_key()).hex()], "cases": cases}
    _w(os.path.join(out, "cases.json"), json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=True))
    for c in cases:
        print(f'{c["name"]}\t{c["verdict"]}\t{c["reason"]}')


if __name__ == "__main__":
    main(sys.argv[1])
