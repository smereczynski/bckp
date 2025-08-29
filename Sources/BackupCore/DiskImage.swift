import Foundation

// MARK: - DiskImage (macOS)
// Minimal helper to create and mount sparse disk images using hdiutil.
// Note: This uses shelling out to /usr/bin/hdiutil which is available on macOS.

enum DiskImageError: Error { case commandFailed(String), parseFailed }

struct DiskImage {
    struct AttachResult: Decodable {
        struct Entity: Decodable {
            let contentHint: String?
            let devEntry: String?
            let mountPoint: String?
            private enum CodingKeys: String, CodingKey {
                case contentHint = "content-hint"
                case devEntry = "dev-entry"
                case mountPoint = "mount-point"
            }
        }
        let systemEntities: [Entity]
        private enum CodingKeys: String, CodingKey { case systemEntities = "system-entities" }
    }

    @discardableResult
    private static func runHdiutil(_ args: [String], input: Data? = nil) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        if let input = input {
            let inp = Pipe()
            proc.standardInput = inp
            try proc.run()
            inp.fileHandleForWriting.write(input)
            inp.fileHandleForWriting.closeFile()
        } else {
            try proc.run()
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "hdiutil failed"
            throw DiskImageError.commandFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.fileHandleForReading.readDataToEndOfFile()
    }

    static func createSparseImage(at url: URL, size: String, volumeName: String, fileSystem: String = "APFS", type: String = "SPARSE", encryption: EncryptionSettings? = nil) throws {
        // hdiutil create -type SPARSE -fs APFS -volname <name> [-encryption AES-256 -certificate <der> ...] -size <size> <path>
        let (encArgs, cleanup) = try DiskImageEncryptionArgs.build(for: encryption)
        defer { cleanup() }
        var args = ["create", "-type", type, "-fs", fileSystem, "-volname", volumeName]
        args.append(contentsOf: encArgs)
        args.append(contentsOf: ["-size", size, url.path])
        _ = try runHdiutil(args)
    }

    static func attach(imageURL: URL, mountpoint: URL, nobrowse: Bool = true) throws -> (device: String, mountPoint: URL) {
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: true)
        var args = ["attach", imageURL.path, "-mountpoint", mountpoint.path, "-owners", "on", "-noverify", "-plist"]
        if nobrowse { args.append("-nobrowse") }
        let data = try runHdiutil(args)
        let result = try PropertyListDecoder().decode(AttachResult.self, from: data)
        guard let ent = result.systemEntities.first(where: { $0.devEntry != nil }), let dev = ent.devEntry else { throw DiskImageError.parseFailed }
        // hdiutil respects requested mountpoint; prefer it if present
        let mnt = ent.mountPoint ?? mountpoint.path
        return (device: dev, mountPoint: URL(fileURLWithPath: mnt))
    }

    /// Attempt to detach a device, with an optional busy-check on the mount point to fail fast when open files exist.
    /// If `mountPoint` is provided and appears busy (via `lsof`), this throws without attempting a force detach.
    static func detach(device: String, mountPoint: URL? = nil, force: Bool = false) throws {
        // Best-effort busy check using lsof when a mount point is known.
        if let mp = mountPoint, isMountPointBusy(mp) {
            throw DiskImageError.commandFailed("Cannot detach \(device): mount point is busy (open files under \(mp.path))")
        }
        var args = ["detach", device]
        if force { args.insert("-force", at: 1) }
        _ = try runHdiutil(args)
    }

    /// Returns true if there are open file descriptors under the mount point (best-effort using /usr/sbin/lsof).
    private static func isMountPointBusy(_ mountPoint: URL) -> Bool {
        let proc = Process()
        // lsof typically resides at /usr/sbin/lsof on macOS
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-t", "+D", mountPoint.path]
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
            // If lsof failed to run or returned an error, assume not busy (don't block detaches due to tooling absence)
            if proc.terminationStatus != 0 { return false }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if data.isEmpty { return false }
            // Any output indicates at least one PID has files open under mountPoint
            return true
        } catch {
            // If lsof isn't available, fall back to no busy detection
            return false
        }
    }
}
