import Foundation
import Network
import Testing
@testable import SwiftTerminal

/// A loopback listener that keeps every request body it receives, so the
/// bytes the app actually puts on the wire can be compared between requests.
final class RecordingInteropServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RecordingInteropServer")
    private let lock = NSLock()
    private var bodies: [Data] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    var receivedBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        let portBox = PortBox()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                portBox.value = self.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.start(queue: queue)
        #expect(ready.wait(timeout: .now() + 5) == .success)
        return portBox.value
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() }
                else { self.receiveRequest(connection, accumulated: buffer) }
                return
            }
            // Keep only the entity body: the headers are not part of the
            // request the provider hashes. The body can arrive in later
            // segments, so wait for the announced length.
            let body = buffer[headerEnd.upperBound...]
            let announced = self.expectedLength(in: buffer[buffer.startIndex..<headerEnd.lowerBound])
            if body.count < announced, !complete {
                self.receiveRequest(connection, accumulated: buffer)
                return
            }
            self.lock.lock()
            self.bodies.append(Data(body))
            self.lock.unlock()
            self.respond(connection)
        }
    }

    private func expectedLength(in header: Data) -> Int {
        guard let text = String(data: header, encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return Int(value) ?? 0
        }
        return 0
    }

    private func respond(_ connection: NWConnection) {
        var body = ""
        body += "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
        body += "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":null}]}\n\n"
        body += "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}\n\n"
        body += "data: [DONE]\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            self.queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
        })
    }
}

/// Extracts the raw `"tools":[...]` slice from a request body without
/// re-serialising it, so a reshuffled key order stays visible.
func rawToolsSlice(in body: Data) -> String? {
    guard let text = String(data: body, encoding: .utf8) else { return nil }
    guard let marker = text.range(of: "\"tools\":") else { return nil }
    var index = marker.upperBound
    guard index < text.endIndex, text[index] == "[" else { return nil }
    let start = index
    var depth = 0
    var inString = false
    var escaped = false
    while index < text.endIndex {
        let character = text[index]
        if inString {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { inString = false }
        } else {
            if character == "\"" { inString = true }
            else if character == "[" { depth += 1 }
            else if character == "]" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
        }
        index = text.index(after: index)
    }
    return nil
}

@Test("The tool schema reaches the provider with a byte-identical layout on every request")
@MainActor
func toolSchemaBytesStayStableAcrossRequests() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AICachePrefix-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try RecordingInteropServer()
    let port = try server.start()
    defer { server.stop() }

    let model = try makeInteropModel(root: root, baseURL: "http://127.0.0.1:\(port)/v1")
    let profiles = model.profiles
    #expect(!profiles.isEmpty)
    #expect(await model.selectModel(profiles[0].id, sessionID: model.conversationID))
    #expect(await model.send("第一次"))
    await model.waitForCurrentTurnCompletion()
    #expect(await model.send("第二次"))
    await model.waitForCurrentTurnCompletion()

    let bodies = server.receivedBodies
    #expect(bodies.count >= 2)
    let slices = bodies.compactMap { rawToolsSlice(in: $0) }
    #expect(slices.count == bodies.count)
    #expect(!slices.isEmpty)
    // Every request must carry the same tool schema bytes, otherwise the
    // provider sees a different prompt prefix and the cached prefix stops
    // matching after the first reshuffled key.
    for slice in slices.dropFirst() {
        #expect(slice == slices[0])
    }
}

@Test("Compaction requests stay out of the conversation cache statistics")
func compactionUsageIsExcludedFromTurnStatistics() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AICacheCompaction-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AISessionStore(directory: directory)
    let session = try await store.create(target: .local(workingDirectory: nil), modelProfileID: nil)
    let turnID = UUID()

    func envelope(_ requestID: UUID, input: Int64, hit: Int64) -> AIUsageEnvelope {
        AIUsageNormalizer.decode(
            UsageWire(promptTokens: input, completionTokens: 1, totalTokens: input + 1,
                      promptCacheHitTokens: hit, promptCacheMissTokens: input - hit),
            context: AIUsageRequestContext(
                requestID: requestID, provider: "deepseek_chat", requestedModel: "test",
                profileID: UUID(), usageMapping: "deepseek_chat")
        )!
    }

    let conversation = AIRequestOwner(sessionID: session.id, turnID: turnID, maintenanceID: nil,
                                      stepIndex: 0, purpose: "conversation", attemptIndex: 0)
    try await store.settleUsage(owner: conversation, envelope: envelope(UUID(), input: 1_000, hit: 900))
    // An automatic compaction is attributed to the same turn but sends its own
    // summarisation prompt, so it never shares the conversation prefix.
    let compaction = AIRequestOwner(sessionID: session.id, turnID: turnID, maintenanceID: nil,
                                    stepIndex: 0, purpose: "auto_compaction", attemptIndex: 0)
    try await store.settleUsage(owner: compaction, envelope: envelope(UUID(), input: 40_000, hit: 0))

    let turnUsage = try await store.usageForTurn(sessionID: session.id, turnID: turnID)
    #expect(turnUsage.envelopes.count == 1)
    #expect(turnUsage.requestCount == 1)
    #expect(turnUsage.usage.totalInput.value == 1_000)
    #expect(turnUsage.cacheHitRate == 0.9)
}
