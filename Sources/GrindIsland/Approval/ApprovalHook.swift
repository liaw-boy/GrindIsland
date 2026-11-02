import Foundation
import Darwin

/// `GrindIsland --permission-hook`: the command Claude Code runs for its `PermissionRequest` hook. It forwards the
/// request to the running app and prints the user's decision. In every failure case (app not running, timeout, bad
/// input) it prints nothing and exits 0, so Claude Code shows its normal terminal prompt: this can never approve anything
/// by accident.
enum ApprovalHook {
    static let waitSeconds: Double = 100

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--permission-hook") else { return }
        let socketOverride = CommandLine.arguments.first(where: { $0.hasPrefix("--socket=") }).map { String($0.dropFirst(9)) }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let d = ask(input: input, path: socketOverride ?? ApprovalWire.socketPath()), let out = ApprovalWire.hookOutput(for: d) {
            FileHandle.standardOutput.write(out)
        }
        exit(0)
    }

    static func ask(input: Data, path: String) -> ApprovalDecision? {
        guard ApprovalRequest.parse(input) != nil else { return nil }           // not a request we understand
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } == 0
        }
        guard connected else { return nil }                                      // app not running
        var line = input
        while line.last == 0x0A || line.last == 0x0D { line.removeLast() }
        line.append(0x0A)
        guard line.withUnsafeBytes({ write(fd, $0.baseAddress, line.count) }) == line.count else { return nil }
        var tv = timeval(tv_sec: Int(waitSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 512)
        while reply.count < 512 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            reply.append(chunk, count: n)
            if reply.contains(0x0A) { break }
        }
        return ApprovalWire.parseReply(reply)
    }
}
