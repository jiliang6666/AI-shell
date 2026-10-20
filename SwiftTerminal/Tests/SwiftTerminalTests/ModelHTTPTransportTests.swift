import Foundation
import Testing
@testable import SwiftTerminal

private actor QueuedAIHTTPTransport: AIHTTPStreamTransport {
    private var responses: [AIHTTPStreamResponse]
    private var requests: [URLRequest] = []

    init(responses: [AIHTTPStreamResponse]) {
        self.responses = responses
    }

    func stream(for request: URLRequest) async throws -> AIHTTPStreamResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    func requestCount() -> Int { requests.count }

    func capturedRequests() -> [URLRequest] { requests }

    func replaceResponses(_ responses: [AIHTTPStreamResponse]) {
        self.responses = responses
    }
}

@Test("Model streaming requests have a finite 120-second idle timeout")
@MainActor
func modelStreamRequestHasBoundedIdleTimeout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIBoundedHTTPTimeout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, transport, _) = try await makeHTTPModel(directory: directory, status: 200, retryAfter: nil)
    defer { model.stop() }
    await transport.replaceResponses([
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])

    #expect(await model.send("Check the model request timeout."))
    await model.waitForCurrentTurnCompletion()

    let request = try #require(await transport.capturedRequests().first)
    #expect(AIHTTPStreamTimeoutPolicy.requestIdleInterval == 120)
    #expect(request.timeoutInterval == AIHTTPStreamTimeoutPolicy.requestIdleInterval)
    #expect(model.errorMessage == nil)
    #expect(model.messages.last?.content == "done")
}

@Test("A task continues beyond the former model, tool-round and HTTP request limits", arguments: [false, true])
@MainActor
func modelTurnContinuesWithoutArtificialStepLimit(_ executeCommands: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIUnlimitedTurn-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: directory, status: 200, retryAfter: nil)
    defer { model.stop() }
    let rounds = 40
    var responses: [AIHTTPStreamResponse] = []
    for step in 0..<rounds {
        let arguments = executeCommands ? #"{"command":"printf fixture","purpose":"fixture"}"#
            : #"{"operation":"fixture_invalid"}"#
        let delta: [String: Any] = ["choices": [["delta": ["tool_calls": [[
            "index": 0, "id": "call-\(step)", "type": "function",
            "function": ["name": executeCommands ? "run_command" : "run_inspection", "arguments": arguments]
        ]]], "finish_reason": "tool_calls"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: delta), as: UTF8.self)
        responses.append(httpStreamResponse(status: 200, body: "data: \(json)\n\ndata: [DONE]\n\n"))
    }
    responses.append(httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"all steps completed\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"))
    await transport.replaceResponses(responses)
    var executed = 0
    if executeCommands {
        #expect(await model.setPermission(.terminalOnly, sessionID: model.conversationID))
        let generation = UUID()
        model.terminalBindingProvider = { TerminalBindingStatus(available: true, generation: generation, reason: nil) }
        model.terminalCommandRunner = { _ in
            executed += 1
            return ShellCommandResult(output: "fixture", exitCode: 0, timedOut: false)
        }
    }
    #expect(await model.send("Complete every fixture step."))
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while model.isWorking, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isWorking)
    #expect(model.errorMessage == nil)
    #expect(await transport.requestCount() == rounds + 1)
    #expect(model.messages.last?.content == "all steps completed")
    #expect(model.messages.filter { $0.role == "tool" }.count == rounds)
    #expect(executed == (executeCommands ? rounds : 0))
    let snapshot = try await coordinator.store.load(sessionID: model.conversationID)
    #expect(snapshot.turnStates.values.contains("completed"))
}

@Test("A complete response may contain more than sixteen serial tool calls")
@MainActor
func modelAcceptsLargerToolBatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AILargerBatch-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, transport, _) = try await makeHTTPModel(directory: directory, status: 200, retryAfter: nil)
    defer { model.stop() }
    let calls: [[String: Any]] = (0..<20).map { index in
        ["index": index, "id": "batch-\(index)", "type": "function",
         "function": ["name": "run_inspection", "arguments": #"{"operation":"fixture_invalid"}"#]]
    }
    let delta: [String: Any] = ["choices": [["delta": ["tool_calls": calls], "finish_reason": "tool_calls"]]]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: delta), as: UTF8.self)
    await transport.replaceResponses([
        httpStreamResponse(status: 200, body: "data: \(json)\n\ndata: [DONE]\n\n"),
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"batch completed\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])
    #expect(await model.send("Handle the full batch."))
    await model.waitForCurrentTurnCompletion()
    #expect(model.errorMessage == nil)
    #expect(model.messages.filter { $0.role == "tool" }.count == 20)
    #expect(model.messages.last?.content == "batch completed")
}

private actor PausedRetrySleeper {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func sleep(for _: TimeInterval) async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private func questionToolResponse(includePrematureCommand: Bool = false, invalid: Bool = false) throws -> AIHTTPStreamResponse {
    let arguments = invalid ? #"{"question":"","reason":"","options":[]}"# : #"{"question":"使用哪种安装方式？","reason":"两种方式会影响已有配置，需要你选择。","options":[{"id":"keep","label":"保留现有配置","description":"合并必要的新配置。"},{"id":"replace","label":"重新配置","description":"替换原配置。"}],"recommended_option_id":"keep"}"#
    var calls: [[String: Any]] = [["index": 0, "id": "question-call", "type": "function", "function": ["name": "ask_user", "arguments": arguments]]]
    if includePrematureCommand {
        calls.append(["index": 1, "id": "premature-command", "type": "function", "function": ["name": "run_command", "arguments": #"{"command":"printf should-not-run","purpose":"fixture"}"#]])
    }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": calls], "finish_reason": "tool_calls"]]]), as: UTF8.self)
    return httpStreamResponse(status: 200, body: "data: \(json)\n\ndata: [DONE]\n\n")
}

@Test("ask_user pauses without dispatching commands and a real answer resumes the same task", arguments: [false, true])
@MainActor
func askUserAnswerResumesTask(_ freeform: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuestionFlow-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil)
    defer { model.stop() }
    #expect(await model.setPermission(.terminalOnly, sessionID: model.conversationID))
    let generation = UUID()
    model.terminalBindingProvider = { TerminalBindingStatus(available: true, generation: generation, reason: nil) }
    var executions = 0
    model.terminalCommandRunner = { _ in
        executions += 1
        return ShellCommandResult(output: "fixture", exitCode: 0, timedOut: false)
    }
    await transport.replaceResponses([
        try questionToolResponse(includePrematureCommand: true),
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"continued with your choice\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])
    #expect(await model.send("Install the fixture."))
    await model.waitForCurrentTurnCompletion()
    let question = try #require(model.pendingQuestion)
    #expect(!model.isWorking)
    #expect(model.isWaitingForUser)
    #expect(!model.canSelectModel)
    #expect(!(await model.send("Do not replace the waiting question.")))
    #expect(await transport.requestCount() == 1)
    #expect(executions == 0)
    #expect(try await coordinator.store.load(sessionID: model.conversationID).turnStates[question.turnID] == "open")
    #expect(!(await model.answerQuestion(id: UUID(), optionID: "keep")))
    #expect(!(await model.answerQuestion(id: question.id, optionID: "missing")))
    #expect(!(await model.answerQuestion(id: question.id, text: "  ")))
    let accepted = await model.answerQuestion(id: question.id, optionID: freeform ? nil : "keep", text: freeform ? "仅更新缺少的依赖" : "")
    #expect(accepted)
    #expect(!(await model.answerQuestion(id: question.id, optionID: "replace")))
    await model.waitForCurrentTurnCompletion()
    #expect(model.pendingQuestion == nil)
    #expect(!model.isWaitingForUser)
    #expect(executions == 0)
    #expect(model.messages.last?.content == "continued with your choice")
    let responses = model.messages.filter { $0.toolCallID == question.callID }
    #expect(responses.count == 1)
    let answer = try JSONDecoder().decode(AIUserAnswer.self, from: Data(try #require(responses.first?.content).utf8))
    #expect(answer.selectedOptionID == (freeform ? nil : "keep"))
    #expect(answer.text == (freeform ? "仅更新缺少的依赖" : nil))
    #expect(responses.first?.requestID == question.requestID)
    #expect(try await coordinator.store.load(sessionID: model.conversationID).turnStates[question.turnID] == "completed")
    let requests = await transport.capturedRequests()
    let body = try #require(requests.first?.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "ask_user" })
}

@Test("Cancelling a waiting question rejects stale answers and sends no follow-up request")
@MainActor
func askUserCancellationDoesNotResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuestionCancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil)
    await transport.replaceResponses([try questionToolResponse()])
    #expect(await model.send("fixture"))
    await model.waitForCurrentTurnCompletion()
    let question = try #require(model.pendingQuestion)
    model.stop()
    #expect(model.pendingQuestion == nil)
    #expect(!(await model.answerQuestion(id: question.id, optionID: "keep")))
    #expect(await transport.requestCount() == 1)
    #expect(model.messages.filter { $0.toolCallID == question.callID }.count == 1)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while try await coordinator.store.load(sessionID: model.conversationID).turnStates[question.turnID] == "open", ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await coordinator.store.load(sessionID: model.conversationID).turnStates[question.turnID] == "cancelled")
}

@Test("Malformed questions return a tool error so the assistant can repair them without halting")
@MainActor
func invalidAskUserDoesNotHaltTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIQuestionRepair-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, _, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil)
    defer { model.stop() }
    await transport.replaceResponses([
        try questionToolResponse(invalid: true),
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"repaired\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])
    #expect(await model.send("fixture"))
    await model.waitForCurrentTurnCompletion()
    #expect(model.pendingQuestion == nil)
    #expect(model.errorMessage == nil)
    #expect(model.messages.last?.content == "repaired")
    #expect(await transport.requestCount() == 2)
}

@Test("Stop still cancels the current executor after an asynchronous tool continuation")
@MainActor
func stopCancelsContinuedCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIContinuedCancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, _, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil)
    defer { model.stop() }
    #expect(await model.setPermission(.terminalOnly, sessionID: model.conversationID))
    let generation = UUID()
    model.terminalBindingProvider = { TerminalBindingStatus(available: true, generation: generation, reason: nil) }
    var secondStarted = false
    var cancellationReachedExecutor = false
    model.terminalCommandRunner = { proposal in
        if proposal.id == "second" {
            secondStarted = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancellationReachedExecutor = Task.isCancelled }
        }
        return ShellCommandResult(output: "fixture", exitCode: 0, timedOut: false)
    }
    let responses = ["first", "second"].map { id in
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\(id)\",\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"printf fixture\\\",\\\"purpose\\\":\\\"fixture\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n")
    }
    await transport.replaceResponses(responses)
    #expect(await model.send("fixture"))
    let startDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !secondStarted, ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(secondStarted)
    // The previous execution task has now returned after spawning this one.
    try await Task.sleep(for: .milliseconds(80))
    model.stop()
    let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !cancellationReachedExecutor, ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cancellationReachedExecutor)
    #expect(!model.isWorking)
    #expect(await transport.requestCount() == 2)
}

@Test("Reloading or deleting library profiles never silently changes the conversation's model")
@MainActor
func modelLibraryReloadPreservesConversationSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIProfileSelection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: directory, status: 200, retryAfter: nil)
    let original = model.profile
    #expect(await model.selectModel(original.id, sessionID: model.conversationID))
    let other = ModelProfile(name: "other", baseURL: "https://other.invalid/v1", model: "other-model", apiKey: "other-key")
    let profileStore = ModelProfileStore(directory: directory.appendingPathComponent("profiles"))
    try profileStore.saveAll([original, other], activeID: other.id)
    model.reloadProfilesFromStore()
    #expect(model.profile.id == original.id)
    #expect(try await coordinator.store.load(sessionID: model.conversationID).modelProfileID == original.id)

    try model.saveProfiles([other], active: other)
    #expect(model.profile.id == original.id)
    #expect(!model.profile.isConfigured)
    #expect(!(await model.send("must not fall back")))
    await model.waitForCurrentTurnCompletion()
    #expect(await transport.requestCount() == 0)
    #expect(await model.selectModel(other.id, sessionID: model.conversationID))
    #expect(model.profile == other)
}

@Test("Profile edits leave turn and maintenance HTTP retries frozen and apply to the next turn", arguments: [true, false])
@MainActor
func activeTurnKeepsFrozenModelProfileAcrossRetry(_ isTurn: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AIProfileFreeze-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sleeper = PausedRetrySleeper()
    let (model, _, transport, owner) = try await makeHTTPModel(directory: directory, status: 503, retryAfter: "0", retrySleeper: { delay in await sleeper.sleep(for: delay) })
    let original = model.profile
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    await transport.replaceResponses([
        httpStreamResponse(status: 503, headers: ["Retry-After": "0"]),
        httpStreamResponse(status: 200, body: body),
        httpStreamResponse(status: 200, body: body)
    ])
    var maintenance: Task<ChatMessage, Error>?
    if isTurn {
        #expect(await model.send("first turn"))
    } else {
        maintenance = Task { try await model.completeRequest(messages: [ChatMessage(role: "user", content: "maintenance")], owner: owner) { _ in } }
    }
    await sleeper.waitUntilStarted()
    let edited = ModelProfile(id: original.id, name: "edited", baseURL: "https://edited.invalid/v1", model: "edited-model", apiKey: "edited-key")
    try model.saveProfile(edited)
    await sleeper.resume()
    if let maintenance { _ = try await maintenance.value }
    else { await model.waitForCurrentTurnCompletion() }
    let firstRequests = await transport.capturedRequests()
    #expect(firstRequests.count == 2)
    for request in firstRequests {
        #expect(request.url?.host == "model.invalid")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let requestBody = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(json["model"] as? String == original.model)
    }
    #expect(await model.send("next turn"))
    await model.waitForCurrentTurnCompletion()
    let last = try #require(await transport.capturedRequests().last)
    #expect(last.url?.host == "edited.invalid")
    #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer edited-key")
}

private actor CancellableRetrySleeper {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: TimeInterval) async throws {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(600))
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private func httpStreamResponse(
    status: Int,
    headers: [String: String] = [:],
    body: String = ""
) -> AIHTTPStreamResponse {
    AIHTTPStreamResponse(
        statusCode: status,
        headers: headers,
        bytes: AsyncThrowingStream { continuation in
            for byte in body.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
    )
}

@Test("Conversation retries one transient HTTP response through the injected streaming transport")
@MainActor
func conversationRetriesTransientHTTPResponse() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalHTTPRetry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profileStore = ModelProfileStore(directory: directory.appendingPathComponent("profiles", isDirectory: true))
    let profile = ModelProfile(name: "test", baseURL: "https://model.invalid/v1", model: "test-model", apiKey: "test-key")
    try profileStore.saveAll([profile], activeID: profile.id)

    let sessionID = UUID()
    let terminalID = UUID()
    let target = AITargetSnapshot(hostID: nil, terminalSessionID: terminalID, workingDirectory: nil, displayName: "本机")
    let coordinator = AISessionCoordinator(
        store: AISessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true)),
        legacyArchiveURL: directory.appendingPathComponent("legacy-conversations.json"),
        resumeExecutionHistory: {}
    )
    _ = try await coordinator.store.create(sessionID: sessionID, target: target, modelProfileID: profile.id)

    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"完成\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    let transport = QueuedAIHTTPTransport(responses: [
        httpStreamResponse(status: 503, headers: ["Retry-After": "0"], body: "temporary failure"),
        httpStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: body)
    ])
    let model = TerminalAIModel(
        terminalSessionID: terminalID,
        conversationID: sessionID,
        modelProfileStore: profileStore,
        sessionCoordinator: coordinator,
        httpTransport: transport,
        archiveLoader: { [] },
        archiveWriter: { _ in }
    )
    let owner = AIRequestOwner(
        sessionID: sessionID,
        turnID: nil,
        maintenanceID: UUID(),
        stepIndex: 0,
        purpose: "transport_test",
        attemptIndex: 0
    )

    let response = try await model.completeRequest(messages: [ChatMessage(role: "user", content: "你好")], owner: owner) { _ in }

    #expect(response.content == "完成")
    #expect(await transport.requestCount() == 2)
    let events = try await coordinator.store.readEvents(sessionID: sessionID)
    let starts = try events
        .filter { $0.type == .requestStarted }
        .map { event -> AIRequestOwner in
            guard case .requestStarted(let owner, _) = try JSONDecoder().decode(AISessionEventPayload.self, from: event.payload) else {
                throw AISessionStoreError.invalidArguments
            }
            return owner
        }
    let settlements = try events
        .filter { $0.type == .requestSettled }
        .map { event -> String in
            guard case .requestSettled(_, _, let status, _) = try JSONDecoder().decode(AISessionEventPayload.self, from: event.payload) else {
                throw AISessionStoreError.invalidArguments
            }
            return status
        }
    #expect(starts.count == 2)
    #expect(Set(events.filter { $0.type == .requestStarted }.compactMap(\.requestID)).count == 2)
    #expect(starts.map(\.attemptIndex) == [0, 1])
    #expect(settlements == ["invalid_response", "completed"])
}

@Test("Retry-After above the automatic wait cap does not dispatch a second attempt")
@MainActor
func retryAfterAboveLimitDoesNotRetry() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalHTTPRetryCap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profileStore = ModelProfileStore(directory: directory.appendingPathComponent("profiles", isDirectory: true))
    let profile = ModelProfile(name: "test", baseURL: "https://model.invalid/v1", model: "test-model", apiKey: "test-key")
    try profileStore.saveAll([profile], activeID: profile.id)
    let sessionID = UUID()
    let terminalID = UUID()
    let target = AITargetSnapshot(hostID: nil, terminalSessionID: terminalID, workingDirectory: nil, displayName: "本机")
    let coordinator = AISessionCoordinator(
        store: AISessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true)),
        legacyArchiveURL: directory.appendingPathComponent("legacy-conversations.json"),
        resumeExecutionHistory: {}
    )
    _ = try await coordinator.store.create(sessionID: sessionID, target: target, modelProfileID: profile.id)
    let transport = QueuedAIHTTPTransport(responses: [
        httpStreamResponse(status: 429, headers: ["Retry-After": "31"])
    ])
    let model = TerminalAIModel(
        terminalSessionID: terminalID,
        conversationID: sessionID,
        modelProfileStore: profileStore,
        sessionCoordinator: coordinator,
        httpTransport: transport,
        archiveLoader: { [] },
        archiveWriter: { _ in }
    )
    let owner = AIRequestOwner(
        sessionID: sessionID,
        turnID: nil,
        maintenanceID: UUID(),
        stepIndex: 0,
        purpose: "transport_test",
        attemptIndex: 0
    )

    await #expect(throws: ModelAPIError.self) {
        try await model.completeRequest(messages: [ChatMessage(role: "user", content: "你好")], owner: owner) { _ in }
    }
    #expect(await transport.requestCount() == 1)
}

@Test("Cancelling a retry backoff prevents the next HTTP attempt")
@MainActor
func cancellingRetryBackoffPreventsAnotherAttempt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalHTTPRetryCancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sleeper = CancellableRetrySleeper()
    let (model, coordinator, transport, owner) = try await makeHTTPModel(
        directory: directory,
        status: 503,
        retryAfter: "25",
        retrySleeper: { delay in try await sleeper.sleep(for: delay) }
    )

    let request = Task { @MainActor in
        try await model.completeRequest(messages: [ChatMessage(role: "user", content: "你好")], owner: owner) { _ in }
    }
    await sleeper.waitUntilStarted()
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }

    #expect(await transport.requestCount() == 1)
    let events = try await coordinator.store.readEvents(sessionID: owner.sessionID)
    #expect(events.filter { $0.type == .requestStarted }.count == 1)
}

@Test("An interrupted response after visible text is never retried")
@MainActor
func interruptedStreamAfterTextIsNotRetried() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalHTTPInterrupted-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, transport, owner) = try await makeHTTPModel(directory: directory, status: 200, retryAfter: nil)
    let incomplete = "data: {\"choices\":[{\"delta\":{\"content\":\"部分内容\"},\"finish_reason\":null}]}\n\n"
    await transport.replaceResponses([
        AIHTTPStreamResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            bytes: AsyncThrowingStream { continuation in
                for byte in incomplete.utf8 { continuation.yield(byte) }
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        )
    ])

    await #expect(throws: URLError.self) {
        try await model.completeRequest(messages: [ChatMessage(role: "user", content: "你好")], owner: owner) { _ in }
    }
    #expect(await transport.requestCount() == 1)
}

@Test("One explicit provider context overflow compacts history and retries once")
@MainActor
func providerContextOverflowCompactsThenRetriesOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftTerminalHTTPOverflow-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profileStore = ModelProfileStore(directory: directory.appendingPathComponent("profiles", isDirectory: true))
    let profile = ModelProfile(name: "test", baseURL: "https://model.invalid/v1", model: "test-model", apiKey: "test-key")
    try profileStore.saveAll([profile], activeID: profile.id)
    let sessionID = UUID()
    let terminalID = UUID()
    let target = AITargetSnapshot(hostID: nil, terminalSessionID: terminalID, workingDirectory: nil, displayName: "本机")
    let configuration = AIContextConfiguration(
        contextWindowOverride: 100_000,
        outputReserve: 10_000,
        autoCompact: false,
        triggerRatio: 0.8,
        keepRecentTurns: 4,
        safetyRatio: 0.05,
        minimumSafetyTokens: 512,
        summaryMaxOutputTokens: 1024
    )
    let coordinator = AISessionCoordinator(
        store: AISessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true)),
        legacyArchiveURL: directory.appendingPathComponent("legacy-conversations.json"),
        resumeExecutionHistory: {}
    )
    let session = try await coordinator.store.create(
        sessionID: sessionID,
        target: target,
        modelProfileID: profile.id,
        configuration: configuration
    )
    let modelSnapshot = AIModelSnapshot(
        profileID: profile.id,
        configurationRevision: 1,
        endpoint: URL(string: "https://model.invalid/v1/chat/completions")!,
        provider: "openai_compatible",
        requestedModel: profile.model,
        contextWindow: configuration.contextWindowOverride,
        maxOutputTokens: nil,
        usageMapping: "openai_compatible",
        streamUsageSupport: "unknown"
    )
    var expectedRevision = session.revision
    for index in 0..<5 {
        let oldTurnID = UUID()
        let user = ChatMessage(role: "user", content: "历史约束 \(index)：" + String(repeating: "保留已确认的终端目标和操作结果。", count: 20), turnID: oldTurnID)
        let assistant = ChatMessage(role: "assistant", content: "此前已完成只读检查，未执行写操作。", turnID: oldTurnID)
        let receipt = try await coordinator.store.append([
            AINewSessionEvent(
                sessionID: sessionID,
                type: .turnStarted,
                turnID: oldTurnID,
                payload: AISessionEventPayload.turnStarted(turnID: oldTurnID, target: target, model: modelSnapshot).data
            ),
            AINewSessionEvent(
                sessionID: sessionID,
                type: .userMessage,
                turnID: oldTurnID,
                payload: AISessionEventPayload.userMessage(messageID: user.id, content: user.content ?? "").data
            ),
            AINewSessionEvent(
                sessionID: sessionID,
                type: .assistantMessage,
                turnID: oldTurnID,
                payload: AISessionEventPayload.assistantMessage(messageID: assistant.id, stored: AIStoredMessage(message: assistant)).data
            ),
            AINewSessionEvent(
                sessionID: sessionID,
                type: .turnEnded,
                turnID: oldTurnID,
                payload: AISessionEventPayload.turnEnded(turnID: oldTurnID, status: "completed", errorCode: nil).data
            )
        ], expectedRevision: expectedRevision)
        expectedRevision = receipt.revision
    }

    let overflow = httpStreamResponse(status: 400, body: #"{"error":{"code":"context_length_exceeded"}}"#)
    let summary = "data: {\"choices\":[{\"delta\":{\"content\":\"保留目标和已完成检查。\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    let answer = "data: {\"choices\":[{\"delta\":{\"content\":\"恢复后完成。\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    let transport = QueuedAIHTTPTransport(responses: [
        overflow,
        httpStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: summary),
        httpStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: answer)
    ])
    let model = TerminalAIModel(
        terminalSessionID: terminalID,
        conversationID: sessionID,
        modelProfileStore: profileStore,
        sessionCoordinator: coordinator,
        httpTransport: transport,
        archiveLoader: { [] },
        archiveWriter: { _ in }
    )

    #expect(await model.send("继续处理当前终端。"))
    await model.waitForCurrentTurnCompletion()
    let events = try await coordinator.store.readEvents(sessionID: sessionID)

    #expect(await transport.requestCount() == 3)
    #expect(model.messages.last?.content == "恢复后完成。")
    #expect(model.contextSummaryForDisplay == "保留目标和已完成检查。")
    let requestOwners = try events
        .filter { $0.type == .requestStarted }
        .map { event -> AIRequestOwner in
            guard case .requestStarted(let owner, _) = try JSONDecoder().decode(AISessionEventPayload.self, from: event.payload) else {
                throw AISessionStoreError.invalidArguments
            }
            return owner
        }
    #expect(requestOwners.map(\.purpose) == ["conversation", "auto_compaction", "conversation"])
    #expect(requestOwners.map(\.attemptIndex) == [0, 1, 2])
    #expect(events.filter { $0.type == .compactionEnded }.count == 1)
    #expect(!events.contains { $0.type == .toolIntent })
}

@MainActor
private func makeHTTPModel(
    directory: URL,
    status: Int,
    retryAfter: String?,
    workspace: WorkspaceData = WorkspaceData(),
    retrySleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
        try await Task.sleep(for: .seconds(delay))
    }
) async throws -> (TerminalAIModel, AISessionCoordinator, QueuedAIHTTPTransport, AIRequestOwner) {
    let profileStore = ModelProfileStore(directory: directory.appendingPathComponent("profiles", isDirectory: true))
    let profile = ModelProfile(name: "test", baseURL: "https://model.invalid/v1", model: "test-model", apiKey: "test-key")
    try profileStore.saveAll([profile], activeID: profile.id)
    let sessionID = UUID()
    let terminalID = UUID()
    let target = AITargetSnapshot(hostID: nil, terminalSessionID: terminalID, workingDirectory: nil, displayName: "本机")
    let coordinator = AISessionCoordinator(
        store: AISessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true)),
        legacyArchiveURL: directory.appendingPathComponent("legacy-conversations.json"),
        resumeExecutionHistory: {}
    )
    _ = try await coordinator.store.create(sessionID: sessionID, target: target, modelProfileID: profile.id)
    let transport = QueuedAIHTTPTransport(responses: [
        httpStreamResponse(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    ])
    let model = TerminalAIModel(
        terminalSessionID: terminalID,
        conversationID: sessionID,
        modelProfileStore: profileStore,
        sessionCoordinator: coordinator,
        httpTransport: transport,
        retrySleeper: retrySleeper,
        archiveLoader: { [] },
        archiveWriter: { _ in },
        workspaceLoader: { workspace }
    )
    let owner = AIRequestOwner(sessionID: sessionID, turnID: nil, maintenanceID: UUID(), stepIndex: 0, purpose: "transport_test", attemptIndex: 0)
    return (model, coordinator, transport, owner)
}

@Test("A modifying saved action waits for a visible confirmation before dispatch", arguments: [false, true])
@MainActor
func savedActionConfirmationResumesCorrectly(_ approve: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AISavedConfirmation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let command = SavedCommand(name: "生成文件", description: "仅生成测试文件", command: "touch fixture.txt", hostID: nil, workingDirectory: "/tmp")
    var workspace = WorkspaceData()
    workspace.savedCommands = [command]
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil, workspace: workspace)
    defer { model.stop() }
    let generation = UUID()
    model.terminalBindingProvider = { TerminalBindingStatus(available: true, generation: generation, reason: nil) }
    var executions = 0
    model.terminalCommandRunner = { _ in
        executions += 1
        return ShellCommandResult(output: "fixture", exitCode: 0, timedOut: false)
    }
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["actionID": command.id.uuidString]), as: UTF8.self)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [["index": 0, "id": "saved-call", "type": "function", "function": ["name": "run_saved_action", "arguments": arguments]]]], "finish_reason": "tool_calls"]]]), as: UTF8.self)
    await transport.replaceResponses([
        httpStreamResponse(status: 200, body: "data: \(json)\n\ndata: [DONE]\n\n"),
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"finished\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])
    #expect(await model.send("运行保存的测试命令"))
    await model.waitForCurrentTurnCompletion()
    let proposal = try #require(model.pendingCommand)
    #expect(proposal.command == command.command)
    #expect(model.isWaitingForUser)
    #expect(executions == 0)
    #expect(await transport.requestCount() == 1)
    if approve { await model.approvePendingCommand() } else { model.rejectPendingCommand() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.isWorking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isWorking)
    #expect(model.pendingCommand == nil)
    #expect(model.errorMessage == nil)
    #expect(executions == (approve ? 1 : 0))
    #expect(model.messages.last?.content == "finished")
    if approve {
        let snapshot = try await coordinator.store.load(sessionID: model.conversationID)
        let result = try #require(snapshot.messages.first { $0.toolCallID == "saved-call" })
        #expect(result.commandResult?.command == command.command)
        #expect(result.commandResult?.status == .completed)
        #expect(result.requestID != nil)
    }
}

@Test("A prose choice becomes a waiting card and resumes with a user message, not an orphan tool result")
@MainActor
func plainTextChoiceResumesCorrectly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIProseChoice-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, coordinator, transport, _) = try await makeHTTPModel(directory: root, status: 200, retryAfter: nil)
    defer { model.stop() }
    let text = "请选择安装方式：\n1. 保留现有配置\n2. 重新配置"
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]), as: UTF8.self)
    await transport.replaceResponses([
        httpStreamResponse(status: 200, body: "data: \(json)\n\ndata: [DONE]\n\n"),
        httpStreamResponse(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"finished\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
    ])
    #expect(await model.send("测试选择"))
    await model.waitForCurrentTurnCompletion()
    let question = try #require(model.pendingQuestion)
    #expect(question.source == .assistantText)
    #expect(question.arguments.options.map(\.label) == ["保留现有配置", "重新配置"])
    #expect(try await coordinator.store.load(sessionID: model.conversationID).turnStates[question.turnID] == "open")
    #expect(await model.answerQuestion(id: question.id, optionID: "choice-1"))
    await model.waitForCurrentTurnCompletion()
    #expect(model.pendingQuestion == nil)
    #expect(model.messages.last?.content == "finished")
    let requests = await transport.capturedRequests()
    let body = try #require(requests.last?.httpBody)
    let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.last?["role"] as? String == "user")
    #expect(messages.last?["tool_call_id"] == nil)
    #expect((messages.last?["content"] as? String)?.contains("保留现有配置") == true)
}
