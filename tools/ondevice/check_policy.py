#!/usr/bin/env python3
"""端上 Agent 决策表的 Python 镜像校验（box 上没有 Swift 工具链时用）。
规则须与 ios-app/NexusOnDeviceAgent.swift 逐条一致；Swift 测试读同一份 fixture。"""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
T = json.loads((root / "config/gates/asl_reject_thresholds.json").read_text())
MIN, MARGIN, HAND = T["min_confidence"], T["min_top2_margin"], T["min_hand_score"]
low = lambda v, m: (v if v is not None else -1) < m
def decide(r):
    if r["wantedOutput"] in ("image", "video"): return "refuse", False
    sign = r["input"] == "signVideo"
    if r["input"] in ("signVideo", "audio") and (low(r["recognitionConfidence"], MIN) or (sign and (low(r.get("top2Margin"), MARGIN) or low(r.get("handScore"), HAND)))): return "askRetry", False
    if r["input"] == "signVideo" and r["wantedOutput"] == "speech" and not r["userConfirmed"]: return "needsConfirmation", False
    if r["onDeviceReady"]: return "onDevice", False
    media = r["input"] != "text"
    if not r["online"]: return "refuse", False
    if media and not r["cloudMediaConsent"]: return "refuse", False
    return "cloud", media
cases = json.loads((root / "tests/fixtures/ondevice-agent-cases.json").read_text())
fail = 0
for c in cases:
    got = decide(c["req"])
    ok = got == (c["route"], c["leaves"])
    fail += not ok
    print(("PASS" if ok else "FAIL"), c["name"], got)
# 穷举：手语代说只在已确认且置信度达标时发生；原始媒体出设备只在联网+同意+端上未就绪时发生
import itertools
for inp, out, on, cons, conf, cf, ready, mg, hs in itertools.product(["text","image","video","audio","signVideo"],["text","speech","image","video"],[0,1],[0,1],[None,0.5,0.84,0.85,0.95],[0,1],[0,1],[None,0.1,0.15,0.3],[None,0.4,0.5,0.9]):
    r=dict(input=inp,wantedOutput=out,online=bool(on),cloudMediaConsent=bool(cons),recognitionConfidence=conf,userConfirmed=bool(cf),onDeviceReady=bool(ready),top2Margin=mg,handScore=hs)
    route, leaves = decide(r)
    if inp=="signVideo" and out=="speech" and route in("onDevice","cloud") and not (cf and not low(conf,MIN) and not low(mg,MARGIN) and not low(hs,HAND)): fail+=1; print("FAIL invariant speak", r)
    if leaves and not (on and cons and not ready and inp!="text"): fail+=1; print("FAIL invariant leak", r)
    if out in("image","video") and route!="refuse": fail+=1; print("FAIL invariant gen", r)
print(f"cases={len(cases)} fail={fail}")
sys.exit(1 if fail else 0)
