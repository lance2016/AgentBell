import CryptoKit
import Foundation
import Testing
@testable import BellCore

struct UpdateSignatureTests {
    private let key = Curve25519.Signing.PrivateKey()
    private let archive = Data("AgentBell.app".utf8)

    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private func sign(_ data: Data) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    @Test func acceptsAnArchiveSignedWithTheKey() throws {
        #expect(UpdateSignature.isValid(archive, signature: try sign(archive), publicKey: publicKey))
    }

    @Test func toleratesTheTrailingNewlineOfASignatureFile() throws {
        #expect(UpdateSignature.isValid(archive, signature: try sign(archive) + "\n", publicKey: publicKey))
    }

    @Test func rejectsAChangedArchive() throws {
        let signature = try sign(archive)
        #expect(!UpdateSignature.isValid(Data("AgentBell.app!".utf8), signature: signature, publicKey: publicKey))
    }

    @Test func rejectsAnotherKeysSignature() throws {
        let other = try Curve25519.Signing.PrivateKey().signature(for: archive).base64EncodedString()
        #expect(!UpdateSignature.isValid(archive, signature: other, publicKey: publicKey))
    }

    @Test func rejectsGarbage() {
        #expect(!UpdateSignature.isValid(archive, signature: "not base64", publicKey: publicKey))
        #expect(!UpdateSignature.isValid(archive, signature: "", publicKey: publicKey))
        #expect(!UpdateSignature.isValid(archive, signature: "AAAA", publicKey: "AAAA"))
    }

    @Test func embeddedKeyIsUsable() {
        #expect(Data(base64Encoded: UpdateSignature.publicKey)?.count == 32)
    }
}
