// Ed25519 key for signing update archives. The app embeds the public key
// (UpdateSignature.publicKey) and installs only archives signed with the private one.
//
//   swift scripts/update-key.swift generate <private-key-file>   writes the key, prints the public key
//   swift scripts/update-key.swift sign <private-key-file> <file> prints the file's signature
//
// Keys and signatures are base64 text. Keep the private key out of the repository.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func readKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("cannot read private key at \(path)") }
    return key
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "generate"):
    let path = args[2]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists; not overwriting") }
    let key = Curve25519.Signing.PrivateKey()
    let directory = (path as NSString).deletingLastPathComponent
    if !directory.isEmpty {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    guard FileManager.default.createFile(
        atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600])
    else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case (3, "public"):
    print(readKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
case (4, "sign"):
    guard let data = FileManager.default.contents(atPath: args[3]) else { fail("cannot read \(args[3])") }
    print(try readKey(args[2]).signature(for: data).base64EncodedString())
default:
    fail("usage: update-key.swift generate <key> | public <key> | sign <key> <file>")
}
