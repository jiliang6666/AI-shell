import Foundation
import Testing
@testable import SwiftTerminal

@Test("Cancelling an active SFTP process stops the child process")
func cancellationStopsSFTPProcess() throws {
    let state = SFTPProcessState()
    state.process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    state.process.arguments = ["5"]
    try state.start()
    state.cancel()
    state.process.waitUntilExit()
    #expect(!state.process.isRunning)
    #expect(state.process.terminationStatus != 0)
}

@Test("An operation timeout stops the child process and reports a timeout")
func timeoutStopsSFTPProcess() throws {
    let state = SFTPProcessState()
    state.process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    state.process.arguments = ["5"]
    try state.start()
    state.timeoutIfRunning()
    state.process.waitUntilExit()
    #expect(state.didTimeOut)
    #expect(!state.process.isRunning)
}
