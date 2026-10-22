"""BlackGod 技能市场：技能包校验 / 签名 / 门控激活（参考实现，Python）。

依据：门控规范_v1.4 §2 存档点②、§2.1 激活顺序；pack_spec_v1.3 §1/§2/§4/§5。
激活顺序（fail-closed，前一步不过后面不执行）：
  1 验签 -> 2 逐文件 sha256 -> 3 eval_hash -> 4 run_gates -> 5 原子切指针
私钥从不在本模块中持久化；信任根（公钥列表）由调用方传入。
"""
from __future__ import annotations

import base64
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import time
from dataclasses import dataclass, field
from typing import Callable, Iterable

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

PASS, FAIL, NOT_READY = "PASS", "FAIL", "NOT_READY"
MANIFEST = "manifest.json"
GROUPS = {"skills", "experimental"}
EVAL_KEYS = ("testset_lock_sha256", "gate_config_sha256", "gate_report_sha256")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
PACK_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")

# 白名单：只有这些能力 id 可以出现。其余一律 FAIL（含 allowDangerous、shell.*）。
ALLOWED_CAPABILITIES = {
    "skill.storage.own",   # 只读写本技能自己的数据
    "ui.render",
    "ui.notify",
    "clipboard.write",
    "network.fetch",       # 必须带非空 domains
}
# 明确的危险能力（出现即 FAIL，并给出具体原因；即使未来误加入白名单也拒绝）
DANGEROUS_PATTERNS = (
    re.compile(r"(?i)allowdangerous"),
    re.compile(r"(?i)(^|[._])(shell|exec|spawn|subprocess|eval)([._]|$)"),
    re.compile(r"(?i)skill\.storage\.(other|all|any|\*)"),
    re.compile(r"(?i)(other|cross)[._-]?skill"),
)


class Reject(Exception):
    def __init__(self, verdict: str, reason: str):
        super().__init__(reason)
        self.verdict, self.reason = verdict, reason


def _rb(p):
    with open(p, "rb") as f:
        return f.read()


# ---------------------------------------------------------------- 规范化 / 哈希

def canonical_json(obj) -> bytes:
    """键排序、无多余空白、UTF-8；拒绝浮点（规范要求浮点写成字符串）、删除注释键。"""
    def clean(o):
        if isinstance(o, float):
            raise Reject(FAIL, "manifest 含浮点数，须写成十进制字符串")
        if isinstance(o, dict):
            return {k: clean(v) for k, v in o.items()
                    if not (isinstance(k, str) and (k.startswith("//") or k in ("_comment", "$comment")))}
        if isinstance(o, list):
            return [clean(v) for v in o]
        return o
    return json.dumps(clean(obj), sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def pubkey_raw(pub: Ed25519PublicKey) -> bytes:
    return pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def fingerprint(pub: Ed25519PublicKey) -> str:
    """作者公钥指纹 = sha256(32 字节原始公钥) 小写 hex。"""
    return sha256_hex(pubkey_raw(pub))


def signing_payload(manifest: dict) -> bytes:
    m = {k: v for k, v in manifest.items() if k != "signature"}
    return canonical_json(m)


# ---------------------------------------------------------------- 打包（供离线 CI / 测试）

def build_manifest(pkg_dir: str, *, pack_id: str, version: str, group: str,
                   capabilities: list, eval_hash: dict | None,
                   author_pub: Ed25519PublicKey) -> dict:
    files = []
    for root, dirs, names in os.walk(pkg_dir):
        dirs.sort()
        for n in sorted(names):
            full = os.path.join(root, n)
            rel = os.path.relpath(full, pkg_dir).replace(os.sep, "/")
            if rel == MANIFEST:
                continue
            data = _rb(full)
            files.append({"path": rel, "sha256": sha256_hex(data), "size": len(data)})
    m = {"pack_id": pack_id, "kind": "skill", "version": version, "group": group,
         "channel": "official", "author_key_fingerprint": fingerprint(author_pub),
         "capabilities": capabilities, "files": files}
    if eval_hash is not None:
        m["eval_hash"] = eval_hash
    return m


def sign_manifest(manifest: dict, priv: Ed25519PrivateKey) -> dict:
    m = dict(manifest)
    m["signature"] = base64.b64encode(priv.sign(signing_payload(m))).decode()
    return m


def write_manifest(pkg_dir: str, manifest: dict) -> None:
    with open(os.path.join(pkg_dir, MANIFEST), "wb") as f:
        f.write(canonical_json(manifest))


# ---------------------------------------------------------------- 校验步骤

def _safe_rel(path) -> str:
    if not isinstance(path, str) or not path:
        raise Reject(FAIL, "文件路径为空或类型错误")
    if "\\" in path or "\x00" in path:
        raise Reject(FAIL, f"非法路径字符: {path!r}")
    if path.startswith("/") or re.match(r"^[A-Za-z]:", path):
        raise Reject(FAIL, f"绝对路径: {path}")
    parts = path.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise Reject(FAIL, f"路径穿越或非规范路径: {path}")
    return path


def scan_tree(pkg_dir: str) -> dict[str, str]:
    """遍历包目录（不跟随符号链接）；任何符号链接/特殊文件 -> FAIL。返回 rel->绝对路径。"""
    st = os.lstat(pkg_dir)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise Reject(FAIL, "包根不是普通目录（可能是符号链接）")
    out = {}
    for root, dirs, names in os.walk(pkg_dir, followlinks=False):
        for n in dirs + names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, pkg_dir).replace(os.sep, "/")
            m = os.lstat(full).st_mode
            if stat.S_ISLNK(m):
                raise Reject(FAIL, f"包内含符号链接: {rel}")
            if stat.S_ISDIR(m):
                continue
            if not stat.S_ISREG(m):
                raise Reject(FAIL, f"包内含特殊文件: {rel}")
            out[rel] = full
    return out


def check_schema(m: dict) -> None:
    if not isinstance(m, dict):
        raise Reject(FAIL, "manifest 不是对象")
    req = ["pack_id", "kind", "version", "group", "author_key_fingerprint",
           "capabilities", "files", "signature"]
    miss = [k for k in req if k not in m]
    if miss:
        raise Reject(FAIL, f"manifest 缺字段: {','.join(miss)}")
    if m["kind"] != "skill":
        raise Reject(FAIL, "kind 必须为 skill")
    if not isinstance(m["pack_id"], str) or not PACK_ID.match(m["pack_id"]):
        raise Reject(FAIL, "pack_id 非法")
    if not isinstance(m["version"], str) or not SEMVER.match(m["version"]):
        raise Reject(FAIL, "version 须为 semver x.y.z")
    if m["group"] not in GROUPS:
        raise Reject(FAIL, f"group 须为 {sorted(GROUPS)}")
    if not isinstance(m["files"], list) or not isinstance(m["capabilities"], list):
        raise Reject(FAIL, "files / capabilities 须为数组")


def verify_signature(m: dict, trusted: Iterable[Ed25519PublicKey]) -> None:
    fp = m.get("author_key_fingerprint")
    keys = [k for k in trusted if fingerprint(k) == fp]
    if not keys:
        raise Reject(FAIL, "签名者不在信任根中")
    try:
        sig = base64.b64decode(m["signature"], validate=True)
    except Exception:
        raise Reject(FAIL, "签名编码错误")
    payload = signing_payload(m)
    for k in keys:
        try:
            k.verify(sig, payload)
            return
        except InvalidSignature:
            pass
    raise Reject(FAIL, "签名校验失败")


def check_capabilities(caps: list) -> None:
    for c in caps:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str):
            raise Reject(FAIL, f"能力声明格式错误: {c!r}")
        cid = c["id"]
        blob = json.dumps(c, ensure_ascii=False)
        for p in DANGEROUS_PATTERNS:
            if p.search(cid) or p.search(blob):
                raise Reject(FAIL, f"危险能力: {cid}")
        if cid not in ALLOWED_CAPABILITIES:
            raise Reject(FAIL, f"未知能力: {cid}")
        extra = set(c) - {"id", "domains"}
        if extra:
            raise Reject(FAIL, f"能力 {cid} 含未知字段: {sorted(extra)}")
        if cid == "network.fetch":
            d = c.get("domains")
            if not isinstance(d, list) or not d:
                raise Reject(FAIL, "网络访问未声明域名")
            for x in d:
                if not isinstance(x, str) or not DOMAIN.match(x):
                    raise Reject(FAIL, f"非法域名（不允许通配/IP/端口）: {x!r}")
        elif "domains" in c:
            raise Reject(FAIL, f"能力 {cid} 不接受 domains")


def verify_files(m: dict, tree: dict[str, str]) -> None:
    declared = {}
    for f in m["files"]:
        if not isinstance(f, dict):
            raise Reject(FAIL, "files[] 项格式错误")
        p = _safe_rel(f.get("path"))
        if p == MANIFEST or p in declared:
            raise Reject(FAIL, f"files[] 重复或包含 manifest: {p}")
        if not isinstance(f.get("sha256"), str) or not HEX64.match(f["sha256"]):
            raise Reject(FAIL, f"sha256 格式错误: {p}")
        declared[p] = f
    actual = set(tree) - {MANIFEST}
    extra = sorted(actual - set(declared))
    if extra:
        raise Reject(FAIL, f"多余文件: {extra}")
    missing = sorted(set(declared) - actual)
    if missing:
        raise Reject(FAIL, f"缺文件: {missing}")
    for p in sorted(declared):
        data = _rb(tree[p])
        if sha256_hex(data) != declared[p]["sha256"]:
            raise Reject(FAIL, f"哈希不符: {p}")
        if "size" in declared[p] and declared[p]["size"] != len(data):
            raise Reject(FAIL, f"大小不符: {p}")


def check_eval_hash(m: dict, expected: dict | None) -> None:
    eh = m.get("eval_hash")
    if not isinstance(eh, dict) or any(not eh.get(k) for k in EVAL_KEYS):
        raise Reject(NOT_READY, "eval_hash 缺失或不完整")
    if not expected or any(not expected.get(k) for k in EVAL_KEYS):
        raise Reject(NOT_READY, "缺少发布记录 eval_hash，无法核对")
    for k in EVAL_KEYS:
        if eh[k] != expected[k]:
            raise Reject(FAIL, f"eval_hash 不符: {k}")


# ---------------------------------------------------------------- 存储 / 指针 / 日志

@dataclass
class Result:
    verdict: str
    reason: str
    pack_id: str | None = None
    version: str | None = None


GateFn = Callable[[dict, str], str]  # (manifest, staged_dir) -> PASS/FAIL/NOT_READY


@dataclass
class SkillStore:
    root: str
    trusted_keys: list = field(default_factory=list)
    clock: Callable[[], float] = time.time

    def __post_init__(self):
        for d in ("versions", "pointers", "staging"):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        self.log_path = os.path.join(self.root, "activation_log.jsonl")

    # -- 指针
    def _ptr_path(self, pid):
        return os.path.join(self.root, "pointers", pid + ".json")

    def pointer(self, pid) -> dict:
        try:
            with open(self._ptr_path(pid), "rb") as f:
                return json.loads(f.read())
        except FileNotFoundError:
            return {"current": None, "previous": None}

    def _write_pointer(self, pid, ptr: dict) -> None:
        """原子写：临时文件 + fsync + os.replace + fsync 目录。读者只会看到旧或新。"""
        d = os.path.dirname(self._ptr_path(pid))
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".ptr-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(canonical_json(ptr))
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self._ptr_path(pid))
            dfd = os.open(d, os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(tmp)
            raise

    @contextlib.contextmanager
    def _lock(self, pid):
        with open(os.path.join(self.root, "pointers", "." + pid + ".lock"), "a") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lf, fcntl.LOCK_UN)

    def _log(self, action, res: Result):
        rec = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(self.clock())),
               "action": action, "pack_id": res.pack_id, "version": res.version,
               "verdict": res.verdict, "reason": res.reason}
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())

    def version_dir(self, pid, ver):
        return os.path.join(self.root, "versions", pid, ver)

    # -- 激活
    def activate(self, pkg_dir: str, *, expected_eval_hash: dict | None,
                 run_gates: GateFn) -> Result:
        res = Result(FAIL, "未知错误")
        staged = None
        try:
            # 先复制到 staging（复制前拒绝符号链接），之后所有校验都在副本上做，避免 TOCTOU
            scan_tree(pkg_dir)
            staged = tempfile.mkdtemp(dir=os.path.join(self.root, "staging"))
            shutil.rmtree(staged)
            shutil.copytree(pkg_dir, staged, symlinks=True)
            tree = scan_tree(staged)
            if MANIFEST not in tree:
                raise Reject(FAIL, "缺 manifest.json")
            try:
                m = json.loads(_rb(tree[MANIFEST]).decode("utf-8"))
            except Exception:
                raise Reject(FAIL, "manifest.json 解析失败")
            if isinstance(m, dict):
                res.pack_id, res.version = m.get("pack_id"), m.get("version")
            check_schema(m)
            verify_signature(m, self.trusted_keys)          # 1
            check_capabilities(m["capabilities"])            # （签名后、哈希前：静态拒绝）
            verify_files(m, tree)                            # 2
            check_eval_hash(m, expected_eval_hash)           # 3
            try:                                             # 4
                g = run_gates(m, staged)
            except Exception as e:
                raise Reject(FAIL, f"run_gates 异常: {type(e).__name__}")
            if g not in (PASS, FAIL, NOT_READY):
                raise Reject(FAIL, f"run_gates 返回非法值: {g!r}")
            if g != PASS:
                raise Reject(g, f"run_gates = {g}")
            pid, ver = m["pack_id"], m["version"]
            with self._lock(pid):                            # 5
                dest = self.version_dir(pid, ver)
                ptr = self.pointer(pid)
                if ptr.get("current") == ver:
                    raise Reject(FAIL, "该版本已是当前版本")
                if os.path.exists(dest):
                    if ver == ptr.get("previous"):
                        raise Reject(FAIL, "该版本为 previous，请用回滚")
                    shutil.rmtree(dest)  # 未被指针引用的残留（如上次崩溃）
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                os.rename(staged, dest)
                staged = None
                old_prev = ptr.get("previous")
                self._write_pointer(pid, {"current": ver, "previous": ptr.get("current")})
                if old_prev and old_prev != ver:
                    shutil.rmtree(self.version_dir(pid, old_prev), ignore_errors=True)
            res.verdict, res.reason = PASS, "激活成功"
        except Reject as r:
            res.verdict, res.reason = r.verdict, r.reason
        except Exception as e:  # fail-closed
            res.verdict, res.reason = FAIL, f"内部错误: {type(e).__name__}"
        finally:
            if staged:
                shutil.rmtree(staged, ignore_errors=True)
        self._log("activate", res)
        return res

    def rollback(self, pid: str) -> Result:
        res = Result(FAIL, "", pid)
        with self._lock(pid):
            ptr = self.pointer(pid)
            prev = ptr.get("previous")
            if not prev or not os.path.isdir(self.version_dir(pid, prev)):
                res.reason = "无可回滚的上一版本"
            else:
                self._write_pointer(pid, {"current": prev, "previous": ptr.get("current")})
                res.verdict, res.version, res.reason = PASS, prev, f"回滚: {ptr.get('current')} -> {prev}"
        self._log("rollback", res)
        return res
