import Foundation
import SQLite3

// These doubles prevent the standalone test executable from touching app audio or settings.
struct DictationAudioMetadata: Codable, Equatable, Sendable {
    let fileName: String
    let durationMilliseconds: Int
    let byteCount: Int
    let sampleRate: Int
    let channels: Int
    let model: String?
}

final class DictationAudioHistoryStore {
    static let shared = DictationAudioHistoryStore()
    @discardableResult func deleteAudio(fileName: String) -> Int { 0 }
    func deleteAllAudioFiles() {}
    func audioUsageBytes() -> Int { 0 }
    func deleteUnreferencedAudioFiles(referencedFileNames: Set<String>) -> (fileCount: Int, byteCount: Int) { (0, 0) }
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var audioHistoryBudgetBytes: Int { 1_000_000 }
    var weekendsDontBreakStreak: Bool { false }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func debug(_ message: String, source: String) {}
}

@main struct HistoryPersistenceBoundaryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fluid-history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "fluid-history-tests-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated history defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "TranscriptionHistoryEntries"
        let audio = DictationAudioMetadata(
            fileName: "test.wav",
            durationMilliseconds: 1000,
            byteCount: 32_000,
            sampleRate: 16_000,
            channels: 1,
            model: "test"
        )
        let legacy = (0..<8400).map { index in
            TranscriptionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                rawText: "Raw \(index)",
                processedText: String(repeating: "Test dictation \(index). ", count: 12),
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: true,
                processingModel: "test",
                transcriptionDurationMilliseconds: 50,
                aiProcessingDurationMilliseconds: 100,
                aiTokensPerSecond: 500,
                audio: index == 0 ? audio : nil
            )
        }
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let url = root.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        // No actor suspension: these mutations necessarily precede startup loading.
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        store.attachAudio(audio, to: newID)
        store.deleteEntry(id: legacy[1].id)
        try await store.waitUntilLoaded()
        await store.finishPendingWrites()
        precondition(defaults.data(forKey: key) == nil, "Retire legacy only after successful import")
        precondition(store.entries.count == 8400)
        precondition(store.entries.first(where: { $0.id == newID })?.audio == audio)
        precondition(!store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(reloaded == store.entries, "Migration, metadata and concurrent startup edits must round-trip")
        print("PASS: 8,400-entry migration, exact round-trip, startup insert/audio/delete")

        // Reject a write touching any old entry. A new dictation and its audio must only update their row.
        try self.sql(url, "CREATE TRIGGER reject_old BEFORE INSERT ON history WHEN NEW.id != '\(newID.uuidString)' BEGIN SELECT RAISE(FAIL, 'unrelated row rewritten'); END")
        let enqueueStart = ProcessInfo.processInfo.systemUptime
        store.attachAudio(audio, to: newID)
        let enqueueMs = (ProcessInfo.processInfo.systemUptime - enqueueStart) * 1000
        await store.finishPendingWrites()
        await Task.yield()
        precondition(store.persistenceError == nil, "Updating one row must not rewrite unrelated history")
        print("PASS: single-row audio update; main actor enqueue \(enqueueMs) ms")
        try self.sql(url, "DROP TRIGGER reject_old")

        try self.sql(url, "CREATE TRIGGER reject_all BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        let failedID = UUID()
        store.addEntry(id: failedID, rawText: "pending", processedText: "Unsaved", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError != nil)
        precondition(store.entries.contains(where: { $0.id == failedID }))
        let afterFailure = try await writer.load()
        precondition(!afterFailure.contains(where: { $0.id == failedID }))
        store.retryPersistence()
        await store.finishPendingWrites()
        let afterFailedReplacement = try await writer.load()
        precondition(afterFailedReplacement == afterFailure, "Failed replacement must roll back its initial DELETE")
        try self.sql(url, "DROP TRIGGER reject_all")
        store.retryPersistence()
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError == nil)
        let afterRetry = try await writer.load()
        precondition(afterRetry.contains(where: { $0.id == failedID }))
        print("PASS: failed write stays in memory, surfaces error, retry restores complete snapshot")

        store.clearAllHistory()
        store.attachAudio(audio, to: newID)
        await store.finishPendingWrites()
        let afterClear = try await writer.load()
        precondition(afterClear.isEmpty, "Late audio must not resurrect deleted entries")
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestart.isEmpty, "Migration marker must prevent old history resurrection")
        print("PASS: clear, late audio, restart and stale legacy cannot resurrect history")

        let badURL = root.appendingPathComponent("bad.sqlite3")
        let badData = Data("invalid JSON".utf8)
        defaults.set(badData, forKey: key)
        let badStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: badURL))
        do {
            try await badStore.waitUntilLoaded()
            preconditionFailure("Corrupt legacy must fail visibly")
        } catch {}
        precondition(!badStore.isLoading && badStore.persistenceError != nil)
        precondition(defaults.data(forKey: key) == badData)
        try defaults.set(JSONEncoder().encode([legacy[0]]), forKey: key)
        badStore.retryPersistence()
        try await badStore.waitUntilLoaded()
        precondition(badStore.entries == [legacy[0]])
        print("PASS: corrupt migration preserves source, exits loading and supports retry")

        let restoreStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url))
        restoreStore.restore(from: [legacy[3]])
        try await restoreStore.waitUntilLoaded()
        await restoreStore.finishPendingWrites()
        precondition(restoreStore.entries == [legacy[3]])
        let afterRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestore == [legacy[3]])
        print("PASS: restore during loading replaces both memory and disk")
    }

    static func sql(_ url: URL, _ command: String) throws {
        var handle: OpaquePointer?
        precondition(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        precondition(sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK)
    }
}
