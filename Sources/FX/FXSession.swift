import Foundation

public actor FXSession {
    public nonisolated let id: String
    private let agent: FXAgent
    private var closed = false
    private var activeTurn: FXTurn?

    init(id: String, agent: FXAgent) {
        self.id = id
        self.agent = agent
    }

    public func prompt(_ text: String) throws -> FXTurn {
        try prompt([.text(text)])
    }

    public func prompt(_ blocks: [FXPromptBlock]) throws -> FXTurn {
        guard !closed else { throw FXError.sessionClosed }
        guard activeTurn == nil else { throw FXError.turnInProgress }
        let turn = FXTurn(sessionID: id, agent: agent)
        activeTurn = turn
        turn.start(blocks: blocks)
        return turn
    }

    public func setModel(_ model: String) async throws {
        guard !closed else { throw FXError.sessionClosed }
        try await agent.setConfig(sessionID: id, id: "model", value: model)
    }

    public func setMode(_ mode: String) async throws {
        guard !closed else { throw FXError.sessionClosed }
        try await agent.setConfig(sessionID: id, id: "mode", value: mode)
    }

    public func remove() async throws {
        guard !closed else { return }
        activeTurn?.cancel()
        try await agent.remove(sessionID: id)
        closed = true
    }

    public func close() {
        activeTurn?.cancel()
        activeTurn = nil
        closed = true
    }

    func yield(_ update: FXUpdate) {
        activeTurn?.yield(update)
    }

    func finish(turn: FXTurn) {
        if activeTurn === turn { activeTurn = nil }
    }

    func fail(_ error: Error) {
        activeTurn?.fail(error)
        activeTurn = nil
        closed = true
    }

    func markClosed() {
        activeTurn?.cancel()
        activeTurn = nil
        closed = true
    }
}

public final class FXTurn: @unchecked Sendable {
    public let updates: AsyncThrowingStream<FXUpdate, Error>
    private let sessionID: String
    private let agent: FXAgent
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<FXUpdate, Error>.Continuation?
    private var task: Task<FXStopReason, Error>?

    init(sessionID: String, agent: FXAgent) {
        self.sessionID = sessionID
        self.agent = agent
        var stored: AsyncThrowingStream<FXUpdate, Error>.Continuation?
        updates = AsyncThrowingStream { continuation in stored = continuation }
        continuation = stored
    }

    func start(blocks: [FXPromptBlock]) {
        task = Task { [agent, sessionID] in
            do {
                let result = try await agent.prompt(sessionID: sessionID, blocks: blocks, turn: self)
                finish()
                return result
            } catch {
                fail(error)
                throw error
            }
        }
    }

    public var stopReason: FXStopReason {
        get async throws {
            guard let task = lock.withLock({ self.task }) else { throw FXError.invalidResponse }
            return try await task.value
        }
    }

    public func cancel() {
        lock.withLock { task?.cancel() }
        Task { [agent, sessionID] in await agent.cancel(sessionID: sessionID) }
    }

    func yield(_ update: FXUpdate) {
        _ = lock.withLock { continuation?.yield(update) }
    }

    func finish() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
