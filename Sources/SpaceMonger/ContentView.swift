import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var scanner = FolderScanner()
    @State private var zoomStack: [FileNode] = []
    @State private var hoveredNode: DisplayNode?
    @State private var searchText = ""
    @State private var activeSearchQuery = ""
    @State private var searchResults: [FileNode] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    /// The node currently displayed as the treemap root (zoom-aware).
    private var currentRoot: FileNode? {
        zoomStack.last ?? scanner.root
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar)

            Divider()

            Group {
                if let root = currentRoot {
                    if activeSearchQuery.isEmpty {
                        TreeMapView(
                            root: root,
                            revision: scanner.treeRevision,
                            onNodeTapped: handleTap,
                            hoveredNode: $hoveredNode
                        )
                        // Right-click context menu (replaces WM_RBUTTONDOWN shell menu)
                        .contextMenu {
                            if let node = hoveredNode {
                                contextMenuItems(for: node)
                            }
                        }
                    } else {
                        searchResultsView
                    }
                } else if scanner.isScanning {
                    scanningView
                } else {
                    welcomeView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            statusBar
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.bar)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: searchText) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSearch()
            }
        }
        .onChange(of: scanner.root?.id) { _ in
            if !activeSearchQuery.isEmpty { performSearch() }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: openFolder) {
                Label("Open…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("o", modifiers: .command)

            Divider().frame(height: 20)

            Button(action: zoomOut) {
                Label("Zoom Out", systemImage: "arrow.up.backward.circle")
            }
            .buttonStyle(.bordered)
            .disabled(zoomStack.isEmpty)
            .keyboardShortcut("[", modifiers: .command)

            Button(action: resetZoom) {
                Label("Root", systemImage: "house.circle")
            }
            .buttonStyle(.bordered)
            .disabled(zoomStack.isEmpty)
            .keyboardShortcut(.escape, modifiers: [])

            Divider().frame(height: 20)

            if let root = currentRoot {
                breadcrumb(for: root)
            }

            if scanner.root != nil {
                Divider().frame(height: 20)

                HStack(spacing: 6) {
                    NativeSearchField(text: $searchText, onSubmit: performSearch)
                        .frame(height: 22)
                    Button("Search") {
                        performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(normalizedSearchText.isEmpty)
                }
                .frame(width: 300)
            }

            Spacer()

            if scanner.isScanning {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                Button("Cancel", action: scanner.cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Search

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            HStack {
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                } else {
                    Text("\(searchResults.count) \(searchResults.count == 1 ? "match" : "matches")")
                }
                Spacer()
                Text("Names containing “\(activeSearchQuery)”")
                    .foregroundColor(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if isSearching {
                Spacer()
                ProgressView("Searching file and directory names…")
                Spacer()
            } else if searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No Matches")
                        .font(.title2.bold())
                    Text("No file or directory name contains “\(activeSearchQuery)”.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(searchResults) { node in
                    Button {
                        navigateToSearchResult(node)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                    .lineLimit(1)
                                Text(node.url.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !node.isDirectory {
                                    Text("Opens the containing folder")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer(minLength: 12)

                            Text(node.formattedSize)
                                .font(.system(.body, design: .monospaced))
                                .monospacedDigit()
                                .fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(node.isDirectory
                        ? "Click to show this folder"
                        : "Click to show this file's containing folder")
                }
                .listStyle(.inset)
            }
        }
    }

    private func performSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        hoveredNode = nil

        let query = normalizedSearchText
        guard !query.isEmpty, let root = scanner.root else {
            isSearching = false
            return
        }

        activeSearchQuery = query
        isSearching = true
        searchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                ContentView.matchingNodes(in: root, query: query)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled,
                  activeSearchQuery == query,
                  scanner.root?.id == root.id else { return }
            searchResults = matches
            isSearching = false
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        activeSearchQuery = ""
        searchResults = []
        isSearching = false
    }

    nonisolated private static func matchingNodes(in root: FileNode, query: String) -> [FileNode] {
        var pending = [root]
        var matches: [FileNode] = []
        var visited = 0

        while let node = pending.popLast() {
            visited += 1
            if visited.isMultiple(of: 1_024), Task.isCancelled { return [] }

            if node.name.localizedCaseInsensitiveContains(query) {
                matches.append(node)
            }
            if node.isDirectory {
                pending.append(contentsOf: node.children.reversed())
            }
        }

        matches.sort { lhs, rhs in
            let lhsIsExact = lhs.name.localizedCaseInsensitiveCompare(query) == .orderedSame
            let rhsIsExact = rhs.name.localizedCaseInsensitiveCompare(query) == .orderedSame
            if lhsIsExact != rhsIsExact { return lhsIsExact }
            if lhs.totalSize != rhs.totalSize { return lhs.totalSize > rhs.totalSize }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        return matches
    }

    @ViewBuilder
    private func breadcrumb(for _: FileNode) -> some View {
        let path = [scanner.root].compactMap { $0 } + zoomStack

        HStack(spacing: 2) {
            ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Button {
                    navigateToBreadcrumb(at: index)
                } label: {
                    Text(component.name)
                        .font(.system(size: 11))
                        .foregroundColor(index == path.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(component.url.path)
            }
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            if let node = hoveredNode {
                Text(node.fileNode.url.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let date = node.fileNode.modificationDate {
                    Text(date, style: .date)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if let ownerURL = node.fileNode.storageOwnerURL {
                    Text("Hard link · storage counted elsewhere")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Storage counted under \(ownerURL.path)")
                }

                Text(node.fileNode.formattedSize)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()

            } else if let root = scanner.root {
                Text("\(root.fileCount) files, \(root.folderCount) folders — \(root.formattedSize)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                if scanner.diskTotal > 0 {
                    let used = scanner.diskTotal - scanner.diskFree
                    Text("\(formatBytes(used)) used · \(formatBytes(scanner.diskFree)) free of \(formatBytes(scanner.diskTotal))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Open a folder to visualise disk usage")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Scanning / Welcome

    @ViewBuilder
    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Scanning…")
                .font(.headline)
            Text(scanner.diskTotal > 0 ? formatBytes(scanner.diskTotal) + " volume" : "")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var welcomeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("SpaceMonger for Mac")
                .font(.largeTitle.bold())
            Text("Click a folder — its contents fill the window.\nLarger areas mean more disk space used.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Label(
                "SpaceMonger for Mac works best with as much screen space as possible.",
                systemImage: "arrow.up.left.and.arrow.down.right"
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Button(action: openFolder) {
                Label("Open Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context Menu (replaces shell context menu in original)

    @ViewBuilder
    private func contextMenuItems(for node: DisplayNode) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(
                node.fileNode.url.path, inFileViewerRootedAtPath: "")
        }

        Button(node.fileNode.isDirectory ? "Open in Finder" : "Open") {
            NSWorkspace.shared.open(node.fileNode.url)
        }

        if node.fileNode.isDirectory {
            Divider()
            Button("Zoom into \"\(node.fileNode.name)\"") {
                zoomStack.append(node.fileNode)
            }
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
            moveToTrash(node: node.fileNode)
        }
    }

    // MARK: - Actions

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Folder to Scan"
        panel.prompt = "Scan"
        panel.message = "SpaceMonger for Mac will measure the size of every item inside."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        zoomStack = []
        hoveredNode = nil
        clearSearch()
        scanner.scan(url: url)
    }

    /// Left-click zooms into directories. Files require an explicit context-menu action.
    private func handleTap(_ node: FileNode) {
        guard node.isDirectory else { return }
        zoomStack.append(node)
    }

    private func zoomOut() {
        guard !zoomStack.isEmpty else { return }
        _ = zoomStack.removeLast()
    }

    private func resetZoom() {
        zoomStack = []
    }

    private func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index <= zoomStack.count else { return }
        zoomStack = Array(zoomStack.prefix(index))
        hoveredNode = nil
    }

    private func navigateToSearchResult(_ node: FileNode) {
        guard let destination = node.isDirectory ? node : node.parent else { return }
        guard let root = scanner.root else { return }

        var path: [FileNode] = []
        var current: FileNode? = destination
        while let component = current, component !== root {
            path.append(component)
            current = component.parent
        }
        guard current === root else { return }

        zoomStack = path.reversed()
        hoveredNode = nil
        clearSearch()
    }

    /// Move a file/folder to the system Trash, then mirror that move in memory.
    /// A failed Trash operation leaves the display unchanged.
    private func moveToTrash(node: FileNode) {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(
                at: node.url,
                resultingItemURL: &resultingURL
            )
        } catch {
            return
        }

        if let deletedLevel = zoomStack.firstIndex(where: { $0 === node }) {
            zoomStack = Array(zoomStack.prefix(deletedLevel))
        }
        hoveredNode = nil
        _ = scanner.moveToTrashInScannedTree(
            node,
            destinationURL: resultingURL as URL?
        )
    }
}

/// A native search field gives immediate AppKit cursor and focus behavior while still
/// keeping search execution explicit (Return or the adjacent Search button).
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "Search names"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submit(_:))
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.text = searchField.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}
