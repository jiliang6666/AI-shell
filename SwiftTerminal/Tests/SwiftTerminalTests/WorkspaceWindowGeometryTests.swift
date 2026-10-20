import AppKit
import Testing
@testable import SwiftTerminal

@Test("Opening and closing the left panel keeps the terminal origin fixed")
func sidebarExpansionKeepsTerminalPosition() {
    let closed = CGRect(x: 180, y: 100, width: 1005, height: 720)
    let opened = WorkspaceWindowGeometry.resizedFrame(
        from: closed,
        currentSidebar: false,
        currentAssistant: true,
        sidebar: true,
        assistant: true,
        anchorToRight: true
    )
    #expect(opened.minX + WorkspaceWindowGeometry.sidebarWidth == closed.minX)
    #expect(opened.width - WorkspaceWindowGeometry.sidebarWidth - WorkspaceWindowGeometry.assistantWidth == 660)

    let closedAgain = WorkspaceWindowGeometry.resizedFrame(
        from: opened,
        currentSidebar: true,
        currentAssistant: true,
        sidebar: false,
        assistant: true,
        anchorToRight: true
    )
    #expect(closedAgain == closed)
}

@Test("Opening the right panel keeps the terminal origin and width fixed")
func assistantExpansionKeepsTerminalPosition() {
    let closed = CGRect(x: 180, y: 100, width: 885, height: 720)
    let opened = WorkspaceWindowGeometry.resizedFrame(
        from: closed,
        currentSidebar: true,
        currentAssistant: false,
        sidebar: true,
        assistant: true,
        anchorToRight: false
    )
    #expect(opened.minX == closed.minX)
    #expect(opened.width - WorkspaceWindowGeometry.sidebarWidth - WorkspaceWindowGeometry.assistantWidth == 660)
    #expect(WorkspaceWindowGeometry.minimumWidth(sidebar: false, assistant: true) == 1005)
}
