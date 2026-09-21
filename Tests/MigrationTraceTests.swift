import Foundation

@main
struct MigrationTraceTests {
    static func expect(_ value: Bool, line: UInt = #line) {
        guard value else {
            FileHandle.standardError.write(Data("FAIL log check at line \(line)\n".utf8))
            exit(1)
        }
    }

    static func main() async throws {
        let expected = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.path
        let logURL = MigrationTrace.logURL
        guard logURL.standardizedFileURL.path.hasPrefix(expected + "/") else {
            fatalError("Refusing to test outside temporary directory: \(logURL.path)")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        MigrationTrace.event("smoke.begin")
        var contents = try String(contentsOf: logURL, encoding: .utf8)
        expect(contents.contains("session=\(MigrationTrace.sessionID.uuidString) event=smoke.begin"))

        let firstMigration = UUID()
        let secondMigration = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                MigrationTrace.$migrationID.withValue(firstMigration) {
                    MigrationTrace.event("concurrent.first")
                }
            }
            group.addTask {
                MigrationTrace.$migrationID.withValue(secondMigration) {
                    MigrationTrace.event("concurrent.second")
                }
            }
        }
        MigrationTrace.$migrationID.withValue(firstMigration) {
            MigrationTrace.command("EXEC context-check")
        }
        contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        expect(lines.contains { $0.contains("migration=\(firstMigration.uuidString) event=concurrent.first") })
        expect(lines.contains { $0.contains("migration=\(secondMigration.uuidString) event=concurrent.second") })
        expect(lines.contains { $0.contains("migration=\(firstMigration.uuidString) EXEC context-check") })
        print("PASS session and concurrent migration contexts remain isolated")

        // Even invalid plist bytes must survive for diagnosis. Timestamp the
        // fixtures explicitly so retention order doesn't depend on test speed.
        var ids: [UUID] = []
        for index in 0..<12 {
            let id = UUID()
            ids.append(id)
            let data = Data("raw response \(index)".utf8)
            guard let saved = MigrationTrace.saveCapacityQuery(data, queryID: id) else {
                fatalError("Snapshot was not saved")
            }
            expect(try Data(contentsOf: saved) == data)
            try fileManager.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: saved.path
            )
        }
        let snapshots = logURL.deletingLastPathComponent().appendingPathComponent("CapacityQueries")
        let retained = try fileManager.contentsOfDirectory(atPath: snapshots.path)
        expect(Set(retained) == Set(ids.dropFirst(2).map { "\($0.uuidString).plist" }))
        print("PASS exact raw response persistence and retention of the latest ten queries")

        for index in 1...2 {
            let data = Data(("round-\(index)\n" + String(repeating: "x", count: 8_000_001)).utf8)
            try data.write(to: logURL)
            MigrationTrace.event("rotation.\(index)")
        }
        let archive = logURL.appendingPathExtension("1")
        expect(try String(contentsOf: archive, encoding: .utf8).hasPrefix("round-2\n"))
        expect(!fileManager.fileExists(atPath: logURL.appendingPathExtension("2").path))
        expect(!fileManager.fileExists(atPath: logURL.appendingPathExtension("3").path))
        expect(try String(contentsOf: logURL, encoding: .utf8).contains("rotation.2"))
        print("PASS workflow rotation preserves one 8 MB history and continues writing")
    }
}
