import XCTest
import Foundation
@testable import BlackGod

/// VoiceSignCore 纯逻辑测试（Linux 由 tools/intelligence/run-tests.sh 运行）。
final class VoiceSignCoreTests: XCTestCase {
    static var repoRoot: URL {
        if let r = ProcessInfo.processInfo.environment["BLACK_GOD_REPO_ROOT"] { return URL(fileURLWithPath: r) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func asl(_ name: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("data/asl/\(name)"))
    }
    static func thresholds() throws -> SignRejectionThresholds {
        try SignRejectionThresholds.load(from: Data(contentsOf: repoRoot.appendingPathComponent(SignRejectionThresholds.configRelativePath)))
    }

    func testOnDevicePolicy() {
        XCTAssertEqual(OnDeviceASRPolicy.evaluate(localeID: "zh-CN", recognizerExists: true,
            recognizerAvailable: true, supportsOnDeviceRecognition: true), .allowed)
        XCTAssertEqual(OnDeviceASRPolicy.evaluate(localeID: "en-US", recognizerExists: true,
            recognizerAvailable: true, supportsOnDeviceRecognition: true), .allowed)
        XCTAssertNotEqual(OnDeviceASRPolicy.evaluate(localeID: "en-US", recognizerExists: true,
            recognizerAvailable: true, supportsOnDeviceRecognition: false), .allowed, "不得回落服务器")
        XCTAssertNotEqual(OnDeviceASRPolicy.evaluate(localeID: "ja-JP", recognizerExists: true,
            recognizerAvailable: true, supportsOnDeviceRecognition: true), .allowed)
        XCTAssertNotEqual(OnDeviceASRPolicy.evaluate(localeID: "zh-CN", recognizerExists: false,
            recognizerAvailable: false, supportsOnDeviceRecognition: false), .allowed)
        XCTAssertNotEqual(OnDeviceASRPolicy.evaluate(localeID: "zh-CN", recognizerExists: true,
            recognizerAvailable: false, supportsOnDeviceRecognition: true), .allowed)
    }

    func testFirstTokenLatency() {
        var m = FirstTokenLatencyMeter()
        m.start(at: 10)
        m.observe(partialText: "  ", at: 10.1)
        XCTAssertNil(m.firstTokenLatency)
        m.observe(partialText: "你", at: 10.35)
        m.observe(partialText: "你好", at: 11)
        XCTAssertEqual(m.firstTokenLatency ?? -1, 0.35, accuracy: 1e-9)
    }

    func testSpeakWithoutConfirmIsRejectedAndLogged() throws {
        var m = SpeakForMeMachine()
        XCTAssertThrowsError(try m.beginSpeaking()) { XCTAssertEqual($0 as? SpeakError, .notConfirmed) }
        try m.setDraft("你好", source: .typed)
        XCTAssertThrowsError(try m.beginSpeaking())
        XCTAssertEqual(m.rejectedSpeakCount, 2)
        try m.confirm(text: "你好")
        XCTAssertEqual(try m.beginSpeaking(), "你好")
        XCTAssertEqual(m.state, .speaking(text: "你好"))
        m.finishSpeaking()
        XCTAssertEqual(m.state, .idle)
        XCTAssertThrowsError(try m.beginSpeaking(), "念完后需重新确认")
    }

    func testEditInvalidatesConfirmationAndMismatchRejected() throws {
        var m = SpeakForMeMachine()
        try m.setDraft("A", source: .typed)
        XCTAssertThrowsError(try m.confirm(text: "B"))
        try m.confirm(text: "A")
        try m.setDraft("C", source: .typed)
        XCTAssertThrowsError(try m.beginSpeaking())
        XCTAssertThrowsError(try m.setDraft("   ", source: .typed))
    }

    static let canonical = #"{"schema":"blackgod.asl_reject_thresholds","version":"0.1-provisional","status":"provisional","min_confidence":0.85,"min_top2_margin":0.15,"min_hand_score":0.5,"on_reject":"retry_prompt","speak_requires_user_confirm":true}"#

    func testGateConfigFileIsByteExactAndLoads() throws {
        let raw = try Data(contentsOf: Self.repoRoot.appendingPathComponent(SignRejectionThresholds.configRelativePath))
        XCTAssertEqual(raw, Data(Self.canonical.utf8), "配置须逐字节一致且无末尾换行")
        let t = try Self.thresholds()
        XCTAssertEqual(t.minConfidence, 0.85); XCTAssertEqual(t.minTop2Margin, 0.15); XCTAssertEqual(t.minHandScore, 0.5)
        XCTAssertEqual(t.status, "provisional"); XCTAssertTrue(t.speakRequiresUserConfirm)
    }

    func testGateConfigRefusesUnsafeOrUnknown() {
        func variant(_ from: String, _ to: String) -> Data { Data(Self.canonical.replacingOccurrences(of: from, with: to).utf8) }
        XCTAssertThrowsError(try SignRejectionThresholds.load(from: variant(#""speak_requires_user_confirm":true"#, #""speak_requires_user_confirm":false"#)))
        XCTAssertThrowsError(try SignRejectionThresholds.load(from: variant(#""status":"provisional""#, #""status":"whatever""#)))
        XCTAssertThrowsError(try SignRejectionThresholds.load(from: variant(#""schema":"blackgod.asl_reject_thresholds""#, #""schema":"x""#)))
        XCTAssertThrowsError(try SignRejectionThresholds.load(from: variant(#","min_hand_score":0.5"#, "")), "配置缺字段拒绝启用")
        XCTAssertThrowsError(try SignRejectionThresholds.load(from: variant(#""min_confidence":0.85"#, #""min_confidence":1.5"#)))
    }

    /// 三项任一缺失或低于下限 → retry_prompt。
    func testMissingOrLowItemsGoToRetryPrompt() throws {
        let gate = SignRejectionGate(thresholds: try Self.thresholds())
        let retry = SignDecision.retry("没看清，请再打一次")
        let good = [SignCandidate(label: "A", confidence: 0.95), SignCandidate(label: "S", confidence: 0.03)]
        XCTAssertEqual(gate.decide(good, handScore: 0.9), .accepted(good[0]))
        XCTAssertEqual(gate.decide(good, handScore: nil), retry, "手部分数缺失")
        XCTAssertEqual(gate.decide([], handScore: 0.9), retry, "置信度缺失")
        XCTAssertEqual(gate.decide([SignCandidate(label: "A", confidence: .nan)], handScore: 0.9), retry)
        XCTAssertEqual(gate.decide([good[0], SignCandidate(label: "S", confidence: .nan)], handScore: 0.9), retry, "top2 缺失/无效")
        XCTAssertEqual(gate.decide(good, handScore: 0.49), retry)
        XCTAssertEqual(gate.decide([SignCandidate(label: "A", confidence: 0.84)], handScore: 0.9), retry)
        XCTAssertEqual(gate.decide([SignCandidate(label: "A", confidence: 0.9), SignCandidate(label: "S", confidence: 0.8)], handScore: 0.9), retry)
    }

    func loadVocabulary() throws -> Set<String> {
        var v = Set<String>()
        let w = try JSONSerialization.jsonObject(with: Self.asl("wordlist_v0.json")) as? [String: Any] ?? [:]
        for e in w["words"] as? [[String: Any]] ?? [] { if let s = e["english"] as? String { v.insert(s) } }
        let a = try JSONSerialization.jsonObject(with: Self.asl("fingerspelling_alphabet.json")) as? [String: Any] ?? [:]
        for e in a["letters"] as? [[String: Any]] ?? [] { if let s = e["letter"] as? String { v.insert(s) } }
        return v
    }

    /// 直接读 data/asl/mock_recognitions.jsonl（MOCK 数据）逐条核对 accept / retry_prompt / reject_no_speak。
    func testMockRecognitionsJSONL() throws {
        let text = String(decoding: try Self.asl("mock_recognitions.jsonl"), as: UTF8.self)
        let thresholds = try Self.thresholds()
        let gate = SignRejectionGate(thresholds: thresholds, vocabulary: try loadVocabulary())
        var checked = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
            if o["type"] as? String == "config" {
                let t = o["thresholds"] as? [String: Double] ?? [:]
                XCTAssertEqual(t["min_confidence"], thresholds.minConfidence, "配置文件与 mock 门限不一致")
                XCTAssertEqual(t["min_top2_margin"], thresholds.minTop2Margin)
                XCTAssertEqual(t["min_hand_score"], thresholds.minHandScore)
                continue
            }
            let id = o["sample_id"] as? String ?? "?"
            let cands = (o["top_k"] as? [[String: Any]] ?? []).map {
                SignCandidate(label: $0["label"] as? String ?? "", confidence: ($0["score"] as? NSNumber)?.doubleValue ?? 0)
            }
            let d = gate.decide(cands, handScore: (o["hand_score"] as? NSNumber)?.doubleValue)
            let expected = o["expected_action"] as? String ?? ""
            switch (expected, d) {
            case ("accept", .accepted(let c)): XCTAssertEqual(c.label, o["expected_text"] as? String, id)
            case ("retry_prompt", .retry(let m)): XCTAssertEqual(m, "没看清，请再打一次", id)
            case ("reject_no_speak", .rejectNoSpeak): break
            default: XCTFail("\(id): expected \(expected), got \(d)")
            }
            checked += 1
        }
        XCTAssertEqual(checked, 15)

        // 内联补充（建议数据侧补为 m16）：不在词表 + 手部够 + 置信度偏低 → reject_no_speak
        let m16 = [SignCandidate(label: "computer", confidence: 0.6), SignCandidate(label: "hello", confidence: 0.3)]
        XCTAssertEqual(gate.decide(m16, handScore: 0.9), .rejectNoSpeak("不在词表内"))
        // 手部偏低优先于词表：不在词表 + 手部低 → retry_prompt
        XCTAssertEqual(gate.decide(m16, handScore: 0.3), .retry(SignDecision.retryMessage))
    }

    func testBridgeDefaultOffAndOnlyDrafts() throws {
        let gate = SignRejectionGate(thresholds: try Self.thresholds())
        var m = SpeakForMeMachine()
        let c = [SignCandidate(label: "hello", confidence: 0.95)]
        let off = SignToSpeakBridge(gate: gate)
        XCTAssertFalse(VoiceSignFeatureFlags.signToSpeechDefault)
        XCTAssertTrue(off.route(c, handScore: 0.9, into: &m).contains("NOT_READY"))
        XCTAssertEqual(m.state, .idle)
        var on = SignToSpeakBridge(gate: gate); on.enabled = true; on.gateStatus = .pass
        _ = on.route(c, handScore: 0.9, into: &m)
        XCTAssertEqual(m.state, .draft(text: "hello", source: .sign))
        XCTAssertThrowsError(try m.beginSpeaking(), "手语结果未确认不得朗读")
    }

    func testMockRecognizerTopK() throws {
        let r = MockSignRecognizer(scripted: [.init(label: "B", confidence: 0.1), .init(label: "A", confidence: 0.9),
                                              .init(label: "C", confidence: 0.5)])
        XCTAssertEqual(try r.recognize(frames: [], topK: 2).map(\.label), ["A", "C"])
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Pure.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Pure.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testManifestValidation() throws {
        func make(_ v: String, _ e: [String], hash: String? = nil) -> SignVocabularyManifest {
            let tmp = SignVocabularyManifest(kind: .fingerspelling, language: "ASL", version: v, entries: e, sha256: "")
            return .init(kind: .fingerspelling, language: "ASL", version: v, entries: e,
                         sha256: hash ?? SHA256Pure.hex(tmp.canonicalPayload))
        }
        XCTAssertNoThrow(try ManifestValidator.validate(make("0.1.0", ["A", "B"])))
        XCTAssertThrowsError(try ManifestValidator.validate(make("v1", ["A"])))
        XCTAssertThrowsError(try ManifestValidator.validate(make("0.1", [])))
        XCTAssertThrowsError(try ManifestValidator.validate(make("0.1", ["A", "A"])))
        XCTAssertThrowsError(try ManifestValidator.validate(make("0.1", ["A"], hash: "XYZ")))
        XCTAssertThrowsError(try ManifestValidator.validate(make("0.1", ["A"], hash: String(repeating: "0", count: 64)))) {
            XCTAssertEqual($0 as? ManifestError, .hashMismatch)
        }
    }
}
