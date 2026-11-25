import Foundation

/// Unix domain socket server that receives messages from the bridge CLI.
///
/// Wire protocol: each message is a 4-byte big-endian uint32 length prefix
/// followed by exactly that many bytes of JSON. Replaces the previous
/// `n < bufSize` end-of-message heuristic which silently truncated any
/// payload that didn't fit in a single read (issue #1).
///
/// For `PermissionRequest`, the connection stays open after the message is
/// delivered; the response is then framed the same way back to the bridge.
final class SocketServer {
    static let defaultSocketPath = "/tmp/code-island.sock"
    private let socketPath = SocketServer.defaultSocketPath
    private let acceptQueue = DispatchQueue(label: "dev.codeisland.socket.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "dev.codeisland.socket.client", qos: .userInitiated, attributes: .concurrent)
    private var serverFd: Int32 = -1
    private var running = false
    /// Bumped on every start() so an accept loop left over from a previous
    /// start/stop cycle exits instead of serving the new socket.
    private var generation = 0
    /// Inode of the socket file we bound, so stop() only unlinks our own file
    /// (not one a newer server — e.g. a relaunched Code Island — bound since).
    private var boundInode: ino_t?

    var onMessage: ((BridgeMessage, ((BridgeResponse) -> Void)?, ((Data) -> Void)?) -> Void)?

    func start() {
        guard !running else { return }
        // Defense in depth: even with SO_NOSIGPIPE per-socket, install a
        // process-level ignore so any miss (or a third-party write to a
        // dead pipe) can't kill the app (issue #4).
        signal(SIGPIPE, SIG_IGN)

        // Create the fd BEFORE unlinking: if socket() fails (e.g. EMFILE) we
        // must not have deleted a path that a live server may still own.
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            print("[CodeIsland] Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Remove stale socket file
        unlink(socketPath)

        // Allow socket reuse
        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to Unix path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            for i in 0..<min(pathBytes.count, pathSize - 1) {
                rawPtr[i] = pathBytes[i]
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("[CodeIsland] Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverFd)
            serverFd = -1
            return
        }

        guard listen(serverFd, 16) == 0 else {
            print("[CodeIsland] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverFd)
            serverFd = -1
            return
        }

        var st = stat()
        boundInode = (stat(socketPath, &st) == 0) ? st.st_ino : nil

        running = true
        generation += 1
        let gen = generation
        let fd = serverFd
        Log.info("Socket server listening on \(socketPath)")

        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd, generation: gen)
        }
    }

    /// True while the server is listening.
    var isRunning: Bool { running }

    /// True while listening AND the socket path still is the file we bound.
    /// False once another server (e.g. a relaunched Code Island app) replaced
    /// it, or someone unlinked it (Code Island's stop() unlinks unconditionally).
    var ownsSocketPath: Bool {
        guard running, let inode = boundInode else { return false }
        var st = stat()
        return stat(socketPath, &st) == 0 && st.st_ino == inode
    }

    /// Outcome of probing a socket path with a real connect().
    enum ProbeResult {
        /// connect() succeeded: a server is accepting.
        case live
        /// Probe failed for a reason that says nothing about the path
        /// (EMFILE, EACCES, ...). Callers must leave the path alone.
        case unknown
        /// No file at the path (ENOENT).
        case gone
        /// File exists but nobody listens (ECONNREFUSED): stale, or a
        /// listener that is shutting down.
        case refused
    }

    /// Connects to `path` once and closes immediately; the other server just
    /// sees a client that hung up. Only call while not serving it ourselves.
    static func probe(at path: String = defaultSocketPath) -> ProbeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        // Can't probe (fd exhaustion): "unknown", never "stale", so the
        // caller doesn't unlink a live server's path.
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking so a misbehaving listener can't stall the main thread.
        // (On Darwin a full backlog on AF_UNIX fails with ECONNREFUSED, not
        // EAGAIN/EINPROGRESS, so it is indistinguishable from a stale file.)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            for i in 0..<min(pathBytes.count, pathSize - 1) {
                rawPtr[i] = pathBytes[i]
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .live }
        switch errno {
        case ENOENT: return .gone
        case ECONNREFUSED: return .refused
        default: return .unknown
        }
    }

    /// True unless the path is definitely free (no file, or a refusing file).
    /// "Unknown" counts as live so callers leave the path alone.
    static func hasLiveServer(at path: String = defaultSocketPath) -> Bool {
        switch probe(at: path) {
        case .live, .unknown: return true
        case .gone, .refused: return false
        }
    }

    func stop() {
        guard running || serverFd >= 0 else { return }
        running = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        var st = stat()
        if let inode = boundInode, stat(socketPath, &st) == 0, st.st_ino == inode {
            unlink(socketPath)
        }
        boundInode = nil
        Log.info("Socket server stopped")
    }

    // MARK: - Accept Loop

    private func acceptLoop(fd serverFd: Int32, generation gen: Int) {
        while running && generation == gen {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                let err = errno
                // EBADF / EINVAL = server socket closed during shutdown; exit cleanly.
                if err == EBADF || err == EINVAL || !running || generation != gen {
                    return
                }
                if running {
                    Log.error("Socket: accept error \(err): \(String(cString: strerror(err)))")
                }
                // Avoid 100% CPU spin on fd exhaustion / connection abort (issue #24).
                // Sleep longer when we're out of fds — backing off gives users a
                // chance to recover by closing other apps.
                if err == EMFILE || err == ENFILE {
                    usleep(250_000)
                } else if err != EINTR {
                    usleep(10_000)
                }
                continue
            }

            // Per-socket SIGPIPE suppression — if the peer disconnects between
            // when we accept and when we write the response, write() must
            // return EPIPE instead of raising SIGPIPE (issue #4).
            var on: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            Log.info("Socket: accepted client fd=\(clientFd)")
            clientQueue.async { [weak self] in
                self?.handleClient(clientFd)
            }
        }
    }

    // MARK: - Client Handling

    private func handleClient(_ fd: Int32) {
        // 30s ceiling on the framed read so a misbehaving peer can't park a worker.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // 1. Read 4-byte length prefix
        guard let len = readUInt32BE(fd: fd) else {
            Log.error("Socket: failed to read length prefix from fd=\(fd)")
            close(fd)
            return
        }
        // Sanity cap: refuse anything larger than 4 MB.
        guard len > 0, len <= 4 * 1024 * 1024 else {
            Log.error("Socket: implausible message length \(len) on fd=\(fd)")
            close(fd)
            return
        }

        // 2. Read exactly `len` bytes of payload
        guard let payload = readExactly(fd: fd, count: Int(len)) else {
            Log.error("Socket: short read of \(len)-byte payload on fd=\(fd)")
            close(fd)
            return
        }

        Log.info("Socket: read \(payload.count) bytes from fd=\(fd)")

        guard let message = try? JSONDecoder().decode(BridgeMessage.self, from: payload) else {
            Log.error("Socket: invalid JSON: \(String(data: payload.prefix(300), encoding: .utf8) ?? "?")")
            close(fd)
            return
        }

        let isPermission = message.hookEvent == "PermissionRequest"

        // Both responders are guaranteed to call close(fd). SessionStore
        // also guarantees one of them runs (issue #2).
        let respond: ((BridgeResponse) -> Void)? = isPermission ? { [weak self] response in
            Log.info("Socket: writing response to fd=\(fd)")
            if let responseData = try? JSONEncoder().encode(response) {
                self?.writeFramed(fd: fd, payload: responseData)
            }
            close(fd)
        } : nil

        let respondRaw: ((Data) -> Void)? = isPermission ? { [weak self] rawData in
            Log.info("Socket: writing raw response to fd=\(fd), \(rawData.count) bytes")
            self?.writeFramed(fd: fd, payload: rawData)
            close(fd)
        } : nil

        Log.info("Socket: parsed message source=\(message.source ?? "nil") hookEvent=\(message.hookEvent) session=\(message.sessionId.prefix(12)) permissionMode=\(message.permissionMode ?? "nil") toolName=\(message.toolName ?? "nil") effort=\(message.effortLevel ?? "nil") durationMs=\(message.durationMs.map(String.init) ?? "nil") userMessage=\(message.userMessage?.prefix(40) ?? "nil")")

        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(message, respond, respondRaw)
        }

        if !isPermission {
            close(fd)
        }
    }

    // MARK: - Framed read/write helpers

    /// Read exactly 4 bytes and decode as big-endian UInt32. Returns nil on
    /// short read or error.
    private func readUInt32BE(fd: Int32) -> UInt32? {
        guard let bytes = readExactly(fd: fd, count: 4) else { return nil }
        return bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            return (UInt32(p[0]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[2]) << 8) | UInt32(p[3])
        }
    }

    /// Read exactly `count` bytes. Loops until satisfied or a short/error read
    /// terminates. Returns nil if EOF arrives before `count` bytes.
    private func readExactly(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        let ok: Bool = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while got < count {
                let n = read(fd, base.advanced(by: got), count - got)
                if n > 0 {
                    got += n
                } else if n == 0 {
                    return false  // EOF
                } else if errno == EINTR {
                    continue
                } else {
                    return false  // error
                }
            }
            return true
        }
        return ok ? data : nil
    }

    /// Write a length-prefixed frame. Loops until all bytes are written.
    /// Errors are logged but not raised — caller has already done its job.
    private func writeFramed(fd: Int32, payload: Data) {
        var header = [UInt8](repeating: 0, count: 4)
        let len = UInt32(payload.count)
        header[0] = UInt8((len >> 24) & 0xFF)
        header[1] = UInt8((len >> 16) & 0xFF)
        header[2] = UInt8((len >> 8) & 0xFF)
        header[3] = UInt8(len & 0xFF)
        writeAll(fd: fd, bytes: header, count: 4)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                writeAll(fd: fd, bytes: base.assumingMemoryBound(to: UInt8.self), count: payload.count)
            }
        }
    }

    private func writeAll(fd: Int32, bytes: UnsafePointer<UInt8>, count: Int) {
        var sent = 0
        while sent < count {
            let n = write(fd, bytes.advanced(by: sent), count - sent)
            if n > 0 {
                sent += n
            } else if errno == EINTR {
                continue
            } else {
                let err = errno
                if err != EPIPE {
                    Log.error("Socket: write failed at \(sent)/\(count): \(String(cString: strerror(err)))")
                }
                return
            }
        }
    }
}
