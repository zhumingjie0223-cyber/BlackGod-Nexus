import Foundation

/// 端上 Agent 路由策略（纯 Foundation，可在 Linux 上验证）。
/// 原则：能在手机上做的就不出手机；原始视频/音频默认不离开设备；
/// 本体只出文字和语音，不出图片和视频；手语识别没把握时不代说。
enum NexusOnDeviceModality: String, Codable, CaseIterable { case text, image, video, audio, signVideo }
enum NexusOnDeviceOutput: String, Codable { case text, speech, image, video }
enum NexusOnDeviceRoute: String, Codable { case onDevice, cloud, refuse, askRetry, needsConfirmation }

struct NexusOnDeviceRequest: Codable, Equatable {
    var input: NexusOnDeviceModality
    var wantedOutput: NexusOnDeviceOutput
    var online: Bool
    /// 用户是否明确同意把原始媒体上传到云端模型。
    var cloudMediaConsent: Bool
    /// 手语/语音识别置信度，0...1；文字输入为 nil。
    var recognitionConfidence: Double?
    /// 用户是否已确认识别出的文字（代说前必需）。
    var userConfirmed: Bool
    /// 端上能力是否就绪（例如手语模型未过门控时为 false）。
    var onDeviceReady: Bool
}

struct NexusOnDeviceDecision: Codable, Equatable {
    var route: NexusOnDeviceRoute
    var reason: String
    /// 是否允许原始媒体离开设备。
    var rawMediaLeavesDevice: Bool
}

enum NexusOnDeviceAgentPolicy {
    /// 低于此置信度只提示重打，绝不代说。阈值待真机实测后由门控锁定。
    static let minSpeakConfidence = 0.80

    static func decide(_ r: NexusOnDeviceRequest) -> NexusOnDeviceDecision {
        if r.wantedOutput == .image || r.wantedOutput == .video {
            return .init(route: .refuse, reason: "本体不能生成图片或视频", rawMediaLeavesDevice: false)
        }
        let isRecognition = r.input == .signVideo || r.input == .audio
        if isRecognition, (r.recognitionConfidence ?? 0) < minSpeakConfidence {
            // 识别类输入缺置信度按没把握处理。
            return .init(route: .askRetry, reason: "没看清，请再打一次", rawMediaLeavesDevice: false)
        }
        if r.input == .signVideo && r.wantedOutput == .speech && !r.userConfirmed {
            return .init(route: .needsConfirmation, reason: "代说前需用户确认文字", rawMediaLeavesDevice: false)
        }
        if r.onDeviceReady {
            return .init(route: .onDevice, reason: "端上就绪，不出手机", rawMediaLeavesDevice: false)
        }
        let isMedia = r.input != .text
        guard r.online else {
            return .init(route: .refuse, reason: "端上未就绪且离线", rawMediaLeavesDevice: false)
        }
        if isMedia && !r.cloudMediaConsent {
            return .init(route: .refuse, reason: "端上未就绪，且未同意上传原始媒体", rawMediaLeavesDevice: false)
        }
        return .init(route: .cloud, reason: "端上未就绪，按用户同意走云端", rawMediaLeavesDevice: isMedia)
    }
}
