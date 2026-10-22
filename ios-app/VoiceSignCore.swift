import Foundation

// VoiceSignCore：语音/手语代说的纯逻辑，只依赖 Foundation，可在 Linux SwiftPM 测试。
// Apple 框架相关实现见 VoiceSignLiveCaption.swift / VoiceSignSpeakForMe.swift / VoiceSignInput.swift。

// MARK: - 端上识别强制策略

enum VoiceSignLocale: String, CaseIterable, Sendable {
    case zhCN = "zh-CN"
    case enUS = "en-US"
}

enum OnDeviceASRDecision: Equatable, Sendable {
    case allowed
    case refused(String)
}

/// 只有在“语言受支持 + 识别器可用 + 支持端上识别”时才允许启动；绝不回落到服务器识别。
enum OnDeviceASRPolicy {
    static func evaluate(localeID: String,
                         recognizerExists: Bool,
                         recognizerAvailable: Bool,
                         supportsOnDeviceRecognition: Bool) -> OnDeviceASRDecision {
        guard VoiceSignLocale(rawValue: localeID) != nil else {
            return .refused("不支持的语言：\(localeID)，仅支持 zh-CN / en-US")
        }
        guard recognizerExists else { return .refused("此设备没有 \(localeID) 识别器") }
        guard supportsOnDeviceRecognition else {
            return .refused("此设备/语言不支持端上识别，已拒绝启动（不会使用服务器识别）")
        }
        guard recognizerAvailable else { return .refused("识别器暂不可用，请稍后重试") }
        return .allowed
    }
}

/// 首字延迟：从开始收音到第一个非空部分结果的时间。
struct FirstTokenLatencyMeter: Sendable {
    private(set) var startedAt: TimeInterval?
    private(set) var firstTokenLatency: TimeInterval?

    mutating func start(at t: TimeInterval) { startedAt = t; firstTokenLatency = nil }

    mutating func observe(partialText: String, at t: TimeInterval) {
        guard firstTokenLatency == nil, let s = startedAt,
              !partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        firstTokenLatency = max(0, t - s)
    }
}

// MARK: - 代说状态机 draft -> confirmed -> speaking

enum SpeakSource: String, Sendable { case typed, phrase, sign }

enum SpeakState: Equatable, Sendable {
    case idle
    case draft(text: String, source: SpeakSource)
    case confirmed(text: String, source: SpeakSource)
    case speaking(text: String)
}

enum SpeakError: Error, Equatable, Sendable {
    case notConfirmed
    case emptyText
    case invalidTransition(String)
}

struct SpeakAuditEntry: Equatable, Sendable {
    let event: String
    let detail: String
}

/// 硬规则：只有用户确认过的文本才能念。未确认调用 speak 一律拒绝并记录。
struct SpeakForMeMachine: Sendable {
    private(set) var state: SpeakState = .idle
    private(set) var audit: [SpeakAuditEntry] = []

    private mutating func log(_ e: String, _ d: String = "") { audit.append(.init(event: e, detail: d)) }

    /// 写入/替换草稿。任何编辑都会让之前的确认失效。
    mutating func setDraft(_ text: String, source: SpeakSource) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SpeakError.emptyText }
        if case .speaking = state { throw SpeakError.invalidTransition("speaking 中不能改草稿") }
        state = .draft(text: t, source: source)
        log("draft", source.rawValue)
    }

    /// 用户显式确认。`text` 必须与当前草稿完全一致，防止确认后被替换。
    mutating func confirm(text: String) throws {
        guard case let .draft(d, src) = state else { throw SpeakError.invalidTransition("没有草稿可确认") }
        guard d == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SpeakError.invalidTransition("确认文本与草稿不一致")
        }
        state = .confirmed(text: d, source: src)
        log("confirmed", src.rawValue)
    }

    /// 返回要念的文本。只有 confirmed 状态可以通过。
    mutating func beginSpeaking() throws -> String {
        guard case let .confirmed(t, _) = state else {
            log("speak_rejected", "not_confirmed")
            throw SpeakError.notConfirmed
        }
        state = .speaking(text: t)
        log("speaking")
        return t
    }

    mutating func finishSpeaking() {
        if case .speaking = state { state = .idle; log("finished") }
    }

    mutating func cancel() { state = .idle; log("cancel") }

    var rejectedSpeakCount: Int { audit.filter { $0.event == "speak_rejected" }.count }
}

enum CommonPhrases {
    static let zh = ["你好", "谢谢", "请稍等", "请再说一遍", "我听不见，请写给我看", "我需要帮助"]
    static let en = ["Hello", "Thank you", "Please wait", "Could you repeat that?",
                     "I can't hear, please write it down", "I need help"]
}

// MARK: - 手语：关键点、候选、拒识

struct SignKeypoint: Equatable, Sendable { let x: Float; let y: Float; let z: Float }
struct SignFrame: Equatable, Sendable { let timestamp: TimeInterval; let keypoints: [SignKeypoint] }

struct SignCandidate: Equatable, Sendable {
    let label: String
    let confidence: Double
}

/// 输入关键点帧序列，输出 top-k 候选（按置信度降序）。实现方不得直接产生可朗读文本。
protocol SignRecognizer {
    func recognize(frames: [SignFrame], topK: Int) throws -> [SignCandidate]
}

enum SignDecision: Equatable, Sendable {
    case accepted(SignCandidate)
    /// 置信度不足或前两名太接近：提示重打，不产生文本。
    case retry(String)
    /// 标签不在词表：直接拒识，不产生文本。
    case rejectNoSpeak(String)
    static let retryMessage = "没看清，请再打一次"
}

/// 拒识门限（可配置）。
/// 暂定值：置信度 ≥ 0.85、top1-top2 ≥ 0.15、手部检测 ≥ 0.5 —— 待 ASL 门控标定后再定，勿当作已验证参数。
/// 门限从统一门控配置 config/gates/asl_reject_thresholds.json 读取，代码中不内置数值。
/// 当前 status 为 provisional（暂定），待 ASL 门控标定。
struct SignRejectionThresholds: Codable, Equatable, Sendable {
    static let expectedSchema = "blackgod.asl_reject_thresholds"
    static let knownStatuses: Set<String> = ["provisional", "calibrated"]
    static let configRelativePath = "config/gates/asl_reject_thresholds.json"

    var schema: String
    var version: String
    var status: String
    var minConfidence: Double
    var minTop2Margin: Double
    var minHandScore: Double
    var onReject: String
    var speakRequiresUserConfirm: Bool

    enum CodingKeys: String, CodingKey {
        case schema, version, status
        case minConfidence = "min_confidence", minTop2Margin = "min_top2_margin", minHandScore = "min_hand_score"
        case onReject = "on_reject", speakRequiresUserConfirm = "speak_requires_user_confirm"
    }

    enum LoadError: Error, Equatable {
        case wrongSchema, unknownStatus, confirmNotRequired, unsupportedOnReject, outOfRange
    }

    /// 解析并校验；任何不合规（缺字段、schema/status 不认识、speak_requires_user_confirm != true）都抛错 → 拒绝启用。
    static func load(from data: Data) throws -> SignRejectionThresholds {
        let t = try JSONDecoder().decode(SignRejectionThresholds.self, from: data)
        guard t.schema == expectedSchema else { throw LoadError.wrongSchema }
        guard knownStatuses.contains(t.status) else { throw LoadError.unknownStatus }
        guard t.speakRequiresUserConfirm else { throw LoadError.confirmNotRequired }
        guard t.onReject == "retry_prompt" else { throw LoadError.unsupportedOnReject }
        let ok = [t.minConfidence, t.minTop2Margin, t.minHandScore].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        guard ok else { throw LoadError.outOfRange }
        return t
    }
}

struct SignRejectionGate: Sendable {
    var thresholds: SignRejectionThresholds
    /// 允许的标签集合（字母表 + 词表）；nil 表示不检查。
    var vocabulary: Set<String>? = nil

    /// 置信度 / top1-top2 差距 / 手部检测 任一缺失或低于下限 → retry_prompt（不产生文本）。
    /// 标签不在词表 → rejectNoSpeak（也不产生文本）。
    func decide(_ candidates: [SignCandidate], handScore: Double?) -> SignDecision {
        let retry = SignDecision.retry(SignDecision.retryMessage)
        guard let hand = handScore, hand.isFinite, hand >= thresholds.minHandScore else { return retry }
        let s = candidates.sorted { $0.confidence > $1.confidence }
        guard let top1 = s.first, top1.confidence.isFinite, top1.confidence >= thresholds.minConfidence else {
            return retry
        }
        let second = s.count > 1 ? s[1].confidence : 0
        guard second.isFinite, top1.confidence - second >= thresholds.minTop2Margin - 1e-9 else { return retry }
        if let v = vocabulary,
           top1.label.isEmpty || !top1.label.split(separator: " ").allSatisfy({ v.contains(String($0)) }) {
            return .rejectNoSpeak("不在词表内")
        }
        return .accepted(top1)
    }
}

// MARK: - 词表 / 指拼字母表清单

struct SignVocabularyManifest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case fingerspelling, lexicon }
    let kind: Kind
    let language: String       // 例如 "ASL"
    let version: String        // 版本 x.y 或 x.y.z
    let entries: [String]
    let sha256: String         // 对 canonicalPayload 的 sha256（小写 hex）

    /// 规范化负载：kind|language|version|entries 以 \n 连接。
    var canonicalPayload: Data {
        Data(([kind.rawValue, language, version] + entries).joined(separator: "\n").utf8)
    }
}

enum ManifestError: Error, Equatable, Sendable {
    case badVersion, emptyEntries, duplicateEntry(String), badHashFormat, hashMismatch
}

enum ManifestValidator {
    static func validate(_ m: SignVocabularyManifest) throws {
        let parts = m.version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw ManifestError.badVersion
        }
        guard !m.entries.isEmpty else { throw ManifestError.emptyEntries }
        var seen = Set<String>()
        for e in m.entries where !seen.insert(e).inserted { throw ManifestError.duplicateEntry(e) }
        let hexSet = Set("0123456789abcdef")
        guard m.sha256.count == 64, m.sha256.allSatisfy({ hexSet.contains($0) }) else {
            throw ManifestError.badHashFormat
        }
        guard SHA256Pure.hex(m.canonicalPayload) == m.sha256 else { throw ManifestError.hashMismatch }
    }
}

/// 纯 Swift SHA-256（避免依赖 CryptoKit，便于 Linux 测试）。
enum SHA256Pure {
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]

    static func hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b+1]) << 16 | UInt32(msg[b+2]) << 8 | UInt32(msg[b+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

// MARK: - 手语 → 代说 桥接与功能开关

enum VoiceSignFeatureFlags {
    /// 手语代说默认关闭。只有 ASL 门控评测结果为 PASS 后才允许打开；
    /// 当前门控状态为 NOT_READY（无模型、无评测数据），请勿改为 true。
    static let signToSpeechDefault = false
}

enum SignGateStatus: String, Sendable { case notReady = "NOT_READY", pass = "PASS", fail = "FAIL" }

struct SignToSpeakBridge {
    var gate: SignRejectionGate
    var enabled: Bool = VoiceSignFeatureFlags.signToSpeechDefault
    var gateStatus: SignGateStatus = .notReady

    /// 识别结果只会进入 draft；返回给 UI 的提示。绝不调用 beginSpeaking。
    func route(_ candidates: [SignCandidate], handScore: Double?,
               into machine: inout SpeakForMeMachine) -> String {
        guard enabled, gateStatus == .pass, gate.thresholds.speakRequiresUserConfirm else { return "手语代说未开启（ASL 门控：\(gateStatus.rawValue)）" }
        switch gate.decide(candidates, handScore: handScore) {
        case .retry(let msg), .rejectNoSpeak(let msg): return msg
        case .accepted(let c):
            do { try machine.setDraft(c.label, source: .sign); return "请确认：\(c.label)" }
            catch { return "无法写入草稿" }
        }
    }
}

/// 测试/演示用识别器：按预设返回候选，不含模型。
struct MockSignRecognizer: SignRecognizer {
    var scripted: [SignCandidate]
    func recognize(frames: [SignFrame], topK: Int) throws -> [SignCandidate] {
        Array(scripted.sorted { $0.confidence > $1.confidence }.prefix(max(0, topK)))
    }
}
