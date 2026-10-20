import Foundation
import Testing
@testable import SwiftTerminal

struct TerminalSessionPolicyTests {
    @Test("Local terminals stay separate from SSH sessions")
    func localSessionsAreFilteredAndNewestFirst() {
        let first = TerminalSession(host: nil)
        let host = SSHHost(name: "NAS", address: "nas.local", username: "admin")
        let remote = TerminalSession(host: host)
        let second = TerminalSession(host: nil)

        let local = TerminalSessionPolicy.localSessions([first, remote, second])

        #expect(local.map(\.id) == [second.id, first.id])
    }

    @Test("A host reuses its existing terminal session")
    func existingSessionMatchesHostIdentity() {
        let host = SSHHost(name: "NAS", address: "nas.local", username: "admin")
        let session = TerminalSession(host: host)
        let other = TerminalSession(host: SSHHost(name: "Other", address: "other.local", username: "me"))

        #expect(TerminalSessionPolicy.existingSession(for: host, in: [other, session])?.id == session.id)
        #expect(TerminalSessionPolicy.existingSession(for: host, in: [other]) == nil)
    }
}


@Test("Workspace selection is terminal-first and recovers from stale tabs")
func workspaceSelectionFillsMissingOrStaleSessions() {
    let first = TerminalSession(host: nil)
    let host = SSHHost(name: "NAS", address: "nas.local", username: "admin")
    let remote = TerminalSession(host: host)
    let sessions = [first, remote]
    let missingID = UUID()

    #expect(WorkspaceSelectionPolicy.startupPage == .terminal)
    #expect(WorkspaceSelectionPolicy.restoredSelectedSessionID(sessions, selectedID: nil) == first.id)
    #expect(WorkspaceSelectionPolicy.restoredSelectedSessionID(sessions, selectedID: missingID) == first.id)
    #expect(WorkspaceSelectionPolicy.restoredSelectedSessionID(sessions, selectedID: remote.id) == remote.id)
}
