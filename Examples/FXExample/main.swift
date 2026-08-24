import Foundation
import FX

@main
struct FXExample {
    static func main() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"] else {
            print("Set AI_GATEWAY_API_KEY to run the live example.")
            return
        }

        let agent = try await FXAgent(
            configuration: .init(apiKey: apiKey),
            permissionHandler: { _ in .deny }
        )
        let session = try await agent.createSession()
        let turn = try await session.prompt("Reply with exactly: fx Swift SDK works")
        for try await update in turn.updates {
            if case .assistantText(let text) = update { print(text, terminator: "") }
        }
        print("\nStop reason: \(try await turn.stopReason.rawValue)")
        await agent.close()
    }
}
