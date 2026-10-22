import Foundation
import AVFoundation
import SwiftUI

/// SpeakForMe：打字代说。只有经 SpeakForMeMachine 确认的文本才会交给 AVSpeechSynthesizer。
/// 需在 Xcode/真机验证发音与音频会话行为。
@MainActor
final class SpeakForMeEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var machine = SpeakForMeMachine()
    @Published var lastMessage: String = ""
    var languageCode = "zh-CN"
    private let synth = AVSpeechSynthesizer()

    override init() { super.init(); synth.delegate = self }

    func draft(_ text: String, source: SpeakSource = .typed) {
        do { try machine.setDraft(text, source: source); lastMessage = "草稿待确认" }
        catch { lastMessage = "草稿无效" }
    }

    func confirm(_ text: String) {
        do { try machine.confirm(text: text); lastMessage = "已确认" }
        catch { lastMessage = "确认失败：\(error)" }
    }

    /// 未确认直接拒绝并记录（审计在 machine.audit 中）。
    func speak() {
        do {
            let text = try machine.beginSpeaking()
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: languageCode)
            synth.speak(u)
        } catch {
            lastMessage = "拒绝朗读：文本未经确认"
        }
    }

    func stop() { synth.stopSpeaking(at: .immediate); machine.finishSpeaking() }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.machine.finishSpeaking() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.machine.finishSpeaking() }
    }
}

struct SpeakForMeView: View {
    @StateObject private var engine = SpeakForMeEngine()
    @State private var input = ""

    private var draftText: String? {
        if case let .draft(t, _) = engine.machine.state { return t }
        return nil
    }

    var body: some View {
        Form {
            Section("输入要说的话") {
                TextField("打字…", text: $input, axis: .vertical).font(.title2)
                Button("放入草稿") { engine.draft(input) }
            }
            Section("常用短语") {
                ForEach(CommonPhrases.zh, id: \.self) { p in
                    Button(p) { input = p; engine.draft(p, source: .phrase) }
                }
            }
            Section("确认后才会朗读") {
                if let d = draftText {
                    Text(d).font(.largeTitle.bold())
                    Button("确认这句话") { engine.confirm(d) }
                }
                Button("朗读") { engine.speak() }.accessibilityIdentifier("speakforme.speak")
                Text(engine.lastMessage).font(.footnote)
            }
        }
    }
}
