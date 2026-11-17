// The MCP stdio server the terminal agents launch. It relays bytes between the agent (stdin/stdout) and the
// running VocalCord app's socket, which answers the JSON-RPC itself. Usage: vocalcord-mcp <socket path>.
// The token file next to the socket is rewritten by every app launch and only this user can read it.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("vocalcord-mcp: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: vocalcord-mcp <socket path>") }
let socketPath = CommandLine.arguments[1]
let tokenURL = URL(filePath: socketPath).deletingLastPathComponent().appending(path: "bridge.token")
guard let token = try? String(contentsOf: tokenURL, encoding: .utf8) else { fail("Open VocalCord first.") }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("Socket path too long.") }
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard fd >= 0, connected == 0 else { fail("Open VocalCord first.") }
signal(SIGPIPE, SIG_IGN)

/// Copies bytes until `from` closes or a write fails.
@Sendable func pump(_ from: Int32, _ to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(from, &buffer, buffer.count)
        guard count > 0 else { return }
        var sent = 0
        while sent < count {
            let written = buffer[sent..<count].withUnsafeBytes { write(to, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            sent += written
        }
    }
}

let hello = Array((token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
guard write(fd, hello, hello.count) == hello.count else { fail("Open VocalCord first.") }
Thread.detachNewThread { [fd] in
    pump(STDIN_FILENO, fd)
    shutdown(fd, SHUT_WR)
}
pump(fd, STDOUT_FILENO)
exit(0)
