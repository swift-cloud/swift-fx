import CFX
import Foundation

final class NativeRuntime: @unchecked Sendable {
    enum RuntimeError: Swift.Error, LocalizedError {
        case create(Int32)
        case write(Int32)
        case invalidFetch

        var errorDescription: String? {
            switch self {
            case .create(let status): "fx runtime creation failed with status \(status)"
            case .write(let status): "fx runtime write failed with status \(status)"
            case .invalidFetch: "fx returned an invalid host fetch request"
            }
        }
    }

    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private var pumpTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private let session: URLSession

    init(configuration: FXConfiguration) throws {
        guard fx_abi_version() == FX_ABI_VERSION else {
            throw RuntimeError.create(Int32(FX_ERROR_INVALID_ARGUMENT.rawValue))
        }
        session = URLSession(configuration: .ephemeral)
        let credential = Data(configuration.apiKey.utf8)
        let model = configuration.model.map { Data($0.utf8) }
        let home = Data(configuration.home.path.utf8)
        let workspace = Data(configuration.workspace.path.utf8)
        let gateway = configuration.gatewayURL.map { Data($0.absoluteString.utf8) }

        var created: OpaquePointer?
        let status = credential.withUnsafeBytes { credentialBytes in
            home.withUnsafeBytes { homeBytes in
                workspace.withUnsafeBytes { workspaceBytes in
                    withOptionalBytes(model) { modelPointer, modelCount in
                        withOptionalBytes(gateway) { gatewayPointer, gatewayCount in
                            var options = fx_runtime_options_t(
                                abi_version: FX_ABI_VERSION,
                                credential: credentialBytes.bindMemory(to: UInt8.self).baseAddress,
                                credential_length: credentialBytes.count,
                                model: modelPointer,
                                model_length: modelCount,
                                home: homeBytes.bindMemory(to: UInt8.self).baseAddress,
                                home_length: homeBytes.count,
                                workspace_root: workspaceBytes.bindMemory(to: UInt8.self).baseAddress,
                                workspace_root_length: workspaceBytes.count,
                                gateway_chat_url: gatewayPointer,
                                gateway_chat_url_length: gatewayCount
                            )
                            return fx_runtime_create(&options, &created)
                        }
                    }
                }
            }
        }
        guard status == FX_OK, let created else {
            throw RuntimeError.create(Int32(status.rawValue))
        }
        pointer = created
    }

    deinit {
        pumpTask?.cancel()
        fetchTask?.cancel()
        if let pointer {
            fx_runtime_close_input(pointer)
            fx_runtime_abort_fetch(pointer)
        }
    }

    func start(onMessage: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (UInt8) -> Void) {
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var lineBuffer = Data()
            while !Task.isCancelled {
                guard let runtime = self.currentPointer() else { return }
                let available = fx_runtime_output_available(runtime)
                if available > 0 {
                    var bytes = Data(count: min(available, 1_048_576))
                    let count = bytes.withUnsafeMutableBytes { raw in
                        fx_runtime_drain(runtime, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
                    }
                    bytes.count = count
                    lineBuffer.append(bytes)
                    while let newline = lineBuffer.firstIndex(of: 0x0a) {
                        let line = lineBuffer[..<newline]
                        lineBuffer.removeSubrange(...newline)
                        if !line.isEmpty { onMessage(Data(line)) }
                    }
                }
                self.pollFetch(runtime)
                if fx_runtime_exited(runtime) {
                    onExit(fx_runtime_exit_code(runtime))
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func write(_ data: Data) throws {
        guard let runtime = currentPointer() else { throw RuntimeError.write(Int32(FX_ERROR_CLOSED.rawValue)) }
        let status = data.withUnsafeBytes { raw in
            fx_runtime_write(runtime, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard status == FX_OK else { throw RuntimeError.write(Int32(status.rawValue)) }
    }

    func closeInput() {
        guard let runtime = currentPointer() else { return }
        fx_runtime_close_input(runtime)
    }

    func abortFetch() {
        lock.lock()
        let runtime = pointer
        let task = fetchTask
        lock.unlock()
        task?.cancel()
        if let runtime { fx_runtime_abort_fetch(runtime) }
    }

    func stop() {
        lock.lock()
        guard let runtime = pointer else { lock.unlock(); return }
        pointer = nil
        let pump = pumpTask
        let fetch = fetchTask
        pumpTask = nil
        fetchTask = nil
        lock.unlock()
        pump?.cancel()
        fetch?.cancel()
        fx_runtime_close_input(runtime)
        fx_runtime_abort_fetch(runtime)
        fx_runtime_destroy(runtime)
        session.invalidateAndCancel()
    }

    private func currentPointer() -> OpaquePointer? {
        lock.withLock { pointer }
    }

    private func pollFetch(_ runtime: OpaquePointer) {
        lock.lock()
        let activeTask = fetchTask
        lock.unlock()
        if activeTask != nil { return }

        var requestBytes = Data(count: 8 * 1_024 * 1_024)
        let count = requestBytes.withUnsafeMutableBytes { raw in
            fx_runtime_take_fetch(runtime, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard count > 0 else { return }
        requestBytes.count = count
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.performFetch(requestBytes)
        }
        lock.withLock { fetchTask = task }
    }

    private func performFetch(_ data: Data) async {
        defer { lock.withLock { fetchTask = nil } }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let handle = object["handle"] as? Int,
            let method = object["method"] as? String,
            let urlString = object["url"] as? String,
            let url = URL(string: urlString),
            let headersJSON = object["headers"] as? String,
            let headerData = headersJSON.data(using: .utf8),
            let headers = try? JSONSerialization.jsonObject(with: headerData) as? [[String: String]],
            let bodyBase64 = object["body"] as? String
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = Data(base64Encoded: bodyBase64)
        for header in headers {
            if let name = header["name"], let value = header["value"] {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, let runtime = currentPointer() else { return }
            guard fx_runtime_start_fetch_response(runtime, Int32(handle), UInt16(http.statusCode)) == FX_FETCH_APPLIED else { return }
            var chunk = Data()
            chunk.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 64 * 1_024 {
                    guard await push(chunk, handle: Int32(handle)) else { return }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty, !(await push(chunk, handle: Int32(handle))) { return }
            if let runtime = currentPointer() { _ = fx_runtime_finish_fetch(runtime, Int32(handle)) }
        } catch {
            if let runtime = currentPointer(), fx_runtime_fetch_active(runtime, Int32(handle)) {
                _ = fx_runtime_fail_fetch(runtime, Int32(handle))
            }
        }
    }

    private func push(_ data: Data, handle: Int32) async -> Bool {
        while !Task.isCancelled {
            guard let runtime = currentPointer() else { return false }
            let result = data.withUnsafeBytes { raw in
                fx_runtime_push_fetch_response(runtime, handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            }
            if result == FX_FETCH_APPLIED { return true }
            if result == FX_FETCH_STALE { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

private func withOptionalBytes<T>(_ data: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    guard let data else { return body(nil, 0) }
    return data.withUnsafeBytes { raw in
        body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
