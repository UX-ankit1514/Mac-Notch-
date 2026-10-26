import Darwin
import Foundation

public enum LocalSocketError: Error, Equatable {
    case pathTooLong
    case alreadyRunning
    case system(String, Int32)
}

/// Fills a sockaddr_un for `path`, or nil if the path doesn't fit.
private func makeAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setTimeout(_ fd: Int32, _ option: Int32, milliseconds: Int) {
    var tv = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Sends one payload over a Unix socket and closes. Used by `notch-hook`.
public enum LocalSocketClient {
    /// Returns false if nobody is listening or the write didn't complete in time.
    @discardableResult
    public static func send(_ data: Data, to path: String, timeoutMilliseconds: Int = 400) -> Bool {
        guard var addr = makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, SO_SNDTIMEO, milliseconds: timeoutMilliseconds)
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { return false }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        shutdown(fd, SHUT_WR)
        return ok
    }

    /// True when something is accepting connections at `path`.
    public static func isListening(at path: String) -> Bool {
        guard var addr = makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withSockaddr(&addr, { connect(fd, $0, $1) }) == 0
    }
}

/// Accepts one-shot connections on a Unix socket owned by this user. Each
/// connection carries a single payload, capped at `maxBytes`. Connections
/// from other users are refused using the kernel-reported peer uid.
public final class LocalSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Void

    public let path: String
    public let maxBytes: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "notch.socket.accept")
    private let readQueue = DispatchQueue(label: "notch.socket.read", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, maxBytes: Int = 16 * 1024, handler: @escaping Handler) {
        self.path = path
        self.maxBytes = maxBytes
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws(LocalSocketError) {
        guard var addr = makeAddress(path) else { throw .pathTooLong }
        if FileManager.default.fileExists(atPath: path) {
            if LocalSocketClient.isListening(at: path) { throw .alreadyRunning }
            unlink(path)    // stale socket from a previous run
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        // No umask juggling: umask is process-wide, so changing it would race
        // with files other threads create. The directory is already 0700.
        guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else { close(fd); throw .system("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw .system("listen", errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            unlink(path)
            listenFD = -1
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            readQueue.async { [maxBytes, handler] in
                defer { close(client) }
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                setTimeout(client, SO_RCVTIMEO, milliseconds: 500)
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while data.count <= maxBytes {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                guard !data.isEmpty, data.count <= maxBytes else { return }
                handler(data)
            }
        }
    }
}
