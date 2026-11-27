// Packages the 1024 px app artwork as a macOS icon.

import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let artwork = resources.appendingPathComponent("AppIcon-1024.png")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: executable, code: Int(process.terminationStatus))
    }
}

// ICNS uses the same chunk header for the container and each PNG representation.
func chunk(_ type: String, _ payload: Data) -> Data {
    var length = UInt32(payload.count + 8).bigEndian
    var data = Data(type.utf8)
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}

let representations = [
    (16, ["icp4"]), (32, ["icp5", "ic11"]), (64, ["ic12"]), (128, ["ic07"]),
    (256, ["ic08", "ic13"]), (512, ["ic09", "ic14"]), (1024, ["ic10"]),
]
var payload = Data()
for (pixels, types) in representations {
    let png: Data
    if pixels == 1024 {
        png = try Data(contentsOf: artwork)
    } else {
        let resized = temporary.appendingPathComponent("\(pixels).png")
        try run("/usr/bin/sips", [
            "-z", String(pixels), String(pixels), artwork.path, "--out", resized.path,
        ])
        png = try Data(contentsOf: resized)
    }
    for type in types {
        payload.append(chunk(type, png))
    }
}

try chunk("icns", payload).write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
print("wrote Resources/AppIcon.icns")
