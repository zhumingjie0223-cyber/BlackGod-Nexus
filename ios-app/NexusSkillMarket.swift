import Foundation
import CryptoKit

// 技能市场：技能包校验与门控激活（门控规范 v1.4 §2 存档点② / §2.1；pack_spec v1.3 §1/§2/§4）。
// 判定与 tools/skill_market/skill_market.py 参考实现一致（共享 fixture 校验）。
// 本文件只做验证，不生成、不持有任何私钥。Ed25519 验签经 NexusSkillSignatureVerifier 注入：
// iOS 端可用 CryptoKit 的 Curve25519.Signing 实现；Linux 回归用 libcrypto EVP 实现。

enum NexusSkillVerdict: String, Codable, Equatable { case pass = "PASS", fail = "FAIL", notReady = "NOT_READY" }

/// 验签协议：Ed25519，publicKey 为 32 字节原始公钥，signature 为 64 字节。
protocol NexusSkillSignatureVerifier {
    func isValidSignature(_ signature: Data, for message: Data, publicKey: Data) -> Bool
}

struct NexusSkillActivationResult: Equatable {
    var verdict: NexusSkillVerdict
    var reason: String
    var packID: String?
    var version: String?
}

struct NexusSkillReject: Error { let verdict: NexusSkillVerdict; let reason: String
    static func fail(_ r: String) -> Self { .init(verdict: .fail, reason: r) }
}

// MARK: - JSON 值与规范化

indirect enum NexusSkillJSON: Decodable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String), array([NexusSkillJSON]), object([String: NexusSkillJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([NexusSkillJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: NexusSkillJSON].self)) }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var object: [String: NexusSkillJSON]? { if case .object(let o) = self { return o }; return nil }
    var array: [NexusSkillJSON]? { if case .array(let a) = self { return a }; return nil }
}

enum NexusSkillCanonical {
    static func isCommentKey(_ k: String) -> Bool { k.hasPrefix("//") || k == "_comment" || k == "$comment" }

    /// 键按 Unicode 码点排序、分隔符 `,` `:`、UTF-8、拒绝浮点、删注释键（与 Python json.dumps(sort_keys, ensure_ascii=False) 一致）。
    static func encode(_ v: NexusSkillJSON) throws -> Data {
        var out = ""
        try write(v, &out)
        return Data(out.utf8)
    }

    private static func write(_ v: NexusSkillJSON, _ o: inout String) throws {
        switch v {
        case .null: o += "null"
        case .bool(let b): o += b ? "true" : "false"
        case .int(let i): o += String(i)
        case .double: throw NexusSkillReject.fail("manifest 含浮点数，须写成十进制字符串")
        case .string(let s): writeString(s, &o)
        case .array(let a):
            o += "["
            for (i, x) in a.enumerated() { if i > 0 { o += "," }; try write(x, &o) }
            o += "]"
        case .object(let d):
            o += "{"
            let keys = d.keys.filter { !isCommentKey($0) }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            for (i, k) in keys.enumerated() {
                if i > 0 { o += "," }
                writeString(k, &o); o += ":"; try write(d[k]!, &o)
            }
            o += "}"
        }
    }

    private static func writeString(_ s: String, _ o: inout String) {
        o += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0C}": o += "\\f"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        o += "\""
    }
}

func nexusSkillSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - 校验

struct NexusSkillPackValidator {
    static let manifestName = "manifest.json"
    static let groups: Set<String> = ["skills", "experimental"]
    static let evalKeys = ["testset_lock_sha256", "gate_config_sha256", "gate_report_sha256"]
    static let allowedCapabilities: Set<String> = ["skill.storage.own", "ui.render", "ui.notify", "clipboard.write", "network.fetch"]
    static let dangerousPatterns = [
        "(?i)allowdangerous",
        "(?i)(^|[._])(shell|exec|spawn|subprocess|eval)([._]|$)",
        "(?i)skill\\.storage\\.(other|all|any|\\*)",
        "(?i)(other|cross)[._-]?skill",
    ]

    let trustedPublicKeys: [Data]
    let verifier: NexusSkillSignatureVerifier

    static func matches(_ pattern: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return true } // fail-closed
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func pyList(_ items: [String]) -> String { "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]" }

    // 包目录扫描：不跟随符号链接；符号链接 / 特殊文件 → FAIL。
    static func scanTree(_ root: URL) throws -> [String: URL] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: root.path), attrs[.type] as? FileAttributeType == .typeDirectory else {
            throw NexusSkillReject.fail("包根不是普通目录（可能是符号链接）")
        }
        var out: [String: URL] = [:]
        func walk(_ dir: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
                let url = dir.appendingPathComponent(name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let t = (try fm.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType
                if t == .typeSymbolicLink { throw NexusSkillReject.fail("包内含符号链接: \(rel)") }
                if t == .typeDirectory { try walk(url, rel); continue }
                if t != .typeRegular { throw NexusSkillReject.fail("包内含特殊文件: \(rel)") }
                out[rel] = url
            }
        }
        try walk(root, "")
        return out
    }

    static func safeRel(_ v: NexusSkillJSON?) throws -> String {
        guard let p = v?.string, !p.isEmpty else { throw NexusSkillReject.fail("文件路径为空或类型错误") }
        if p.contains("\\") || p.contains("\0") { throw NexusSkillReject.fail("非法路径字符: '\(p)'") }
        if p.hasPrefix("/") || matches("^[A-Za-z]:", p) { throw NexusSkillReject.fail("绝对路径: \(p)") }
        if p.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "" || $0 == "." || $0 == ".." }) {
            throw NexusSkillReject.fail("路径穿越或非规范路径: \(p)")
        }
        return p
    }

    static func checkSchema(_ m: [String: NexusSkillJSON]) throws {
        let req = ["pack_id", "kind", "version", "group", "author_key_fingerprint", "capabilities", "files", "signature"]
        let miss = req.filter { m[$0] == nil }
        if !miss.isEmpty { throw NexusSkillReject.fail("manifest 缺字段: \(miss.joined(separator: ","))") }
        if m["kind"]?.string != "skill" { throw NexusSkillReject.fail("kind 必须为 skill") }
        guard let pid = m["pack_id"]?.string, matches("^[a-z0-9][a-z0-9._-]{0,63}$", pid) else { throw NexusSkillReject.fail("pack_id 非法") }
        guard let ver = m["version"]?.string, matches("^\\d+\\.\\d+\\.\\d+$", ver) else { throw NexusSkillReject.fail("version 须为 semver x.y.z") }
        guard let g = m["group"]?.string, groups.contains(g) else { throw NexusSkillReject.fail("group 须为 ['experimental', 'skills']") }
        guard m["files"]?.array != nil, m["capabilities"]?.array != nil else { throw NexusSkillReject.fail("files / capabilities 须为数组") }
    }

    func verifySignature(_ m: [String: NexusSkillJSON]) throws {
        let fp = m["author_key_fingerprint"]?.string
        let keys = trustedPublicKeys.filter { nexusSkillSHA256Hex($0) == fp }
        if keys.isEmpty { throw NexusSkillReject.fail("签名者不在信任根中") }
        guard let s = m["signature"]?.string, let sig = Data(base64Encoded: s) else { throw NexusSkillReject.fail("签名编码错误") }
        var unsigned = m; unsigned.removeValue(forKey: "signature")
        let payload = try NexusSkillCanonical.encode(.object(unsigned))
        if keys.contains(where: { verifier.isValidSignature(sig, for: payload, publicKey: $0) }) { return }
        throw NexusSkillReject.fail("签名校验失败")
    }

    static func checkCapabilities(_ caps: [NexusSkillJSON]) throws {
        let domainRE = "^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$"
        for c in caps {
            guard let o = c.object, let cid = o["id"]?.string else { throw NexusSkillReject.fail("能力声明格式错误") }
            let blob = String(decoding: (try? NexusSkillCanonical.encode(c)) ?? Data(), as: UTF8.self)
            for p in dangerousPatterns where matches(p, cid) || matches(p, blob) { throw NexusSkillReject.fail("危险能力: \(cid)") }
            if !allowedCapabilities.contains(cid) { throw NexusSkillReject.fail("未知能力: \(cid)") }
            let extra = Set(o.keys).subtracting(["id", "domains"]).sorted()
            if !extra.isEmpty { throw NexusSkillReject.fail("能力 \(cid) 含未知字段: \(pyList(extra))") }
            if cid == "network.fetch" {
                guard let d = o["domains"]?.array, !d.isEmpty else { throw NexusSkillReject.fail("网络访问未声明域名") }
                for x in d { guard let s = x.string, matches(domainRE, s) else { throw NexusSkillReject.fail("非法域名（不允许通配/IP/端口）") } }
            } else if o["domains"] != nil { throw NexusSkillReject.fail("能力 \(cid) 不接受 domains") }
        }
    }

    static func verifyFiles(_ m: [String: NexusSkillJSON], _ tree: [String: URL]) throws {
        var declared: [String: [String: NexusSkillJSON]] = [:]
        for f in m["files"]?.array ?? [] {
            guard let o = f.object else { throw NexusSkillReject.fail("files[] 项格式错误") }
            let p = try safeRel(o["path"])
            if p == manifestName || declared[p] != nil { throw NexusSkillReject.fail("files[] 重复或包含 manifest: \(p)") }
            guard let h = o["sha256"]?.string, matches("^[0-9a-f]{64}$", h) else { throw NexusSkillReject.fail("sha256 格式错误: \(p)") }
            declared[p] = o
        }
        let actual = Set(tree.keys).subtracting([manifestName])
        let extra = actual.subtracting(declared.keys).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        if !extra.isEmpty { throw NexusSkillReject.fail("多余文件: \(pyList(extra))") }
        let missing = Set(declared.keys).subtracting(actual).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        if !missing.isEmpty { throw NexusSkillReject.fail("缺文件: \(pyList(missing))") }
        for p in declared.keys.sorted(by: { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }) {
            let data = try Data(contentsOf: tree[p]!)
            if nexusSkillSHA256Hex(data) != declared[p]!["sha256"]?.string { throw NexusSkillReject.fail("哈希不符: \(p)") }
            if let size = declared[p]!["size"], size != .int(Int64(data.count)) { throw NexusSkillReject.fail("大小不符: \(p)") }
        }
    }

    static func checkEvalHash(_ m: [String: NexusSkillJSON], expected: [String: String]?) throws {
        guard let eh = m["eval_hash"]?.object,
              evalKeys.allSatisfy({ !(eh[$0]?.string ?? "").isEmpty }) else {
            throw NexusSkillReject(verdict: .notReady, reason: "eval_hash 缺失或不完整")
        }
        guard let ex = expected, evalKeys.allSatisfy({ !(ex[$0] ?? "").isEmpty }) else {
            throw NexusSkillReject(verdict: .notReady, reason: "缺少发布记录 eval_hash，无法核对")
        }
        for k in evalKeys where eh[k]?.string != ex[k] { throw NexusSkillReject.fail("eval_hash 不符: \(k)") }
    }
}

// MARK: - 存储：current / previous 指针、原子切换、JSONL 日志

final class NexusSkillMarketStore {
    typealias RunGates = ([String: NexusSkillJSON], URL) -> NexusSkillVerdict
    struct Pointer: Codable, Equatable { var current: String?; var previous: String? }

    let root: URL
    let validator: NexusSkillPackValidator
    private let lock = NSLock()
    var logURL: URL { root.appendingPathComponent("activation_log.jsonl") }

    init(root: URL, trustedPublicKeys: [Data], verifier: NexusSkillSignatureVerifier) throws {
        self.root = root
        validator = NexusSkillPackValidator(trustedPublicKeys: trustedPublicKeys, verifier: verifier)
        for d in ["versions", "pointers", "staging"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    private func pointerURL(_ pid: String) -> URL { root.appendingPathComponent("pointers/\(pid).json") }
    func versionURL(_ pid: String, _ v: String) -> URL { root.appendingPathComponent("versions/\(pid)/\(v)") }

    func pointer(_ pid: String) -> Pointer {
        guard let d = try? Data(contentsOf: pointerURL(pid)), let p = try? JSONDecoder().decode(Pointer.self, from: d) else {
            return Pointer(current: nil, previous: nil)
        }
        return p
    }

    /// 原子写：同目录临时文件写入后 rename(2) 覆盖；读者只会看到旧值或新值。
    private func writePointer(_ pid: String, _ p: Pointer) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let tmp = root.appendingPathComponent("pointers/.ptr-\(UUID().uuidString)")
        try enc.encode(p).write(to: tmp)
        if rename(tmp.path, pointerURL(pid).path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw NexusSkillReject.fail("指针写入失败")
        }
    }

    private func log(_ action: String, _ r: NexusSkillActivationResult) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        var rec: [String: Any] = ["time": f.string(from: Date()), "action": action, "verdict": r.verdict.rawValue, "reason": r.reason]
        rec["pack_id"] = r.packID ?? NSNull(); rec["version"] = r.version ?? NSNull()
        guard var line = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: logURL) }
    }

    func activate(packageAt pkg: URL, expectedEvalHash: [String: String]?, runGates: RunGates) -> NexusSkillActivationResult {
        var res = NexusSkillActivationResult(verdict: .fail, reason: "未知错误")
        let fm = FileManager.default
        var staged: URL? = root.appendingPathComponent("staging/\(UUID().uuidString)")
        defer { if let s = staged { try? fm.removeItem(at: s) } }
        do {
            _ = try NexusSkillPackValidator.scanTree(pkg)
            try fm.copyItem(at: pkg, to: staged!)
            let tree = try NexusSkillPackValidator.scanTree(staged!)
            guard let mURL = tree[NexusSkillPackValidator.manifestName] else { throw NexusSkillReject.fail("缺 manifest.json") }
            guard let parsed = try? JSONDecoder().decode(NexusSkillJSON.self, from: Data(contentsOf: mURL)) else {
                throw NexusSkillReject.fail("manifest.json 解析失败")
            }
            guard let m = parsed.object else { throw NexusSkillReject.fail("manifest 不是对象") }
            res.packID = m["pack_id"]?.string; res.version = m["version"]?.string
            try NexusSkillPackValidator.checkSchema(m)
            try validator.verifySignature(m)                                       // 1
            try NexusSkillPackValidator.checkCapabilities(m["capabilities"]!.array!)
            try NexusSkillPackValidator.verifyFiles(m, tree)                       // 2
            try NexusSkillPackValidator.checkEvalHash(m, expected: expectedEvalHash) // 3
            let g = runGates(m, staged!)                                            // 4
            if g != .pass { throw NexusSkillReject(verdict: g, reason: "run_gates = \(g.rawValue)") }
            let pid = m["pack_id"]!.string!, ver = m["version"]!.string!
            lock.lock(); defer { lock.unlock() }                                    // 5
            let ptr = pointer(pid), dest = versionURL(pid, ver)
            if ptr.current == ver { throw NexusSkillReject.fail("该版本已是当前版本") }
            if fm.fileExists(atPath: dest.path) {
                if ptr.previous == ver { throw NexusSkillReject.fail("该版本为 previous，请用回滚") }
                try fm.removeItem(at: dest)
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staged!, to: dest); staged = nil
            try writePointer(pid, Pointer(current: ver, previous: ptr.current))
            if let old = ptr.previous, old != ver { try? fm.removeItem(at: versionURL(pid, old)) }
            res.verdict = .pass; res.reason = "激活成功"
        } catch let r as NexusSkillReject {
            res.verdict = r.verdict; res.reason = r.reason
        } catch {
            res.verdict = .fail; res.reason = "内部错误: \(type(of: error))"
        }
        log("activate", res)
        return res
    }

    func rollback(_ pid: String) -> NexusSkillActivationResult {
        lock.lock(); defer { lock.unlock() }
        var res = NexusSkillActivationResult(verdict: .fail, reason: "", packID: pid)
        let ptr = pointer(pid)
        if let prev = ptr.previous, FileManager.default.fileExists(atPath: versionURL(pid, prev).path),
           (try? writePointer(pid, Pointer(current: prev, previous: ptr.current))) != nil {
            res.verdict = .pass; res.version = prev; res.reason = "回滚: \(ptr.current ?? "None") -> \(prev)"
        } else { res.reason = "无可回滚的上一版本" }
        log("rollback", res)
        return res
    }
}
