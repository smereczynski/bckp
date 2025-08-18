import SwiftUI
import AppKit
import BackupCore

private struct DisplayLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let subsystem: String
    let message: String
    let context: [String: String]?
    let raw: String
}

/// Panel to browse and tail NDJSON log files written by BackupCore's Logger.
struct LogsPanel: View {
    @State private var logFiles: [URL] = []
    @State private var selectedFile: URL? = nil
    @State private var lines: [DisplayLine] = []

    @State private var minLevel: LogLevel = .info
    @State private var subsystemFilterText: String = ""
    @State private var showRaw: Bool = false
    @State private var follow: Bool = true

    // Tail state
    @State private var fileHandle: FileHandle? = nil
    @State private var tailOffset: UInt64 = 0
    @State private var tailTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 12) {
            header
            controls
            content
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { refreshFiles(selectToday: true) }
        .onChange(of: selectedFile) { _ in loadSelectedFile(resetOffset: true) }
        .onChange(of: minLevel) { _ in /* re-render only */ }
        .onChange(of: subsystemFilterText) { _ in /* re-render only */ }
        .onDisappear { stopTailing() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logs").font(.title2.weight(.semibold))
                Text("NDJSON logs under \(Logger.defaultLogsDirectory().path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { refreshFiles(selectToday: false) } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button { revealLogsFolder() } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("File", selection: Binding(get: {
                selectedFile?.path ?? ""
            }, set: { newPath in
                selectedFile = logFiles.first(where: { $0.path == newPath })
            })) {
                ForEach(logFiles, id: \.path) { url in
                    Text(url.lastPathComponent).tag(url.path)
                }
            }
            .frame(maxWidth: 320)

            Divider()

            Picker("Level", selection: $minLevel) {
                Text("Error").tag(LogLevel.error)
                Text("Warning").tag(LogLevel.warning)
                Text("Info").tag(LogLevel.info)
                Text("Debug").tag(LogLevel.debug)
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            TextField("Subsystems (comma-separated)", text: $subsystemFilterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Toggle("Raw JSON", isOn: $showRaw)
            Toggle("Follow", isOn: Binding(get: { follow }, set: { v in
                follow = v
                if v { startTailing() } else { stopTailing() }
            }))
        }
    }

    private var content: some View {
        let filtered = filteredLines()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { line in
                        if showRaw {
                            Text(line.raw)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(line.id)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(iso8601(line.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(line.level.rawValue.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(colorForLevel(line.level))
                                Text(line.subsystem)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(line.message)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer(minLength: 0)
                                if let ctx = line.context, !ctx.isEmpty {
                                    Text("{" + ctx.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",") + "}")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .id(line.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .onChange(of: lines.count) { _ in
                if follow, let last = filtered.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: showRaw) { _ in
                if follow, let last = filtered.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    // MARK: - Logic
    private func refreshFiles(selectToday: Bool) {
        stopTailing()
        let dir = Logger.defaultLogsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        logFiles = urls.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if selectToday {
            // Pick today's file if available, else newest
            if let todays = todaysLogURL(in: logFiles) { selectedFile = todays }
            else { selectedFile = logFiles.first }
        } else {
            if let current = selectedFile { selectedFile = current } else { selectedFile = logFiles.first }
        }
    }

    private func todaysLogURL(in files: [URL]) -> URL? {
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let name = "bckp-\(fmt.string(from: Date())).log"
        return files.first(where: { $0.lastPathComponent == name })
    }

    private func loadSelectedFile(resetOffset: Bool) {
        guard let url = selectedFile else { lines = []; return }
        stopTailing()
        let (entries, raws) = readAllEntries(from: url)
        lines = zip(entries, raws).map { e, r in
            DisplayLine(timestamp: e.timestamp, level: e.level, subsystem: e.subsystem, message: e.message, context: e.context, raw: r)
        }
        if resetOffset {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value {
                tailOffset = size
            } else {
                tailOffset = 0
            }
        }
        if follow { startTailing() }
    }

    private func startTailing() {
        guard let url = selectedFile else { return }
        stopTailing()
        do {
            fileHandle = try FileHandle(forReadingFrom: url)
        } catch {
            fileHandle = nil
            return
        }
        tailTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let h = fileHandle else { return }
            do {
                let end = try h.seekToEnd()
                if end > tailOffset {
                    let length = end - tailOffset
                    try h.seek(toOffset: tailOffset)
                    if let data = try h.read(upToCount: Int(length)), let text = String(data: data, encoding: .utf8) {
                        appendNewLines(text)
                    }
                    tailOffset = end
                }
            } catch {
                // ignore
            }
        }
        RunLoop.main.add(tailTimer!, forMode: .common)
    }

    private func stopTailing() {
        tailTimer?.invalidate(); tailTimer = nil
        if let h = fileHandle { try? h.close() }
        fileHandle = nil
    }

    private func appendNewLines(_ text: String) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var newLines: [DisplayLine] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map({ String($0) }) {
            if let d = rawLine.data(using: .utf8), let e = try? dec.decode(LogEntry.self, from: d) {
                newLines.append(DisplayLine(timestamp: e.timestamp, level: e.level, subsystem: e.subsystem, message: e.message, context: e.context, raw: rawLine))
            }
        }
        if !newLines.isEmpty { lines.append(contentsOf: newLines) }
    }

    private func readAllEntries(from url: URL) -> ([LogEntry], [String]) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return ([], []) }
        let raws = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { String($0) }
        var entries: [LogEntry] = []
        for line in raws {
            if let d = line.data(using: .utf8), let e = try? dec.decode(LogEntry.self, from: d) {
                entries.append(e)
            }
        }
        return (entries, raws)
    }

    private func filteredLines() -> [DisplayLine] {
        let subs = Set(subsystemFilterText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        return lines.filter { line in
            let levelOK = line.level <= minLevel
            let subsystemOK = subs.isEmpty || subs.contains(line.subsystem.lowercased())
            return levelOK && subsystemOK
        }
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        case .debug: return .gray
        }
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    private func revealLogsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Logger.defaultLogsDirectory()])
    }
}
