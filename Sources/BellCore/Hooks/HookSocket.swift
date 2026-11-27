import Darwin
import Foundation

/// The Unix socket between the hook program and the app. One connection carries one
/// line. The folder is 0700, so only the user can reach the socket.
public enum HookSocket {
    /// Sends one line and returns at once. When the app is not running the connect
    /// fails and nothing happens: a hook must never hold Claude Code up.
    public static func send(_ line: Data, to path: URL = BellPaths.socket) {
        guard let fd = connected(to: path) else { return }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
    }

    /// Whether an app is listening there now. A socket file left by a crash refuses.
    static func isListening(at path: URL) -> Bool {
        guard let fd = connected(to: path) else { return false }
        close(fd)
        return true
    }

    /// A connected descriptor the caller closes, or nil when nobody listens.
    private static func connected(to path: URL) -> Int32? {
        guard var address = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func address(for path: URL) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}

/// Listens on the socket and hands each well-formed event to `onEvent`, on a
/// background thread.
public final class HookServer: @unchecked Sendable {
    public enum StartError: Error, Equatable {
        case folder
        case bind
        /// Another copy of the app already listens on this socket.
        case inUse
    }

    private let path: URL
    private let onEvent: @Sendable (HookEvent) -> Void
    private var fd: Int32 = -1

    public init(path: URL = BellPaths.socket, onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    public func start() throws {
        let folder = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            throw StartError.folder
        }
        // Another copy of the app keeps its socket; one left by a crash is replaced.
        if HookSocket.isListening(at: path) { throw StartError.inUse }
        unlink(path.path)

        guard var address = HookSocket.address(for: path) else { throw StartError.bind }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.bind }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw StartError.bind
        }
        chmod(path.path, 0o600)
        self.fd = fd
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "AgentBell hook socket"
        thread.start()
    }

    public func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        unlink(path.path)
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            if let event = readLine(client).flatMap(HookEvent.decode(line:)) {
                onEvent(event)
            }
            close(client)
        }
    }

    /// Up to one line, with a short timeout so a stuck client cannot block the loop.
    private func readLine(_ client: Int32) -> Data? {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < HookEvent.maxLine {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(0x0A) { break }
        }
        guard let end = data.firstIndex(of: 0x0A) else { return nil }
        return data[data.startIndex..<end]
    }
}
