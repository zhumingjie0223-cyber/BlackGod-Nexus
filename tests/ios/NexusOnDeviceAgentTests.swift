import Foundation
import XCTest
@testable import BlackGod

final class NexusOnDeviceAgentTests: XCTestCase {
    struct Case: Decodable { let name: String; let req: NexusOnDeviceRequest; let route: NexusOnDeviceRoute; let leaves: Bool }

    func testDecisionTableFixture() throws {
        let root = ProcessInfo.processInfo.environment["BLACK_GOD_REPO_ROOT"] ?? FileManager.default.currentDirectoryPath
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/tests/fixtures/ondevice-agent-cases.json"))
        for c in try JSONDecoder().decode([Case].self, from: data) {
            let d = NexusOnDeviceAgentPolicy.decide(c.req)
            XCTAssertEqual(d.route, c.route, c.name)
            XCTAssertEqual(d.rawMediaLeavesDevice, c.leaves, c.name)
        }
    }

    func testNeverSpeaksUnconfirmedOrLowConfidenceSign() {
        for conf in stride(from: 0.0, through: 1.0, by: 0.05) {
            for confirmed in [false, true] {
                let r = NexusOnDeviceRequest(input: .signVideo, wantedOutput: .speech, online: true, cloudMediaConsent: true,
                    recognitionConfidence: conf, userConfirmed: confirmed, onDeviceReady: true)
                let d = NexusOnDeviceAgentPolicy.decide(r)
                if d.route == .onDevice || d.route == .cloud {
                    XCTAssertTrue(confirmed && conf >= NexusOnDeviceAgentPolicy.minSpeakConfidence)
                }
            }
        }
    }
}
