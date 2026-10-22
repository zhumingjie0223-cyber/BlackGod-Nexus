import Foundation
import XCTest
@testable import BlackGod

final class NexusOnDeviceAgentTests: XCTestCase {
    struct Case: Decodable { let name: String; let req: NexusOnDeviceRequest; let route: NexusOnDeviceRoute; let leaves: Bool }

    private var root: String {
        if let r = ProcessInfo.processInfo.environment["BLACK_GOD_REPO_ROOT"] { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    private func thresholds() throws -> NexusRejectThresholds {
        try NexusRejectThresholds.load(from: URL(fileURLWithPath: root + "/config/gates/asl_reject_thresholds.json"))
    }

    func testSharedGateConfigValues() throws {
        let t = try thresholds()
        XCTAssertEqual(t.schema, "blackgod.asl_reject_thresholds")
        XCTAssertEqual(t.status, "provisional")
        XCTAssertEqual(t.minConfidence, 0.85)
        XCTAssertEqual(t.minTop2Margin, 0.15)
        XCTAssertEqual(t.minHandScore, 0.5)
        XCTAssertTrue(t.speakRequiresUserConfirm)
    }

    func testUnknownStatusRefusedToLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad_thresholds.json")
        let bad = try String(contentsOfFile: root + "/config/gates/asl_reject_thresholds.json", encoding: .utf8)
            .replacingOccurrences(of: "\"status\":\"provisional\"", with: "\"status\":\"draft\"")
        try bad.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NexusRejectThresholds.load(from: url))
    }

    func testDecisionTableFixture() throws {
        let t = try thresholds()
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/tests/fixtures/ondevice-agent-cases.json"))
        for c in try JSONDecoder().decode([Case].self, from: data) {
            let d = NexusOnDeviceAgentPolicy.decide(c.req, thresholds: t)
            XCTAssertEqual(d.route, c.route, c.name)
            XCTAssertEqual(d.rawMediaLeavesDevice, c.leaves, c.name)
        }
    }

    func testNeverSpeaksUnconfirmedOrBelowAnyThreshold() throws {
        let t = try thresholds()
        let vals: [Double?] = [nil, 0.0, 0.1, 0.14, 0.15, 0.4, 0.5, 0.84, 0.85, 1.0]
        for conf in vals { for margin in vals { for hand in vals { for confirmed in [false, true] {
            let r = NexusOnDeviceRequest(input: .signVideo, wantedOutput: .speech, online: true, cloudMediaConsent: true,
                recognitionConfidence: conf, userConfirmed: confirmed, onDeviceReady: true, top2Margin: margin, handScore: hand)
            let d = NexusOnDeviceAgentPolicy.decide(r, thresholds: t)
            if d.route == .onDevice || d.route == .cloud {
                XCTAssertTrue(confirmed && (conf ?? -1) >= t.minConfidence && (margin ?? -1) >= t.minTop2Margin && (hand ?? -1) >= t.minHandScore)
            }
        }}}}
    }
}
