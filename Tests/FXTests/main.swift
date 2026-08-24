import Foundation
import FX

@main
struct FXSelfTest {
    static func main() async throws {
        guard FXConfiguration.defaultHome.lastPathComponent == "fx" else {
            throw SelfTestError.failed("unexpected default home")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "fx-swift-self-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let server = try MockGateway()
        try server.start()
        defer { server.stop() }

        let agent = try await FXAgent(configuration: .init(
            apiKey: "self-test-credential",
            workspace: temporary,
            home: temporary.appending(path: "home", directoryHint: .isDirectory),
            gatewayURL: URL(string: "http://127.0.0.1:\(server.port)/v3/ai/language-model")!
        ))
        let session = try await agent.createSession()
        guard !session.id.isEmpty else { throw SelfTestError.failed("empty session id") }
        let sessions = try await agent.listSessions()
        guard sessions.contains(where: { $0.id == session.id }) else {
            throw SelfTestError.failed("created session was not listed")
        }

        let turn = try await session.prompt("say hello")
        var output = ""
        for try await update in turn.updates {
            if case .assistantText(let text) = update { output += text }
        }
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "swift stream works" else {
            throw SelfTestError.failed("unexpected streamed output: \(output)")
        }
        guard try await turn.stopReason == .endTurn else {
            throw SelfTestError.failed("unexpected stop reason")
        }

        await agent.close()
        print("FX Swift self-test passed")
    }
}

enum SelfTestError: Error {
    case failed(String)
}

final class MockGateway: @unchecked Sendable {
    private let socketFD: Int32
    private var task: Task<Void, Never>?
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SelfTestError.failed("socket failed") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else { throw SelfTestError.failed("bind failed") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        socketFD = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() throws {
        task = Task.detached { [socketFD] in
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            _ = read(client, &buffer, buffer.count)
            let body = "data: {\"type\":\"text-delta\",\"delta\":\"swift stream works\"}\n\n" +
                "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"},\"usage\":{\"inputTokens\":{\"total\":1},\"outputTokens\":{\"total\":3}}}\n\n" +
                "data: [DONE]\n\n"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            response.withCString { pointer in _ = write(client, pointer, strlen(pointer)) }
        }
    }

    func stop() {
        task?.cancel()
        shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
    }
}
