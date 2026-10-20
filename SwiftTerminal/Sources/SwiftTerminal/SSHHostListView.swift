import AppKit
import SwiftUI

/// One row in the SSH sidebar list.
struct SSHHostRowModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var isConnected: Bool
    var isSelected: Bool
    var isSMB: Bool = false
    var connectionLabel: String? = nil
}

/// Native macOS sidebar list for saved SSH hosts. NSTableView provides the
/// system row-swipe behavior (the AppKit counterpart of iOS swipeActions),
/// including trackpad tracking, snap, and full-swipe.
///
/// The row geometry intentionally mirrors the SwiftUI local-session row in
/// TerminalWorkspace.sessionRow(_:): 37pt tall, visible content starting
/// 14pt from the sidebar's leading edge, and a 7pt status dot followed by an 8pt gap.
struct SSHHostListView: NSViewRepresentable {
    static let rowHeight: CGFloat = 37

    var rows: [SSHHostRowModel]
    var onActivate: (UUID) -> Void
    var onEdit: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var onReorder: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SidebarTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        // sourceList adds an AppKit-owned leading inset on top of the cell's
        // own padding. That inset is what made SSH rows sit further right
        // than local-shell rows. Draw the highlight ourselves instead.
        tableView.style = .fullWidth
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.didClickRow(_:))

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        column.minWidth = 1
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.contextMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(for: row) }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.rowHeight = Self.rowHeight
        if context.coordinator.rows != rows {
            context.coordinator.rows = rows
            tableView.reloadData()
        }
        context.coordinator.rows = rows
        // Match the table to the visible sidebar width so the row highlight
        // spans the same width as the local-session row.
        let width = scrollView.contentSize.width
        if let column = tableView.tableColumns.first {
            if abs(column.width - width) > 0.5 { column.width = width }
        }
        tableView.frame.size.width = max(width, 1)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("SSHHostColumn")

        var parent: SSHHostListView
        var rows: [SSHHostRowModel] = []
        weak var tableView: NSTableView?

        init(_ parent: SSHHostListView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.columnID, owner: nil) as? SSHHostCellView
                ?? SSHHostCellView(identifier: Self.columnID)
            cell.configure(with: rows[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            SSHHostListView.rowHeight
        }

        func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
            guard edge == .trailing else { return [] }
            let delete = NSTableViewRowAction(style: .destructive, title: "") { [weak self] _, row in
                guard let self, self.rows.indices.contains(row) else { return }
                self.parent.onDelete(self.rows[row].id)
                self.tableView?.rowActionsVisible = false
            }
            delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")

            let edit = NSTableViewRowAction(style: .regular, title: "") { [weak self] _, row in
                guard let self, self.rows.indices.contains(row) else { return }
                self.parent.onEdit(self.rows[row].id)
                self.tableView?.rowActionsVisible = false
            }
            edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "编辑")
            edit.backgroundColor = .controlAccentColor
            return [delete, edit]
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, tableView.selectedRow >= 0, rows.indices.contains(tableView.selectedRow) else { return }
            parent.onActivate(rows[tableView.selectedRow].id)
        }

        func menu(for row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let menu = NSMenu()
            let edit = NSMenuItem(title: "编辑…", action: #selector(editFromMenu(_:)), keyEquivalent: "")
            edit.target = self; edit.representedObject = rows[row].id; menu.addItem(edit)
            let delete = NSMenuItem(title: "删除连接资料…", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
            delete.target = self; delete.representedObject = rows[row].id; menu.addItem(delete)
            return menu
        }

        @MainActor @objc private func editFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { parent.onEdit(id) } }
        @MainActor @objc private func deleteFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { parent.onDelete(id) } }

        @MainActor @objc func didClickRow(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0, rows.indices.contains(tableView.clickedRow) else { return }
            parent.onActivate(rows[tableView.clickedRow].id)
        }
    }
}

/// Sidebar row: status dot, host name, and endpoint.
final class SSHHostCellView: NSTableCellView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let selectionBackground = NSView()
    private let contentStack = NSStackView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        // NSTableView reserves a 6pt leading inset for the cell itself.
        // Cancel it here so the highlight lands at 6pt from the sidebar edge,
        // exactly like the local-session row's background.
        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 7
        selectionBackground.layer?.cornerCurve = .continuous
        selectionBackground.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(dot)
        contentStack.addArrangedSubview(textStack)

        addSubview(selectionBackground)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            // Same visible geometry as TerminalWorkspace.sessionRow(_:).
            // The table cell already starts 6pt into the sidebar, so the
            // visible 6pt margin plus 8pt padding become 8pt inside the cell.
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            selectionBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            selectionBackground.topAnchor.constraint(equalTo: topAnchor),
            selectionBackground.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with row: SSHHostRowModel) {
        titleLabel.stringValue = row.name
        subtitleLabel.stringValue = row.connectionLabel.map { "\($0) · \(row.endpoint)" }
            ?? (row.isConnected ? "已连接 · \(row.endpoint)" : row.endpoint)
        selectionBackground.isHidden = !row.isSelected
        titleLabel.textColor = row.isSelected ? .white : .labelColor
        subtitleLabel.textColor = row.isSelected
            ? NSColor.white.withAlphaComponent(0.8)
            : .secondaryLabelColor
        dot.layer?.backgroundColor = row.isSMB ? NSColor.systemPurple.cgColor : NSColor.systemBlue.cgColor
        setAccessibilityLabel("\(row.name)，\(row.isSMB ? "SMB" : "SSH")，\(row.endpoint)\(row.isSelected ? "，已选中" : "")")
    }
}

private final class SidebarTableView: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenu?(row(at: point))
    }
}
