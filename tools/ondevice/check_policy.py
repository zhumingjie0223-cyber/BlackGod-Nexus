#!/usr/bin/env python3
"""端上 Agent 决策表的 Python 镜像校验（box 上没有 Swift 工具链时用）。
规则须与 ios-app/NexusOnDeviceAgent.swift 逐条一致；Swift 测试读同一份 fixture。"""
import json, pathlib, sys
MIN = 0.80
def decide(r):
    if r["wantedOutput"] in ("image", "video"): return "refuse", False
    if r["input"] in ("signVideo", "audio") and (r["recognitionConfidence"] if r["recognitionConfidence"] is not None else 0) < MIN: return "askRetry", False
    if r["input"] == "signVideo" and r["wantedOutput"] == "speech" and not r["userConfirmed"]: return "needsConfirmation", False
    if r["onDeviceReady"]: return "onDevice", False
    media = r["input"] != "text"
    if not r["online"]: return "refuse", False
    if media and not r["cloudMediaConsent"]: return "refuse", False
    return "cloud", media
root = pathlib.Path(__file__).resolve().parents[2]
cases = json.loads((root / "tests/fixtures/ondevice-agent-cases.json").read_text())
fail = 0
for c in cases:
    got = decide(c["req"])
    ok = got == (c["route"], c["leaves"])
    fail += not ok
    print(("PASS" if ok else "FAIL"), c["name"], got)
# 穷举：手语代说只在已确认且置信度达标时发生；原始媒体出设备只在联网+同意+端上未就绪时发生
import itertools
for inp, out, on, cons, conf, cf, ready in itertools.product(["text","image","video","audio","signVideo"],["text","speech","image","video"],[0,1],[0,1],[None,0.5,0.79,0.8,0.95],[0,1],[0,1]):
    r=dict(input=inp,wantedOutput=out,online=bool(on),cloudMediaConsent=bool(cons),recognitionConfidence=conf,userConfirmed=bool(cf),onDeviceReady=bool(ready))
    route, leaves = decide(r)
    if inp=="signVideo" and out=="speech" and route in("onDevice","cloud") and not (cf and conf is not None and conf>=MIN): fail+=1; print("FAIL invariant speak", r)
    if leaves and not (on and cons and not ready and inp!="text"): fail+=1; print("FAIL invariant leak", r)
    if out in("image","video") and route!="refuse": fail+=1; print("FAIL invariant gen", r)
print(f"cases={len(cases)} fail={fail}")
sys.exit(1 if fail else 0)
