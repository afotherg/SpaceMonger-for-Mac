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
    @State private var sizeMetric: SizeMetric = .allocated
    @State private var trashProgress: TrashProgress?
    @State private var trashTask: Task<Void, Never>?
    @State private var trashFailure: TrashFailure?

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
                            sizeMetric: sizeMetric,
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
        .disabled(trashProgress != nil)
        .overlay {
            if let trashProgress {
                trashProgressOverlay(trashProgress)
            }
        }
        .alert(item: $trashFailure) { failure in
            Alert(
                title: Text("Couldn’t Move Item to Trash"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: searchText) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSearch()
            }
        }
        .onChange(of: scanner.root?.id) { _ in
            if !activeSearchQuery.isEmpty { performSearch() }
        }
        .onChange(of: sizeMetric) { _ in
            hoveredNode = nil
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

            Picker("Size", selection: $sizeMetric) {
                ForEach(SizeMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Choose whether areas represent allocated disk space or logical file size")

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

                            Text(node.formattedSize(for: sizeMetric))
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
        let metric = sizeMetric
        guard !query.isEmpty, let root = scanner.root else {
            isSearching = false
            return
        }

        activeSearchQuery = query
        isSearching = true
        searchTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                ContentView.matchingNodes(in: root, query: query, sizeMetric: metric)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled,
                  activeSearchQuery == query,
                  sizeMetric == metric,
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

    nonisolated private static func matchingNodes(
        in root: FileNode,
        query: String,
        sizeMetric: SizeMetric
    ) -> [FileNode] {
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
            let lhsSize = lhs.size(for: sizeMetric)
            let rhsSize = rhs.size(for: sizeMetric)
            if lhsSize != rhsSize { return lhsSize > rhsSize }
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

                if sizeMetric == .allocated, let ownerURL = node.fileNode.storageOwnerURL {
                    Text("Hard link · storage counted elsewhere")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Storage counted under \(ownerURL.path)")
                }

                Text(node.fileNode.formattedSize(for: sizeMetric))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()

            } else if let root = scanner.root {
                Text("\(root.fileCount) files, \(root.folderCount) folders — \(root.formattedSize(for: sizeMetric)) \(sizeMetric.rawValue)")
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

    @ViewBuilder
    private func trashProgressOverlay(_ progress: TrashProgress) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 34))
                    .foregroundColor(.secondary)

                Text(progress.phase.title)
                    .font(.headline)
                Text(progress.itemName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 340)

                if progress.phase == .moving {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 300)
                    Text("macOS is processing the item")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView(
                        value: Double(progress.completed),
                        total: Double(max(1, progress.total))
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted()) entries")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.12))
            }
            .shadow(radius: 18)
        }
    }

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

    /// Move a file/folder to the system Trash as one modal workflow. Filesystem and
    /// model preparation run away from the main actor so the progress UI stays live.
    private func moveToTrash(node: FileNode) {
        guard trashProgress == nil, node.parent != nil else { return }

        let operationID = UUID()
        let entryCount = node.fileCount + node.folderCount + (node.isDirectory ? 1 : 0)
        trashProgress = TrashProgress(
            id: operationID,
            itemName: node.name,
            phase: .moving,
            completed: 0,
            total: max(1, entryCount)
        )

        let sourceURL = node.url
        trashTask = Task { @MainActor in
            do {
                let destinationURL = try await Task.detached(priority: .userInitiated) {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(
                        at: sourceURL,
                        resultingItemURL: &resultingURL
                    )
                    return resultingURL as URL?
                }.value

                guard var progress = trashProgress, progress.id == operationID else { return }
                progress.phase = .updating
                trashProgress = progress

                guard let update = await scanner.prepareMoveToTrashInScannedTree(
                    node,
                    destinationURL: destinationURL,
                    progress: { completed in
                        guard var current = trashProgress,
                              current.id == operationID,
                              current.phase == .updating else { return }
                        current.completed = min(current.total, completed)
                        trashProgress = current
                    }
                ), scanner.applyTrashTreeUpdate(update) else {
                    throw TrashOperationError.modelUpdateFailed
                }

                if let deletedLevel = zoomStack.firstIndex(where: { $0 === node }) {
                    zoomStack = Array(zoomStack.prefix(deletedLevel))
                }
                hoveredNode = nil
                trashProgress = nil
            } catch {
                if trashProgress?.id == operationID {
                    trashProgress = nil
                }
                trashFailure = TrashFailure(message: error.localizedDescription)
            }
            trashTask = nil
        }
    }
}

private struct TrashProgress: Identifiable {
    enum Phase {
        case moving
        case updating

        var title: String {
            switch self {
            case .moving: return "Moving to Trash…"
            case .updating: return "Updating disk map…"
            }
        }
    }

    let id: UUID
    let itemName: String
    var phase: Phase
    var completed: Int
    let total: Int
}

private struct TrashFailure: Identifiable {
    let id = UUID()
    let message: String
}

private enum TrashOperationError: LocalizedError {
    case modelUpdateFailed

    var errorDescription: String? {
        "The item was moved to Trash, but SpaceMonger could not update its disk map. Reopen the scanned folder to refresh it."
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
