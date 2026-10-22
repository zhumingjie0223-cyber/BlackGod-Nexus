# 技能市场：技能包校验 / 签名 / 门控激活（参考实现）

依据：`门控规范_v1.4` §2 存档点②「端上技能包激活」与 §2.1 激活顺序；`pack_spec_v1.3` §1/§2/§4/§5。

- `skill_market.py`：Python 参考实现（依赖 `cryptography` 的 Ed25519）。
- `test_skill_market.py`：自测（18 项），密钥在运行时生成到临时目录。
- `SkillMarketInterface.swift.draft`：Swift 接口草案（未编译，box 无 swift 工具链）。

## 运行自测
```
cd tools/skill_market && python3 -m unittest -v test_skill_market
```

## 包格式
包是一个目录：`manifest.json` + 载荷文件。manifest 字段：
`pack_id, kind="skill", version(x.y.z), group(skills|experimental), channel, author_key_fingerprint(sha256(原始32字节公钥)),
capabilities[{id, domains?}], files[{path, sha256, size}], eval_hash{testset_lock_sha256, gate_config_sha256, gate_report_sha256}, signature`。
签名 = Ed25519(规范化 JSON(manifest 去掉 signature))；规范化：UTF-8、键排序、分隔符 `,` `:`、禁浮点、删注释键。

## 能力白名单
`skill.storage.own, ui.render, ui.notify, clipboard.write, network.fetch(必须带具体域名，禁通配/IP)`。
其他一律 FAIL；shell/exec/spawn、allowDangerous、读其他技能数据会给出「危险能力」原因。

## 用法
```python
import skill_market as sm
store = sm.SkillStore("/path/store", trusted_keys=[pubkey])        # 信任根由调用方传入
r = store.activate(pkg_dir, expected_eval_hash=发布记录的eval_hash, run_gates=门控函数)
r.verdict  # PASS / FAIL / NOT_READY
store.rollback("pack.id")                                           # current <-> previous
store.pointer("pack.id")                                            # {"current":..., "previous":...}
```
激活顺序（fail-closed）：结构校验 → 1 验签 → 能力白名单 → 2 逐文件哈希（先复制到 staging，在副本上校验，拒绝符号链接/../绝对路径/多余/缺失）→ 3 eval_hash（缺 NOT_READY，不符 FAIL）→ 4 run_gates（异常或非法返回值按 FAIL）→ 5 加锁、版本目录 rename 入库、指针原子替换（tmp+fsync+rename）。保留 current+previous，更早版本删除。
日志：`<store>/activation_log.jsonl`，每行 `{time, action, pack_id, version, verdict, reason}`。

## 离线签名（示例；正式私钥只放离线 CI，不进仓库）
`sm.write_manifest(d, sm.sign_manifest(sm.build_manifest(d, ...), priv))`。本地临时密钥若要落盘，只能放在已 gitignore 的 `tools/skill_market/.keys/`。
