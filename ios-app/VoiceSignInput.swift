import Foundation

/// SignInput：手语（仅指拼 + 词表）输入的应用层封装。不带模型。
/// 识别结果只进入 SpeakForMe 的 draft，必须用户确认后才会朗读。
/// thresholds 由调用方从 data/asl/sign_thresholds_v0.json 读取后传入。
/// 功能开关 VoiceSignFeatureFlags.signToSpeechDefault 默认 false；ASL 门控 PASS 前不得开启。
@MainActor
final class SignInputController {
    private let recognizer: SignRecognizer
    private var bridge: SignToSpeakBridge

    init(recognizer: SignRecognizer, vocabulary: Set<String>,
         thresholds: SignRejectionThresholds) {
        self.recognizer = recognizer
        self.bridge = SignToSpeakBridge(gate: SignRejectionGate(thresholds: thresholds, vocabulary: vocabulary))
    }

    func submit(frames: [SignFrame], handScore: Double, to speak: SpeakForMeEngine) -> String {
        guard let candidates = try? recognizer.recognize(frames: frames, topK: 5) else { return "识别失败" }
        let decision = bridge.gate.decide(candidates, handScore: handScore)
        guard bridge.enabled, bridge.gateStatus == .pass else {
            return "手语代说未开启（ASL 门控：\(bridge.gateStatus.rawValue)）"
        }
        switch decision {
        case .accepted(let c): speak.draft(c.label, source: .sign); return "请确认：\(c.label)"
        case .retry(let m), .rejectNoSpeak(let m): return m
        }
    }
}
