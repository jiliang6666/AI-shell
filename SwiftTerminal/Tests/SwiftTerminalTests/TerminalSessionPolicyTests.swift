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

    @Test("Deleting a saved host removes its SSH sidebar row but keeps the session")
    func deletedHostDoesNotRemainInSSHList() {
        let host = SSHHost(name: "Old host", address: "old.local", username: "admin")
        let session = TerminalSession(host: host)

        let rows = SSHHostSidebarPolicy.entries(hosts: [], sessions: [session])

        #expect(rows.isEmpty)
        #expect(session.host?.id == host.id)
    }

    @Test("Editing connection settings requires a fresh SSH process")
    func connectionChangesRequireRestart() {
        let host = SSHHost(name: "NAS", address: "nas.local", username: "admin")
        var renamed = host
        renamed.name = "Storage"
        renamed.group = "Home"

        var addressed = host
        addressed.address = "192.168.1.20"

        var authentication = host
        authentication.authentication = .privateKey
        authentication.privateKeyPath = "~/.ssh/id_ed25519"

        #expect(!TerminalSessionPolicy.connectionConfigurationChanged(from: host, to: renamed))
        #expect(TerminalSessionPolicy.connectionConfigurationChanged(from: host, to: addressed))
        #expect(TerminalSessionPolicy.connectionConfigurationChanged(from: host, to: authentication))
    }

    @Test("Display metadata updates without changing the connection snapshot")
    func displayMetadataUpdatesWithoutRestart() {
        let host = SSHHost(name: "NAS", address: "nas.local", username: "admin")
        var renamed = host
        renamed.name = "Storage"
        renamed.group = "Home"

        let updated = TerminalSessionPolicy.applyingDisplayMetadata(from: renamed, to: host)

        #expect(updated.name == "Storage")
        #expect(updated.group == "Home")
        #expect(updated.address == host.address)
        #expect(!TerminalSessionPolicy.connectionConfigurationChanged(from: host, to: updated))
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
