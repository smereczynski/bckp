import SwiftUI
import AppKit
import BackupCore

/// A simple view model that bridges the SwiftUI views and the BackupCore engine.
/// State changes are published to update the UI automatically.
final class AppModel: ObservableObject {
    // Repository state
    @Published var repoPath: String = BackupManager.defaultRepoURL.path
    @Published var snapshots: [SnapshotListItem] = []

    // Sources to back up
    @Published var sources: [String] = []

    // Progress/state for long-running work
    @Published var isBusy = false
    @Published var progressFilesProcessed = 0
    @Published var progressFilesTotal = 0
    @Published var progressBytesProcessed: Int64 = 0
    @Published var progressBytesTotal: Int64 = 0

    // Log lines for simple, developer-friendly feedback
    @Published var log: [String] = []

    private let manager = BackupManager()

    /// Create the repo if it doesn't exist (idempotent).
    func ensureRepo() {
        do { try manager.initRepo(at: URL(fileURLWithPath: repoPath)) } catch { }
    }

    /// Pull a list of snapshots from the repo.
    func refreshSnapshots() {
        do {
            let items = try manager.listSnapshots(in: URL(fileURLWithPath: repoPath))
            DispatchQueue.main.async { self.snapshots = items.reversed() }
        } catch {
            append("List failed: \(error.localizedDescription)")
        }
    }

    /// Launch a backup on a background queue and stream progress into the view model.
    func runBackup() {
        guard !sources.isEmpty else { append("Add at least one source"); return }
        isBusy = true
        progressFilesProcessed = 0
        progressFilesTotal = 0
        progressBytesProcessed = 0
        progressBytesTotal = 0
        append("Starting backup…")
        let srcURLs = sources.map { URL(fileURLWithPath: $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try self.manager.backup(
                    sources: srcURLs,
                    to: URL(fileURLWithPath: self.repoPath),
                    options: BackupOptions(),
                    progress: { p in
                        DispatchQueue.main.async {
                            self.progressFilesProcessed = p.processedFiles
                            self.progressFilesTotal = p.totalFiles
                            self.progressBytesProcessed = p.processedBytes
                            self.progressBytesTotal = p.totalBytes
                        }
                    }
                )
                DispatchQueue.main.async {
                    self.append("Backup completed.")
                    self.isBusy = false
                    self.refreshSnapshots()
                }
            } catch {
                DispatchQueue.main.async {
                    self.append("Backup failed: \(error.localizedDescription)")
                    self.isBusy = false
                }
            }
        }
    }

    func append(_ s: String) { log.append(s) }
}

/// The main, modernized view using a sidebar and toolbar.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedSnapshotID: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { model.ensureRepo(); model.refreshSnapshots() }
    }

    // MARK: Sidebar
    private var sidebar: some View {
        List(selection: $selectedSnapshotID) {
            Section("Repository") {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.secondary)
                    TextField("Repo Path", text: $model.repoPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickFolder(single: true) { model.repoPath = $0 } }
                    Button("Init") { model.ensureRepo(); model.refreshSnapshots() }
                }
            }
            Section("Sources") {
                if model.sources.isEmpty {
                    Text("No sources").foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources, id: \.self) { s in SourceRow(path: s) }
                        .onDelete { idx in model.sources.remove(atOffsets: idx) }
                }
            }
            Section("Snapshots") {
                if model.snapshots.isEmpty {
                    Text("No snapshots yet").foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshots, id: \.id) { it in
                        SnapshotRow(item: it)
                            .tag(it.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            progressSection
            GroupBox("Activity") { logView }
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("bckp")
                .font(.largeTitle.weight(.semibold))
            Text("Simple macOS backups using Swift")
                .foregroundStyle(.secondary)
        }
    }

    private var progressSection: some View {
        GroupBox("Backup Status") {
            VStack(alignment: .leading, spacing: 12) {
                let total = Double(max(model.progressBytesTotal, 1))
                let value = Double(model.progressBytesProcessed)
                ProgressView(value: value, total: total)
                HStack {
                    Text("\(model.progressFilesProcessed)/\(max(model.progressFilesTotal, 0)) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(byteCount(model.progressBytesProcessed)) / \(byteCount(model.progressBytesTotal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var logView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 160)
    }

    // MARK: Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: { pickFolder { model.sources.append(contentsOf: $0) } }) {
                Label("Add Sources", systemImage: "folder.badge.plus")
            }
            Button(action: { model.runBackup() }) {
                Label("Run Backup", systemImage: "play.circle")
            }
            .disabled(model.isBusy)
        }
        ToolbarItem(placement: .status) {
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Backing up…")
                }
            } else {
                Text("Idle").foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { model.refreshSnapshots() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: Helpers
    private func byteCount(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .file) }

    /// Show a folder picker and pass selected paths to the handler.
    private func pickFolder(single: Bool = false, _ handler: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !single
        panel.begin { response in
            if response == .OK {
                if single, let url = panel.urls.first { handler(url.path) }
                else { panel.urls.forEach { handler($0.path) } }
            }
        }
    }

    /// Select multiple folders; returns an array of paths.
    private func pickFolder(_ handler: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK { handler(panel.urls.map { $0.path }) }
        }
    }
}

// MARK: - Small subviews
/// Render a source row with a folder icon and truncated path.
private struct SourceRow: View {
    let path: String
    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(path).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Render a snapshot row showing ID (monospaced) and file count.
private struct SnapshotRow: View {
    let item: SnapshotListItem
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.id)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(item.totalFiles)", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.caption)
            Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
