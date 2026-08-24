import Foundation

public actor FXAgent {
    private let runtime: NativeRuntime
    private let permissionHandler: FXPermissionHandler?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var sessions: [String: FXSession] = [:]
    private var activeSessionID: String?
    private var closed = false

    public init(configuration: FXConfiguration, permissionHandler: FXPermissionHandler? = nil) async throws {
        try FileManager.default.createDirectory(at: configuration.home, withIntermediateDirectories: true)
        runtime = try NativeRuntime(configuration: configuration)
        self.permissionHandler = permissionHandler
        runtime.start(
            onMessage: { [weak self] data in Task { await self?.receive(data) } },
            onExit: { [weak self] code in Task { await self?.runtimeExited(code) } }
        )
        _ = try await request("initialize", params: ["protocolVersion": 1, "clientCapabilities": [:]])
    }

    public func createSession() async throws -> FXSession {
        if let activeSessionID { await sessions[activeSessionID]?.markClosed() }
        let response = try await request("session/new")
        return try makeSession(response)
    }

    public func openSession(id: String) async throws -> FXSession {
        if let activeSessionID { await sessions[activeSessionID]?.markClosed() }
        let response = try await request("session/load", params: ["sessionId": id])
        return try makeSession(["sessionId": id].merging(response) { _, new in new })
    }

    public func listSessions() async throws -> [FXSessionSummary] {
        let response = try await request("session/list")
        let values = response["sessions"] as? [[String: Any]] ?? []
        return values.compactMap { value in
            guard let id = value["id"] as? String ?? value["sessionId"] as? String else { return nil }
            let date: Date?
            if let millis = value["updatedAtMs"] as? Double {
                date = Date(timeIntervalSince1970: millis / 1_000)
            } else if let iso = value["updatedAt"] as? String {
                date = ISO8601DateFormatter().date(from: iso)
            } else {
                date = nil
            }
            return FXSessionSummary(id: id, updatedAt: date)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let activeSessionID { await sessions[activeSessionID]?.markClosed() }
        runtime.closeInput()
        try? await Task.sleep(nanoseconds: 20_000_000)
        runtime.stop()
        failPending(FXError.runtimeExited(0))
    }

    public nonisolated func abort() {
        runtime.abortFetch()
        runtime.stop()
    }

    func prompt(sessionID: String, blocks: [FXPromptBlock], turn: FXTurn) async throws -> FXStopReason {
        guard activeSessionID == sessionID else { throw FXError.sessionClosed }
        let response = try await request("session/prompt", params: [
            "sessionId": sessionID,
            "prompt": blocks.map(\.object),
        ])
        guard let raw = response["stopReason"] as? String, let reason = FXStopReason(rawValue: raw) else {
            throw FXError.invalidResponse
        }
        await sessions[sessionID]?.finish(turn: turn)
        return reason
    }

    func cancel(sessionID: String) {
        sendNotification("session/cancel", params: ["sessionId": sessionID])
        runtime.abortFetch()
    }

    func setConfig(sessionID: String, id: String, value: String) async throws {
        _ = try await request("session/set_config_option", params: [
            "sessionId": sessionID,
            "configId": id,
            "value": value,
        ])
    }

    func remove(sessionID: String) async throws {
        _ = try await request("session/remove", params: ["sessionId": sessionID])
        sessions[sessionID] = nil
        if activeSessionID == sessionID { activeSessionID = nil }
    }

    private func makeSession(_ response: [String: Any]) throws -> FXSession {
        guard let id = response["sessionId"] as? String else { throw FXError.invalidResponse }
        let session = FXSession(id: id, agent: self)
        sessions[id] = session
        activeSessionID = id
        return session
    }

    private func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw FXError.runtimeExited(0) }
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(_ method: String, params: [String: Any]) {
        try? send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        try runtime.write(data)
    }

    private func receive(_ data: Data) async {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if object["method"] as? String == "session/update",
           let params = object["params"] as? [String: Any],
           let sessionID = params["sessionId"] as? String,
           let update = params["update"] as? [String: Any],
           let decoded = try? FXUpdate.decode(update) {
            await sessions[sessionID]?.yield(decoded)
            return
        }

        if object["method"] as? String == "session/request_permission",
           let id = object["id"] as? Int,
           let params = object["params"] as? [String: Any] {
            await resolvePermission(id: id, params: params)
            return
        }

        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: FXError.remote(error["message"] as? String ?? "fx request failed"))
        } else if let result = object["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: FXError.invalidResponse)
        }
    }

    private func resolvePermission(id: Int, params: [String: Any]) async {
        let tool = params["toolCall"] as? [String: Any]
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> FXPermissionRequest.Option? in
            guard let optionID = option["optionId"] as? String else { return nil }
            return .init(id: optionID, name: option["name"] as? String ?? optionID)
        }
        let request = FXPermissionRequest(
            sessionID: params["sessionId"] as? String ?? "",
            toolCallID: tool?["toolCallId"] as? String,
            title: tool?["title"] as? String,
            options: options,
            requestID: id
        )
        let decision = await permissionHandler?(request) ?? .cancel
        let outcome: [String: Any] = if let optionID = decision.optionID {
            ["outcome": ["outcome": "selected", "optionId": optionID]]
        } else {
            ["outcome": ["outcome": "cancelled"]]
        }
        try? send(["jsonrpc": "2.0", "id": id, "result": outcome])
    }

    private func runtimeExited(_ code: UInt8) {
        closed = true
        failPending(FXError.runtimeExited(code))
        for session in sessions.values { Task { await session.fail(FXError.runtimeExited(code)) } }
    }

    private func failPending(_ error: Error) {
        let values = pending.values
        pending.removeAll()
        for continuation in values { continuation.resume(throwing: error) }
    }
}
