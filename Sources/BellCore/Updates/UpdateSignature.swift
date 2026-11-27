import CryptoKit
import Foundation

/// Checks that an update archive was signed with the AgentBell release key
/// (`scripts/update-key.swift`). The app installs nothing that fails this.
public enum UpdateSignature {
    /// Ed25519 public key, base64. Its private half stays with whoever publishes releases.
    public static let publicKey = "Yzj2nd2frVL3NBrR68iVzHeXnys7hdmxnl/wxxC9/QA="

    /// `signature` is the base64 text of a `.sig` file.
    public static func isValid(_ archive: Data, signature: String, publicKey: String = publicKey) -> Bool {
        guard let signature = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(signature, for: archive)
    }
}
