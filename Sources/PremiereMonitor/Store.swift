import Foundation
import Darwin

enum Store {
    /// One-time migration from the app's old name: if "Reprise" doesn't exist yet but
    /// "Encore" does, copy it over (copy, not move — the old folder is left in place as an
    /// automatic backup) so the rename doesn't lose the tracked list, settings, or log.
    /// Only fires once; every launch after the first sees "Reprise" already there.
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Reprise", isDirectory: true)
        let legacyDir = base.appendingPathComponent("Encore", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.copyItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let videosFile = appSupportDir.appendingPathComponent("videos.json")
    static let logFile = appSupportDir.appendingPathComponent("premieres.log")
    static let lockFile = appSupportDir.appendingPathComponent("encore.lock")
    static let settingsFile = appSupportDir.appendingPathComponent("settings.json")
    static let channelsFile = appSupportDir.appendingPathComponent("channels.json")
    static let discoveredFile = appSupportDir.appendingPathComponent("discovered.json")

    private static var lockFileDescriptor: Int32 = -1

    /// Tries to acquire an exclusive lock so two instances can never overwrite each other's
    /// videos.json at the same time. Returns false if an instance is already running.
    static func acquireSingleInstanceLock() -> Bool {
        let fd = open(lockFile.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return true } // couldn't create the lock file: just run anyway
        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(fd)
            return false
        }
        lockFileDescriptor = fd
        return true
    }

    /// Of load() een bestaand bestand niet kon lezen. Zolang dit aanstaat mag
    /// save() niet schrijven — anders overschrijft de eerstvolgende actie
    /// (zelfs een simpele "video toevoegen") je bestaande lijst met een lijst
    /// van bijna niets. Dat gat bestond op 19-09-2026: een niet-optioneel veld
    /// liet het decoderen mislukken, load() gaf stilzwijgend [] terug, en
    /// alleen een toevallige `guard !videos.isEmpty` in de pollus voorkwam dat
    /// de lege lijst automatisch werd weggeschreven. Een handmatige actie in
    /// de UI had er wél doorheen gekund.
    private(set) static var loadFailed = false

    static func load() -> [MonitoredVideo] {
        guard let data = try? Data(contentsOf: videosFile) else {
            return []          // bestand bestaat nog niet: gewoon een lege start
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let videos = try? decoder.decode([MonitoredVideo].self, from: data) {
            loadFailed = false
            return videos
        }

        // Het bestand bestaat en heeft inhoud, maar het decoderen mislukte.
        // Dit is geen "geen video's" — dit is een fout die niet stil mag
        // blijven. Eerst een kopie wegzetten zodat er niets verloren gaat,
        // ook als er straks per ongeluk toch overheen geschreven wordt.
        loadFailed = true
        let backup = videosFile.deletingLastPathComponent()
            .appendingPathComponent("videos.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? data.write(to: backup)
        appendLog("[Store] ❌ Could not read videos.json — original preserved as "
                  + "\(backup.lastPathComponent). Saving is blocked until this is investigated.")
        return []
    }

    static func save(_ videos: [MonitoredVideo]) {
        guard !loadFailed else {
            appendLog("[Store] ⚠️ Save skipped: videos.json gave a read error earlier, "
                      + "and I refuse to write a possibly-broken list over the real one.")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(videos) else { return }
        // .atomic: Foundation writes to a temp file next to the target and
        // renames it into place, so a crash or power loss mid-write can never
        // leave a half-written videos.json — you either get the old file or
        // the new one, never something in between. Plain write(to:) doesn't
        // give you that; it can be interrupted mid-write.
        try? data.write(to: videosFile, options: .atomic)
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFile) else { return AppSettings() }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            appendLog("[Store] ⚠️ Could not read settings.json — using default settings.")
            return AppSettings()
        }
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsFile, options: .atomic)
    }

    static func loadChannels() -> [TrackedChannel] {
        guard let data = try? Data(contentsOf: channelsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TrackedChannel].self, from: data)) ?? []
    }

    static func saveChannels(_ channels: [TrackedChannel]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(channels) else { return }
        try? data.write(to: channelsFile, options: .atomic)
    }

    static func loadDiscovered() -> [DiscoveredVideo] {
        guard let data = try? Data(contentsOf: discoveredFile) else { return [] }
        return (try? JSONDecoder().decode([DiscoveredVideo].self, from: data)) ?? []
    }

    static func saveDiscovered(_ discovered: [DiscoveredVideo]) {
        guard let data = try? JSONEncoder().encode(discovered) else { return }
        try? data.write(to: discoveredFile, options: .atomic)
    }

    /// Generous for a text log fed by 30-second-interval checks — this caps premieres.log
    /// from growing forever, which it did unconditionally before. One rotated backup
    /// (premieres.log.old) is kept, so at most ~2x this much ever sits on disk.
    private static let maxLogFileBytes = 5_000_000

    private static func rotateLogIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path))?[.size] as? Int,
              size > maxLogFileBytes else { return }
        let oldLog = logFile.deletingLastPathComponent().appendingPathComponent("premieres.log.old")
        try? FileManager.default.removeItem(at: oldLog)
        try? FileManager.default.moveItem(at: logFile, to: oldLog)
    }

    static func appendLog(_ line: String) {
        rotateLogIfNeeded()
        let entry = line + "\n"
        guard let entryData = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(entryData)
                try? handle.close()
            }
        } else {
            try? entry.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}
