import Foundation
import AVFoundation
import Speech
import SwiftUI

/// LiveCaption：端上实时字幕。强制 requiresOnDeviceRecognition = true，绝不回落服务器。
/// Info.plist 需要：NSSpeechRecognitionUsageDescription（当前 project.yml 尚未声明，需权哥添加）、
/// NSMicrophoneUsageDescription（已存在）。需在 Xcode/真机验证。
@MainActor
final class LiveCaptionEngine: ObservableObject {
    enum Status: Equatable {
        case idle, requestingPermission, listening
        case refused(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var text: String = ""
    @Published private(set) var firstTokenLatency: TimeInterval?
    @Published var localeID: String = VoiceSignLocale.zhCN.rawValue

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var meter = FirstTokenLatencyMeter()

    func start() {
        stop()
        status = .requestingPermission
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor in
                guard auth == .authorized else { self.status = .refused("未授权语音识别"); return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in
                        ok ? self.begin() : (self.status = .refused("未授权麦克风"))
                    }
                }
            }
        }
    }

    private func begin() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        let decision = OnDeviceASRPolicy.evaluate(
            localeID: localeID,
            recognizerExists: recognizer != nil,
            recognizerAvailable: recognizer?.isAvailable ?? false,
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false)
        guard case .allowed = decision, let recognizer else {
            if case let .refused(reason) = decision { status = .refused(reason) }
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true   // 硬性：只在端上识别
        req.shouldReportPartialResults = true
        request = req
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audioEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
                req.append(buf)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            status = .failed("音频启动失败：\(error.localizedDescription)"); return
        }
        text = ""; firstTokenLatency = nil
        meter.start(at: ProcessInfo.processInfo.systemUptime)
        status = .listening
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let t = result.bestTranscription.formattedString
                    self.text = t
                    self.meter.observe(partialText: t, at: ProcessInfo.processInfo.systemUptime)
                    self.firstTokenLatency = self.meter.firstTokenLatency
                    if result.isFinal { self.stop() }
                }
                if let error { self.status = .failed(error.localizedDescription); self.stop(keepStatus: true) }
            }
        }
    }

    func stop(keepStatus: Bool = false) {
        if audioEngine.isRunning { audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        if !keepStatus, status == .listening { status = .idle }
    }
}

struct LiveCaptionView: View {
    @StateObject private var engine = LiveCaptionEngine()
    @State private var fontSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 12) {
            Picker("语言", selection: $engine.localeID) {
                Text("中文").tag(VoiceSignLocale.zhCN.rawValue)
                Text("English").tag(VoiceSignLocale.enUS.rawValue)
            }.pickerStyle(.segmented)
            ScrollView {
                Text(engine.text.isEmpty ? "……" : engine.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("livecaption.text")
            }
            .padding().background(Color.black)
            Slider(value: $fontSize, in: 24...96) { Text("字号") }
            statusLine
            if let l = engine.firstTokenLatency {
                Text(String(format: "首字延迟 %.0f ms（端上）", l * 1000)).font(.footnote)
            }
            Button(engine.status == .listening ? "停止" : "开始字幕") {
                engine.status == .listening ? engine.stop() : engine.start()
            }.buttonStyle(.borderedProminent)
        }
        .padding()
        .onDisappear { engine.stop() }
    }

    @ViewBuilder private var statusLine: some View {
        switch engine.status {
        case .refused(let r): Text("已拒绝启动：\(r)").foregroundStyle(.orange)
        case .failed(let r): Text("失败：\(r)").foregroundStyle(.red)
        case .listening: Text("端上识别中（不联网）").font(.footnote)
        default: EmptyView()
        }
    }
}
