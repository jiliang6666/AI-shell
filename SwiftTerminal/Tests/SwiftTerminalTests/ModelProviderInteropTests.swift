import Foundation
import Network
import Testing
@testable import SwiftTerminal

/// A real TCP listener speaking the OpenAI-compatible SSE wire format, so the
/// client's HTTP/SSE transport is exercised over an actual socket instead of a
/// canned in-memory byte stream.
final class PortBox: @unchecked Sendable {
    var value: UInt16 = 0
}

final class SSEInteropServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var receivedBody = Data()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "SSEInteropServer")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
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

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = accumulated
            if let data { self.receivedBody.append(data); buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection)
            } else if !complete {
                self.receiveRequest(connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection) {
        var body = ""
        body += "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
        body += "data: {\"choices\":[{\"delta\":{\"content\":\"集成\"},\"finish_reason\":null}]}\n\n"
        body += "data: {\"choices\":[{\"delta\":{\"content\":\"成功\"},\"finish_reason\":null}]}\n\n"
        body += "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}\n\n"
        body += "data: [DONE]\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                connection.cancel()
            }
        })
    }
}

@MainActor
func makeInteropModel(root: URL, baseURL: String) throws -> TerminalAIModel {
    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "本地SSE", baseURL: baseURL, model: "sse-fixture", apiKey: "fixture-key")
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    let coordinator = AISessionCoordinator(store: store,
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    return model
}

@Test("OpenAI-compatible SSE over a real loopback socket streams content and usage into the turn")
@MainActor
func loopbackSSEInteropStreamsContentAndUsage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AISSEInterop-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try SSEInteropServer()
    let port = try server.start()
    defer { server.stop() }

    let model = try makeInteropModel(root: root, baseURL: "http://127.0.0.1:\(port)/v1")
    let profiles = model.profiles
    #expect(!profiles.isEmpty)
    #expect(await model.selectModel(profiles[0].id, sessionID: model.conversationID))
    #expect(await model.send("流式互操作检查"))
    await model.waitForCurrentTurnCompletion()

    let assistant = model.messages.last(where: { $0.role == "assistant" })
    #expect(assistant?.content == "集成成功")
    guard let lastMessage = model.messages.last, let turnID = lastMessage.turnID else {
        Issue.record("本轮缺少可结算的消息")
        return
    }
    let usage = model.usagePresentation(for: turnID)
    if let usage {
        print("DEBUG_USAGE rows=\(usage.rows.map { "\($0.label)=\($0.value)" }) total=\(usage.total)")
    }
    #expect(usage != nil)
    #expect(usage?.rows.first(where: { $0.label == "输出" })?.value.contains("3") == true)
    #expect(usage?.rows.first(where: { $0.label == "输入总量" })?.value.contains("12") == true)
}

@Test("A real configured provider streams a turn end to end", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_PROVIDER_TESTS"] == "1"))
@MainActor
func realProviderInteropStreamsTurn() async throws {
    let environment = ProcessInfo.processInfo.environment
    let baseURL = try #require(environment["AI_PROVIDER_BASE_URL"])
    let apiKey = try #require(environment["AI_PROVIDER_API_KEY"])
    let modelName = environment["AI_PROVIDER_MODEL"] ?? "gpt-4o-mini"
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIRealProvider-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let profileStore = ModelProfileStore(directory: root.appendingPathComponent("profiles"))
    let profile = ModelProfile(name: "真实施提供方", baseURL: baseURL, model: modelName, apiKey: apiKey)
    try profileStore.saveAll([profile], activeID: profile.id)
    let store = AISessionStore(directory: root.appendingPathComponent("sessions"))
    let coordinator = AISessionCoordinator(store: store,
        legacyArchiveURL: root.appendingPathComponent("legacy.json"), resumeExecutionHistory: {})
    let model = TerminalAIModel(terminalSessionID: UUID(), modelProfileStore: profileStore,
        sessionCoordinator: coordinator, archiveLoader: { [] }, archiveWriter: { _ in })
    #expect(await model.selectModel(profile.id, sessionID: model.conversationID))
    #expect(await model.send("只回复两个字母：OK"))
    await model.waitForCurrentTurnCompletion()
    let assistant = model.messages.last(where: { $0.role == "assistant" })
    #expect(assistant?.content?.isEmpty == false)
    #expect(model.errorMessage == nil)
}
