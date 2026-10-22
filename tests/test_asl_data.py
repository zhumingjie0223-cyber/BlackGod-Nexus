"""Validate data/asl/* (ASL voice-sign v0 data). Run: pytest tests/test_asl_data.py"""
import json
from pathlib import Path

import pytest

jsonschema = pytest.importorskip("jsonschema")
D = Path(__file__).resolve().parent.parent / "data" / "asl"

ALPHA_SCHEMA = {"type": "object", "required": ["letters"], "properties": {"letters": {"type": "array", "items": {
    "type": "object", "additionalProperties": False,
    "required": ["id", "letter", "is_dynamic", "handshape_note", "confusable_with"],
    "properties": {"id": {"type": "string"}, "letter": {"type": "string", "pattern": "^[A-Z]$"},
                   "is_dynamic": {"type": "boolean"}, "handshape_note": {"type": "string", "minLength": 1},
                   "confusable_with": {"type": "array", "items": {"type": "string", "pattern": "^[A-Z]$"}}}}}}}
MOCK_SCHEMA = {"type": "object", "additionalProperties": False,
    "required": ["MOCK", "sample_id", "type", "top_k", "hand_score", "frames", "expected_action", "expected_text"],
    "properties": {"MOCK": {"const": True}, "sample_id": {"type": "string"}, "type": {"enum": ["letter", "word", "sequence"]},
                   "top_k": {"type": "array", "minItems": 2, "items": {"type": "object", "required": ["label", "score"],
                             "properties": {"label": {"type": "string"}, "score": {"type": "number", "minimum": 0, "maximum": 1}}}},
                   "hand_score": {"type": "number", "minimum": 0, "maximum": 1}, "frames": {"type": "integer", "minimum": 1},
                   "expected_action": {"enum": ["accept", "retry_prompt", "reject_no_speak"]}, "expected_text": {"type": "string"}}}


def load(n):
    return json.loads((D / n).read_text(encoding="utf-8"))


def mock():
    lines = [json.loads(l) for l in (D / "mock_recognitions.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    assert lines[0]["type"] == "config" and lines[0]["MOCK"] is True
    return lines[0], lines[1:]


def test_alphabet():
    a = load("fingerspelling_alphabet.json")
    jsonschema.validate(a, ALPHA_SCHEMA)
    letters = [x["letter"] for x in a["letters"]]
    assert sorted(letters) == [chr(c) for c in range(65, 91)] and len(letters) == 26
    assert {x["letter"] for x in a["letters"] if x["is_dynamic"]} == {"J", "Z"}


def test_wordlist():
    w = load("wordlist_v0.json")
    jsonschema.Draft202012Validator.check_schema(load("wordlist_schema.json"))
    jsonschema.validate(w, load("wordlist_schema.json"))
    ids = [x["word_id"] for x in w["words"]]
    assert len(ids) == len(set(ids)) and 15 <= len(ids) <= 30
    for x in w["words"]:
        if x["signbank_id_gloss"] is None:
            assert x.get("signbank_status") == "未确认"


def test_mock_schema_and_rules():
    cfg, rows = mock()
    t = cfg["thresholds"]
    vocab = {x["english"] for x in load("wordlist_v0.json")["words"]}
    alpha = {x["letter"] for x in load("fingerspelling_alphabet.json")["letters"]}
    assert len(rows) >= 15
    for r in rows:
        jsonschema.validate(r, MOCK_SCHEMA)
        k = sorted(r["top_k"], key=lambda e: -e["score"])
        top, margin = k[0], k[0]["score"] - k[1]["score"]
        known = (top["label"] in alpha if r["type"] == "letter" else
                 top["label"] in vocab if r["type"] == "word" else all(p in vocab for p in top["label"].split()))
        if r["hand_score"] < t["min_hand_score"] or not known:
            exp = "reject_no_speak"
        elif top["score"] >= t["accept_min_score"] and margin >= t["min_margin"] - 1e-9:
            exp = "accept"
        else:
            exp = "retry_prompt"
        assert r["expected_action"] == exp, r["sample_id"]
        want = {"accept": top["label"], "retry_prompt": "没看清，请再打一次", "reject_no_speak": ""}[exp]
        assert r["expected_text"] == want, r["sample_id"]


def test_mock_coverage():
    _, rows = mock()
    acts = {r["expected_action"] for r in rows}
    assert acts == {"accept", "retry_prompt", "reject_no_speak"}
    labels = {r["top_k"][0]["label"] for r in rows if r["expected_action"] == "accept"}
    assert {"J", "Z"} <= labels
    assert any(r["hand_score"] == 0 for r in rows)
