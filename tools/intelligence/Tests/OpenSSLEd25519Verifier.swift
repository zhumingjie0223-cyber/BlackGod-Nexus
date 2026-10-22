import Foundation
import COpenSSL
@testable import BlackGodCore

/// Linux 底层实现：libcrypto EVP Ed25519 验签（见 Support/COpenSSL/ed25519.c）。只验证，不生成密钥。
/// iOS 端替换为 CryptoKit：
///   (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey))?.isValidSignature(signature, for: message) ?? false
struct OpenSSLEd25519Verifier: NexusSkillSignatureVerifier {
    func isValidSignature(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        return publicKey.withUnsafeBytes { pk in
            message.withUnsafeBytes { msg in
                signature.withUnsafeBytes { sig in
                    black_god_ed25519_verify(pk.bindMemory(to: UInt8.self).baseAddress,
                                             msg.bindMemory(to: UInt8.self).baseAddress, msg.count,
                                             sig.bindMemory(to: UInt8.self).baseAddress, sig.count) == 1
                }
            }
        }
    }
}
