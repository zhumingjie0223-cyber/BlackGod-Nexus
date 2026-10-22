import Foundation
import XCTest
@testable import BlackGodCore

/// 共享 fixture：Python 参考实现在运行时把签名包与期望判定生成到临时目录，Swift 逐字比对判定与原因。
final class NexusSkillMarketTests: XCTestCase {
    struct Case: Decodable { let name: String; let package: String; let expected_eval_hash: [String: String]?; let verdict: String; let reason: String }
    struct Doc: Decodable { let trusted_pubkeys_hex: [String]; let cases: [Case] }

    static var fixtureDir: URL!
    static var doc: Doc!
    static var setupError: String?

    override class func setUp() {
        super.setUp()
        let repo = ProcessInfo.processInfo.environment["BLACK_GOD_REPO_ROOT"] ?? FileManager.default.currentDirectoryPath
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skm-swift-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "\(repo)/tools/skill_market/make_fixtures.py", dir.path]
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { setupError = "make_fixtures.py exit \(p.terminationStatus)"; return }
            doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: dir.appendingPathComponent("cases.json")))
            fixtureDir = dir
        } catch { setupError = "\(error)" }
    }

    override class func tearDown() {
        if let d = fixtureDir { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }

    func run(_ name: String) throws -> (NexusSkillActivationResult, Case, NexusSkillMarketStore) {
        if let e = Self.setupError { throw XCTSkip("fixture 生成失败: \(e)") }
        let c = try XCTUnwrap(Self.doc.cases.first { $0.name == name })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skm-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try NexusSkillMarketStore(root: root, trustedPublicKeys: Self.doc.trusted_pubkeys_hex.map(hex),
                                              verifier: OpenSSLEd25519Verifier())
        let r = store.activate(packageAt: Self.fixtureDir.appendingPathComponent(c.package),
                               expectedEvalHash: c.expected_eval_hash, runGates: { _, _ in .pass })
        return (r, c, store)
    }

    func assertParity(_ name: String, _ verdict: NexusSkillVerdict, file: StaticString = #filePath, line: UInt = #line) throws {
        let (r, c, store) = try run(name)
        XCTAssertEqual(r.verdict, verdict, r.reason, file: file, line: line)
        XCTAssertEqual(r.verdict.rawValue, c.verdict, "与 Python 判定不一致", file: file, line: line)
        XCTAssertEqual(r.reason, c.reason, "与 Python 原因不一致", file: file, line: line)
        let ptr = store.pointer("demo.skill")
        XCTAssertEqual(ptr.current, verdict == .pass ? "1.0.0" : nil, file: file, line: line)
    }

    func testNormalPackPasses() throws { try assertParity("normal_pass", .pass) }
    func testTamperedFileFails() throws { try assertParity("tampered_file", .fail) }
    func testOtherSignerFails() throws { try assertParity("other_signer", .fail) }
    func testMissingEvalHashNotReady() throws { try assertParity("missing_eval_hash", .notReady) }
    func testEvalHashMismatchFails() throws { try assertParity("eval_hash_mismatch", .fail) }
    func testDangerousCapabilitiesFail() throws {
        for n in ["dangerous_shell", "dangerous_allow", "network_no_domain", "unknown_capability"] { try assertParity(n, .fail) }
        XCTAssertFalse(NexusSkillPackValidator.allowedCapabilities.contains("allowDangerous"))
    }
    func testPathTraversalFails() throws { for i in 0..<3 { try assertParity("path_traversal_\(i)", .fail) } }
    func testExtraFileAndSymlinkFail() throws { try assertParity("extra_file", .fail); try assertParity("symlink", .fail) }

    func testAllSharedCasesMatchPython() throws {
        if let e = Self.setupError { throw XCTSkip(e) }
        for c in Self.doc.cases {
            let (r, _, _) = try run(c.name)
            XCTAssertEqual("\(r.verdict.rawValue)|\(r.reason)", "\(c.verdict)|\(c.reason)", c.name)
        }
    }

    func testTamperedSignatureBytesRejectedByOpenSSL() throws {
        let (_, c, _) = try run("normal_pass")
        let m = Self.fixtureDir.appendingPathComponent(c.package).appendingPathComponent("manifest.json")
        let obj = try JSONDecoder().decode(NexusSkillJSON.self, from: Data(contentsOf: m)).object!
        var unsigned = obj; unsigned.removeValue(forKey: "signature")
        let payload = try NexusSkillCanonical.encode(.object(unsigned))
        let sig = Data(base64Encoded: obj["signature"]!.string!)!
        let pk = hex(Self.doc.trusted_pubkeys_hex[0])
        let v = OpenSSLEd25519Verifier()
        XCTAssertTrue(v.isValidSignature(sig, for: payload, publicKey: pk))
        var bad = sig; bad[0] ^= 0x01
        XCTAssertFalse(v.isValidSignature(bad, for: payload, publicKey: pk))
        XCTAssertFalse(v.isValidSignature(sig, for: payload + Data([0x20]), publicKey: pk))
    }

    func testCanonicalVectorMatchesPython() throws {
        let j = try JSONDecoder().decode(NexusSkillJSON.self, from: Data(#"{"b":1,"a":{"d":"0.5","c":[1,2]},"_comment":"x","z":"中\n"}"#.utf8))
        XCTAssertEqual(String(decoding: try NexusSkillCanonical.encode(j), as: UTF8.self), #"{"a":{"c":[1,2],"d":"0.5"},"b":1,"z":"中\n"}"#)
        let f = try JSONDecoder().decode(NexusSkillJSON.self, from: Data(#"{"x":0.5}"#.utf8))
        XCTAssertThrowsError(try NexusSkillCanonical.encode(f))
    }
}
