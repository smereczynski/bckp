import SwiftUI
import AppKit
import BackupCore
import Combine

private struct RepoRow: Identifiable {
    let key: String
    let info: RepositoryInfo
    var id: String { key }
}

// MARK: - File change observer for live auto-refresh
private final class ReposFileObserver: ObservableObject {
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private let url: URL

    init(url: URL) {
        self.url = url
        start()
    }

    deinit { stop() }

    func start() {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }
        let q = DispatchQueue.global(qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: q)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // On any change, notify observers on main thread
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
            // If deleted/renamed, try to reattach next time
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.start()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd != -1 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd != -1 { close(fd); fd = -1 }
    }
}

/// A dedicated panel to inspect repositories.json contents.
/// Lists all known repositories (local paths and Azure container URLs),
/// shows last used time and per-source last backup times.
struct RepositoriesPanel: View {
    enum SortOption: String, CaseIterable, Identifiable {
        case key = "Key"
        case lastUsed = "Last used"
        case lastBackup = "Last backup"
        var id: String { rawValue }
    }

    @State private var rows: [RepoRow] = []
    @State private var filter: String = ""
    @State private var sortBy: SortOption = .key
    @StateObject private var fileObserver: ReposFileObserver

    init() {
        _fileObserver = StateObject(wrappedValue: ReposFileObserver(url: RepositoriesPanel.repositoriesFileURL()))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            searchBar
            List {
                ForEach(filteredAndSortedRows()) { row in
                    Section(header: headerRow(for: row)) {
                        UsageRow(title: "Last used", date: row.info.lastUsedAt)
                        if row.info.sources.isEmpty {
                            Text("No sources configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(row.info.sources.sorted(by: { $0.path < $1.path }), id: \.path) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(s.path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
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
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { reload() }
        .onReceive(fileObserver.objectWillChange) { _ in reload() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Repositories")
                    .font(.title2.weight(.semibold))
                Text("Usage and last backups recorded in repositories.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Sort by", selection: $sortBy) {
                ForEach(SortOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.menu)
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by key or source path", text: $filter)
            Spacer()
            Button {
                revealConfigFile()
            } label: {
                Label("Open JSON", systemImage: "doc")
            }
        }
    }

    private func filteredAndSortedRows() -> [RepoRow] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [RepoRow]
        if trimmed.isEmpty {
            filtered = rows
        } else {
            let f = trimmed.lowercased()
            filtered = rows.filter { row in
                if row.key.lowercased().contains(f) { return true }
                return row.info.sources.contains { $0.path.lowercased().contains(f) }
            }
        }
        return filtered.sorted(by: sortComparator)
    }

    private func reload() {
        let cfg = RepositoriesConfigStore.shared.config
        rows = cfg.repositories
            .map { RepoRow(key: $0.key, info: $0.value) }
            .sorted(by: sortComparator)
    }

    private func revealConfigFile() {
        let url = Self.repositoriesFileURL()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sortComparator(_ a: RepoRow, _ b: RepoRow) -> Bool {
        switch sortBy {
        case .key:
            return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
        case .lastUsed:
            return (a.info.lastUsedAt ?? .distantPast) > (b.info.lastUsedAt ?? .distantPast)
        case .lastBackup:
            let aMax = a.info.sources.compactMap { $0.lastBackupAt }.max() ?? .distantPast
            let bMax = b.info.sources.compactMap { $0.lastBackupAt }.max() ?? .distantPast
            return aMax > bMax
        }
    }

    private func headerRow(for row: RepoRow) -> some View {
        HStack(spacing: 8) {
            Text(row.key).font(.headline)
            Spacer()
            Button {
                copyToClipboard(row.key)
            } label: {
                Image(systemName: "doc.on.doc")
                    .help("Copy key")
            }
            .buttonStyle(.plain)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func repositoriesFileURL() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        #else
        let base = URL(fileURLWithPath: NSHomeDirectory())
        #endif
        return base.appendingPathComponent("bckp", isDirectory: true).appendingPathComponent("repositories.json")
    }
}

private struct UsageRow: View {
    let title: String
    let date: Date?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(date?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
