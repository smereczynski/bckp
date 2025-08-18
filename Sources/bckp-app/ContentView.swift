import SwiftUI
import AppKit
import BackupCore

/// A simple view model that bridges the SwiftUI views and the BackupCore engine.
/// State changes are published to update the UI automatically.
final class AppModel: ObservableObject {
    // Repository state
    @Published var repoPath: String = BackupManager.defaultRepoURL.path
    @Published var snapshots: [SnapshotListItem] = []
    @Published var cloudSnapshots: [SnapshotListItem] = []

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

    // Editable configuration (comma-separated include/exclude for simplicity)
    @Published var includeText: String = ""
    @Published var excludeText: String = ""
    @Published var concurrencyText: String = ""
    @Published var azureSASText: String = ""

    private let manager = BackupManager()

    // repositories.json surfaced data
    @Published var repoUsage: RepositoryInfo? = nil
    @Published var cloudRepoUsage: RepositoryInfo? = nil

    /// Create the repo if it doesn't exist (idempotent).
    func ensureRepo() {
        do { try manager.initRepo(at: URL(fileURLWithPath: repoPath)) } catch { }
    // Record usage and refresh repositories.json view
    let url = URL(fileURLWithPath: repoPath)
    RepositoriesConfigStore.shared.recordRepoUsedLocal(repoURL: url)
    refreshRepoUsage()
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

    /// List snapshots from Azure Blob using SAS from config.
    func refreshCloudSnapshots() {
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        guard let sas = cfg.azureSAS, !sas.isEmpty, let sasURL = URL(string: sas) else {
            append("[Cloud] Missing [azure] sas in config; Save config and retry")
            return
        }
        do {
            let items = try manager.listSnapshotsInAzure(containerSASURL: sasURL)
            DispatchQueue.main.async { self.cloudSnapshots = items.reversed() }
            // Also refresh repositories.json view for cloud
            refreshCloudRepoUsage()
        } catch {
            append("[Cloud] List failed: \(error.localizedDescription)")
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
                    // Record backup into repositories.json and refresh view
                    RepositoriesConfigStore.shared.recordBackupLocal(repoURL: URL(fileURLWithPath: self.repoPath), sourcePaths: srcURLs)
                    self.refreshRepoUsage()
                }
            } catch {
                DispatchQueue.main.async {
                    self.append("Backup failed: \(error.localizedDescription)")
                    self.isBusy = false
                }
            }
        }
    }

    /// Initialize Azure container as a repo (idempotent) using SAS from config.
    func ensureAzureRepo() {
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        guard let sas = cfg.azureSAS, !sas.isEmpty, let sasURL = URL(string: sas) else {
            append("[Cloud] Missing [azure] sas in config; Save config and retry")
            return
        }
        do {
            try manager.initAzureRepo(containerSASURL: sasURL)
            append("[Cloud] Repo initialized")
            RepositoriesConfigStore.shared.recordRepoUsedAzure(containerSASURL: sasURL)
            refreshCloudRepoUsage()
        } catch {
            append("[Cloud] Init failed: \(error.localizedDescription)")
        }
    }

    /// Backup to Azure Blob using SAS and options from config.
    func runCloudBackup() {
        guard !sources.isEmpty else { append("[Cloud] Add at least one source"); return }
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        guard let sas = cfg.azureSAS, !sas.isEmpty, let sasURL = URL(string: sas) else {
            append("[Cloud] Missing [azure] sas in config; Save config and retry")
            return
        }
        isBusy = true
        progressFilesProcessed = 0
        progressFilesTotal = 0
        progressBytesProcessed = 0
        progressBytesTotal = 0
        append("[Cloud] Starting backup…")
        let srcURLs = sources.map { URL(fileURLWithPath: $0) }
        let opts = BackupOptions(include: cfg.include, exclude: cfg.exclude, concurrency: cfg.concurrency)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try self.manager.backupToAzure(
                    sources: srcURLs,
                    containerSASURL: sasURL,
                    options: opts,
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
                    self.append("[Cloud] Backup completed.")
                    self.isBusy = false
                    self.refreshCloudSnapshots()
                    // Record backup into repositories.json and refresh view
                    RepositoriesConfigStore.shared.recordBackupAzure(containerSASURL: sasURL, sourcePaths: srcURLs)
                    self.refreshCloudRepoUsage()
                }
            } catch {
                DispatchQueue.main.async {
                    self.append("[Cloud] Backup failed: \(error.localizedDescription)")
                    self.isBusy = false
                }
            }
        }
    }

    /// Restore a cloud snapshot to a destination directory.
    func runCloudRestore(snapshotId: String, destination: String) {
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        guard let sas = cfg.azureSAS, !sas.isEmpty, let sasURL = URL(string: sas) else {
            append("[Cloud] Missing [azure] sas in config; Save config and retry")
            return
        }
        isBusy = true
        append("[Cloud] Restoring \(snapshotId)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.manager.restoreFromAzure(
                    snapshotId: snapshotId,
                    containerSASURL: sasURL,
                    to: URL(fileURLWithPath: destination),
                    concurrency: cfg.concurrency
                )
                DispatchQueue.main.async {
                    self.append("[Cloud] Restore completed.")
                    self.isBusy = false
                    RepositoriesConfigStore.shared.recordRepoUsedAzure(containerSASURL: sasURL)
                    self.refreshCloudRepoUsage()
                }
            } catch {
                DispatchQueue.main.async {
                    self.append("[Cloud] Restore failed: \(error.localizedDescription)")
                    self.isBusy = false
                }
            }
        }
    }

    func append(_ s: String) { log.append(s) }

    /// Copy the entire log to the macOS clipboard
    func copyLogToClipboard() {
        let paste = NSPasteboard.general
        paste.clearContents()
        paste.setString(log.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Config load/save
    func loadConfig() {
        let cfg = AppConfigIO.load(from: AppConfig.defaultRepoConfigURL)
        if let repo = cfg.repoPath { repoPath = repo }
        includeText = cfg.include.joined(separator: ", ")
        excludeText = cfg.exclude.joined(separator: ", ")
        concurrencyText = cfg.concurrency.map(String.init) ?? ""
        azureSASText = cfg.azureSAS ?? ""
        append("Loaded config from \(AppConfig.defaultRepoConfigURL.path)")
    }

    func saveConfig() {
        let include = includeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exclude = excludeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let conc = Int(concurrencyText.trimmingCharacters(in: .whitespaces))
        let cfg = AppConfig(repoPath: repoPath, include: include, exclude: exclude, concurrency: conc, azureSAS: azureSASText.isEmpty ? nil : azureSASText)
        do {
            try AppConfigIO.save(cfg, to: AppConfig.defaultRepoConfigURL)
            append("Saved config to \(AppConfig.defaultRepoConfigURL.path)")
            // Refresh usage views if identifiers changed
            refreshRepoUsage()
            refreshCloudRepoUsage()
        } catch {
            append("Save config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Repositories.json accessors
    func refreshRepoUsage() {
        let key = RepositoriesConfigStore.keyForLocal(URL(fileURLWithPath: repoPath))
        let info = RepositoriesConfigStore.shared.config.repositories[key]
        DispatchQueue.main.async { self.repoUsage = info }
    }

    func refreshCloudRepoUsage() {
        guard !azureSASText.isEmpty, let url = URL(string: azureSASText) else {
            DispatchQueue.main.async { self.cloudRepoUsage = nil }
            return
        }
        let key = RepositoriesConfigStore.keyForAzure(url)
        let info = RepositoriesConfigStore.shared.config.repositories[key]
        DispatchQueue.main.async { self.cloudRepoUsage = info }
    }
}

/// The main, modernized view using a sidebar and toolbar.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedSnapshotID: String?
    @State private var selectedCloudSnapshotID: String?
    @State private var showRepositoriesPanel = false
    @State private var showLogsPanel = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 900, minHeight: 560)
    .onAppear { model.loadConfig(); model.ensureRepo(); model.refreshSnapshots(); model.refreshCloudSnapshots(); model.refreshRepoUsage(); model.refreshCloudRepoUsage() }
    .onChange(of: model.repoPath) { _ in model.refreshRepoUsage() }
    .onChange(of: model.azureSASText) { _ in model.refreshCloudRepoUsage() }
    .sheet(isPresented: $showRepositoriesPanel) {
        RepositoriesPanel()
    }
    .sheet(isPresented: $showLogsPanel) {
        LogsPanel()
    }
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
                if let info = model.repoUsage {
                    UsageSummaryView(title: "Last used", date: info.lastUsedAt)
                    if !info.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Source last backups:").font(.caption).foregroundStyle(.secondary)
                            ForEach(info.sources.sorted(by: { $0.path < $1.path }), id: \.path) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    Text(s.path).lineLimit(1).truncationMode(.middle).font(.caption)
                                    Spacer()
                                    Text(s.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
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
            Section("Configuration") {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                    TextField("Include (comma-separated)", text: $model.includeText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                    TextField("Exclude (comma-separated)", text: $model.excludeText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.secondary)
                    TextField("Concurrency (empty = default)", text: $model.concurrencyText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    TextField("Azure SAS URL", text: $model.azureSASText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer()
                    Button("Save Config") { model.saveConfig() }
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
            Section("Cloud") {
                HStack(spacing: 8) {
                    Button("Init Cloud") { model.ensureAzureRepo() }
                    Button("List Cloud") { model.refreshCloudSnapshots() }
                    Button("Cloud Backup") { model.runCloudBackup() }
                        .disabled(model.isBusy || model.sources.isEmpty)
                }
                if let info = model.cloudRepoUsage {
                    UsageSummaryView(title: "Last used (cloud)", date: info.lastUsedAt)
                    if !info.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud source last backups:").font(.caption).foregroundStyle(.secondary)
                            ForEach(info.sources.sorted(by: { $0.path < $1.path }), id: \.path) { s in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    Text(s.path).lineLimit(1).truncationMode(.middle).font(.caption)
                                    Spacer()
                                    Text(s.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section("Cloud Snapshots") {
                if model.cloudSnapshots.isEmpty {
                    Text("No cloud snapshots").foregroundStyle(.secondary)
                } else {
                    ForEach(model.cloudSnapshots, id: \.id) { it in
                        SnapshotRow(item: it)
                            .tag(it.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedCloudSnapshotID = it.id }
                            .listRowBackground((selectedCloudSnapshotID == it.id) ? Color.accentColor.opacity(0.15) : Color.clear)
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
            .textSelection(.enabled)
        }
        .frame(minHeight: 160)
        .contextMenu {
            Button("Copy All") { model.copyLogToClipboard() }
        }
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
            Button(action: {
                guard let id = selectedCloudSnapshotID else { return }
                pickFolder(single: true) { dest in
                    model.runCloudRestore(snapshotId: id, destination: dest)
                }
            }) {
                Label("Cloud Restore", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isBusy || selectedCloudSnapshotID == nil)
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
        ToolbarItem(placement: .automatic) {
            Button(action: { model.copyLogToClipboard() }) {
                Label("Copy Log", systemImage: "doc.on.doc")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { showRepositoriesPanel = true }) {
                Label("Repositories", systemImage: "tray.full")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { showLogsPanel = true }) {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
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
                if !item.sources.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(item.sources.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer()
            Label("\(item.totalFiles)", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.caption)
            Text("\(item.totalBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .if(!item.sources.isEmpty) { view in
            view.help(item.sources.joined(separator: "\n"))
        }
    }
}

// MARK: - View helpers
private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Small utility view for usage display
private struct UsageSummaryView: View {
    let title: String
    let date: Date?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(date?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
