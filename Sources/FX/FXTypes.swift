import Foundation

public struct FXConfiguration: Sendable {
    public var apiKey: String
    public var model: String?
    public var workspace: URL
    public var home: URL
    public var gatewayURL: URL?

    public init(
        apiKey: String,
        model: String? = nil,
        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        home: URL? = nil,
        gatewayURL: URL? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.workspace = workspace.standardizedFileURL
        self.home = (home ?? Self.defaultHome).standardizedFileURL
        self.gatewayURL = gatewayURL
    }

    public static var defaultHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fx", isDirectory: true)
    }
}

public enum FXError: Error, LocalizedError, Sendable {
    case invalidResponse
    case runtimeExited(UInt8)
    case remote(String)
    case sessionClosed
    case turnInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "fx returned an invalid response"
        case .runtimeExited(let code): "fx runtime exited with code \(code)"
        case .remote(let message): message
        case .sessionClosed: "fx session is closed"
        case .turnInProgress: "an fx turn is already in progress"
        }
    }
}

public enum FXPromptBlock: Sendable {
    case text(String)
    case resource(uri: String, text: String? = nil)

    var object: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .resource(let uri, let text):
            ["type": "resource", "resource": ["uri": uri, "text": text].compactMapValues { $0 }]
        }
    }
}

public enum FXStopReason: String, Sendable, Codable {
    case endTurn = "end_turn"
    case maxOutputTokens = "max_output_tokens"
    case maxModelTurns = "max_model_turns"
    case refused
    case cancelled
}

public enum FXToolCallKind: String, Sendable, Codable {
    case read, edit, delete, move, search, execute, think, fetch, other
}

public enum FXToolCallStatus: String, Sendable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public struct FXToolCall: Sendable {
    public let id: String
    public let title: String
    public let kind: FXToolCallKind
    public let status: FXToolCallStatus
}

public enum FXUpdate: Sendable {
    case assistantText(String)
    case userText(String)
    case toolCall(FXToolCall)
    case toolCallUpdate(id: String, status: FXToolCallStatus, text: String?)
    case availableCommands
    case sessionInfo
    case unknown(type: String, payload: Data)

    static func decode(_ object: [String: Any]) throws -> FXUpdate {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let type = object["sessionUpdate"] as? String else { return .unknown(type: "unknown", payload: data) }
        switch type {
        case "agent_message_chunk":
            let content = object["content"] as? [String: Any]
            return .assistantText(content?["text"] as? String ?? "")
        case "user_message_chunk":
            let content = object["content"] as? [String: Any]
            return .userText(content?["text"] as? String ?? "")
        case "tool_call":
            guard let id = object["toolCallId"] as? String else { return .unknown(type: type, payload: data) }
            return .toolCall(.init(
                id: id,
                title: object["title"] as? String ?? id,
                kind: FXToolCallKind(rawValue: object["kind"] as? String ?? "other") ?? .other,
                status: FXToolCallStatus(rawValue: object["status"] as? String ?? "pending") ?? .pending
            ))
        case "tool_call_update":
            guard let id = object["toolCallId"] as? String else { return .unknown(type: type, payload: data) }
            let content = object["content"] as? [[String: Any]]
            let nested = content?.first?["content"] as? [String: Any]
            return .toolCallUpdate(
                id: id,
                status: FXToolCallStatus(rawValue: object["status"] as? String ?? "failed") ?? .failed,
                text: nested?["text"] as? String
            )
        case "available_commands_update": return .availableCommands
        case "session_info_update": return .sessionInfo
        default: return .unknown(type: type, payload: data)
        }
    }
}

public struct FXPermissionRequest: @unchecked Sendable {
    public struct Option: Sendable {
        public let id: String
        public let name: String
    }

    public let sessionID: String
    public let toolCallID: String?
    public let title: String?
    public let options: [Option]
    let requestID: Int
}

public enum FXPermissionDecision: Sendable {
    case allowOnce
    case allowForSession
    case deny
    case cancel

    var optionID: String? {
        switch self {
        case .allowOnce: "allow_once"
        case .allowForSession: "allow_always"
        case .deny: "reject_once"
        case .cancel: nil
        }
    }
}

public typealias FXPermissionHandler = @Sendable (FXPermissionRequest) async -> FXPermissionDecision

public struct FXSessionSummary: Sendable {
    public let id: String
    public let updatedAt: Date?
}
