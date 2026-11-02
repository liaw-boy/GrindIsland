import Foundation
import Darwin

/// Listens on a user-only Unix socket for permission requests sent by the hook (see `ApprovalHook`), keeps each
/// connection open until the user decides in the island, then writes the decision back.
final class ApprovalServer: @unchecked Sendable {
    static let shared = ApprovalServer()

    /// Called on the main thread. `respond` may be called once; `cancelled` fires if the hook went away first.
    var onRequest: ((ApprovalRequest, _ respond: @escaping (ApprovalDecision) -> Void, _ onCancel: @escaping (@escaping () -> Void) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "com.grindisland.approval", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    func start(path: String = ApprovalWire.socketPath()) {
        queue.async { [self] in
            guard listenFD < 0 else { return }
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir, 0o700)   // also when it already existed
            // Another GrindIsland already answers on this socket: leave it alone instead of stealing its requests.
            if Self.isListening(path) { return }
            unlink(path)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
            }
            // Owner only; set on the file itself (umask is process-wide and would race other threads).
            // Connections are still checked with getpeereid below.
            guard ok, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); return }
            listenFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.accept() }
            src.resume()
            acceptSource = src
        }
    }

    /// Whether something accepts connections on the socket at `path` right now.
    static func isListening(_ path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
        }
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); return }   // same user only
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let conn = Connection(fd: fd, queue: queue) { [weak self] req, conn in self?.deliver(req, conn) }
        conn.start()
    }

    private func deliver(_ req: ApprovalRequest, _ conn: Connection) {
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.onRequest else { conn.finish(.terminal); return }
            handler(req, { conn.finish($0) }, { cb in conn.queue.async { conn.onGone = cb } })
        }
    }

    /// One hook connection: reads one JSON line, waits, answers once.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        let queue: DispatchQueue
        var source: DispatchSourceRead?
        var buffer = Data()
        var delivered = false
        var finished = false
        var onGone: (() -> Void)?
        let deliver: (ApprovalRequest, Connection) -> Void

        init(fd: Int32, queue: DispatchQueue, deliver: @escaping (ApprovalRequest, Connection) -> Void) {
            self.fd = fd; self.queue = queue; self.deliver = deliver
        }

        func start() {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [self] in readAvailable() }
            s.resume()
            source = s
            // A connection that never sends a request is dropped.
            queue.asyncAfter(deadline: .now() + 5) { [self] in if !delivered { close() } }
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { gone(); return }                      // the hook exited (it was answered in the terminal, or killed)
            if n < 0 { if errno != EAGAIN { gone() }; return }
            guard !delivered else { return }
            buffer.append(chunk, count: n)
            if buffer.count > ApprovalRequest.maxInputBytes { close(); return }
            if let nl = buffer.firstIndex(of: 0x0A) {
                delivered = true
                guard let req = ApprovalRequest.parse(buffer.subdata(in: buffer.startIndex..<nl)) else { close(); return }
                deliver(req, self)
            }
        }

        func finish(_ d: ApprovalDecision) {
            queue.async { [self] in
                guard !finished else { return }
                finished = true
                let data = ApprovalWire.reply(d)
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
                close()
            }
        }

        private func gone() {
            let cb = onGone
            onGone = nil
            close()
            if let cb = cb { DispatchQueue.main.async { cb() } }
        }

        private func close() {
            finished = true
            source?.cancel(); source = nil
            Darwin.close(fd)
        }
    }
}
