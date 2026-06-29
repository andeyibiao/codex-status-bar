import Foundation

enum CodexClientError: LocalizedError {
    case processNotStarted
    case processExited
    case invalidResponse
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .processNotStarted: "Codex app-server is not running."
        case .processExited: "Codex app-server exited."
        case .invalidResponse: "Codex app-server returned an invalid response."
        case .rpcError(let message): message
        }
    }
}

final class CodexAppServerClient {
    typealias JSONObject = [String: Any]

    var onNotification: ((JSONObject) -> Void)?
    var onServerRequest: ((JSONObject) -> Void)?

    private let queue = DispatchQueue(label: "codex.statusbar.appserver")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]

    func start() throws {
        if process?.isRunning == true {
            return
        }

        let process = Process()
        let codexPath = "/Applications/Codex.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: codexPath) {
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--stdio"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex", "app-server", "--stdio"]
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            self?.failPending(CodexClientError.processExited)
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readAvailableData(from: handle)
        }

        try process.run()
        self.process = process
        self.inputPipe = stdin
    }

    func stop() {
        process?.terminate()
        process = nil
        inputPipe = nil
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_status_bar",
                    "title": "Codex Status Bar",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
        try sendNotification(method: "initialized", params: [:])
    }

    func request(method: String, params: Any? = nil) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.process?.isRunning == true else {
                    continuation.resume(throwing: CodexClientError.processNotStarted)
                    return
                }

                let id = self.nextID
                self.nextID += 1
                self.pending[id] = continuation

                var message: JSONObject = [
                    "method": method,
                    "id": id
                ]
                if let params {
                    message["params"] = params
                }
                self.write(message)
            }
        }
    }

    func sendNotification(method: String, params: Any? = nil) throws {
        var message: JSONObject = ["method": method]
        if let params {
            message["params"] = params
        }
        queue.async {
            self.write(message)
        }
    }

    private func write(_ message: JSONObject) {
        guard let inputPipe else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            inputPipe.fileHandleForWriting.write(data)
            inputPipe.fileHandleForWriting.write(Data([0x0A]))
        } catch {
            if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            }
        }
    }

    private func readAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }

        queue.async {
            self.outputBuffer.append(data)
            while let newline = self.outputBuffer.firstIndex(of: 0x0A) {
                let line = self.outputBuffer.prefix(upTo: newline)
                self.outputBuffer.removeSubrange(...newline)
                self.handleLine(Data(line))
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? JSONObject
        else {
            return
        }

        if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? JSONObject {
                let message = error["message"] as? String ?? "Unknown Codex app-server error."
                continuation.resume(throwing: CodexClientError.rpcError(message))
            } else if let result = message["result"] as? JSONObject {
                continuation.resume(returning: result)
            } else {
                continuation.resume(returning: [:])
            }
            return
        }

        if message["id"] != nil {
            onServerRequest?(message)
        } else {
            onNotification?(message)
        }
    }

    private func failPending(_ error: Error) {
        queue.async {
            let continuations = self.pending.values
            self.pending.removeAll()
            continuations.forEach { $0.resume(throwing: error) }
        }
    }
}

extension CodexAppServerClient: @unchecked Sendable {}
