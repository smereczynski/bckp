import XCTest
import Foundation
@testable import BackupCore

#if os(macOS)
final class CLIDrivesIntegrationTests: XCTestCase {
    func testDrivesJSONContainsSelectedUUIDWhenPresent() throws {
        // Run only when explicitly enabled to avoid slowing down default test runs.
        let env = ProcessInfo.processInfo.environment
        guard env["BCKP_RUN_CLI_TESTS"] == "1" else {
            throw XCTSkip("Set BCKP_RUN_CLI_TESTS=1 to run CLI integration tests.")
        }

        // Pick an external disk that has a UUID.
        let disks = listExternalDiskIdentities()
        guard let disk = disks.first(where: { $0.volumeUUID != nil }) else {
            throw XCTSkip("No external/removable volume with UUID found; skipping CLI drives JSON test.")
        }
        let uuid = disk.volumeUUID!

        // Run the already-built CLI binary directly to avoid re-entrant `swift run` from tests.
        guard let exeURL = try findBuiltBckpExecutable() else {
            throw XCTSkip("Could not locate built bckp executable under .build; skipping CLI integration test.")
        }

        let result = try runProcess(executable: exeURL, arguments: ["drives", "--json"], cwd: packageRootURL(), timeoutSeconds: 20)

        if result.timedOut {
            XCTFail("CLI timed out after 20s. stderr=\(result.stderr) output=\(result.stdout)")
            return
        }
        XCTAssertEqual(result.status, 0, "CLI exited with non-zero status. stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains(uuid), "Expected drives --json output to contain UUID \(uuid). Output=\n\(result.stdout)")
    }
}
#endif

// MARK: - Helpers

private func packageRootURL(file: StaticString = #filePath) -> URL {
    // Start from the current file location and walk up until Package.swift is found.
    var url = URL(fileURLWithPath: String(describing: file))
    url.deleteLastPathComponent() // .../Tests/BackupCoreTests
    for _ in 0..<6 { // reasonable safety bound
        let candidate = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
            return candidate
        }
        url = candidate
    }
    // Fallback to current directory
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func findBuiltBckpExecutable() throws -> URL? {
    let root = packageRootURL()

    // Candidate relative paths for SwiftPM build output across configs/architectures.
    var rels = [
        ".build/debug/bckp",
        ".build/release/bckp",
        ".build/Debug/bckp",
        ".build/Release/bckp",
        ".build/arm64-apple-macosx/debug/bckp",
        ".build/x86_64-apple-macosx/debug/bckp",
        ".build/arm64-apple-macosx/release/bckp",
        ".build/x86_64-apple-macosx/release/bckp",
    ]

    // If CONFIGURATION is provided (e.g., Debug/Release), prioritize that.
    let env = ProcessInfo.processInfo.environment
    if let cfg = env["CONFIGURATION"]?.lowercased() {
        #if arch(arm64)
        let triple = "arm64-apple-macosx"
        #else
        let triple = "x86_64-apple-macosx"
        #endif
        rels.insert(".build/\(cfg)/bckp", at: 0)
        rels.insert(".build/\(triple)/\(cfg)/bckp", at: 1)
    }

    for rel in rels {
        let url = root.appendingPathComponent(rel)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
    }
    return nil
}

private func runProcess(executable: URL, arguments: [String], cwd: URL, timeoutSeconds: TimeInterval) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    p.currentDirectoryURL = cwd
    let out = Pipe(); p.standardOutput = out
    let err = Pipe(); p.standardError = err
    try p.run()

    let start = Date()
    while p.isRunning {
        if Date().timeIntervalSince(start) > timeoutSeconds {
            p.terminate()
            break
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    // Ensure process has settled
    p.waitUntilExit()

    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: outData, encoding: .utf8) ?? ""
    let stderr = String(data: errData, encoding: .utf8) ?? ""
    let timedOut = Date().timeIntervalSince(start) > timeoutSeconds
    return (p.terminationStatus, stdout, stderr, timedOut)
}
