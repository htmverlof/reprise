import Foundation

enum VideoStatus: String, Codable {
    // Raw values are kept stable (not translated) so existing saved data keeps decoding correctly.
    case waiting = "Wachten"
    case downloadingLive = "LIVE downloaden"
    case vodPending = "Wacht op VOD"
    case downloadingVod = "VOD downloaden"
    case done = "Klaar"

    var displayName: String {
        switch self {
        case .waiting: return "Waiting"
        case .downloadingLive: return "Downloading LIVE"
        case .vodPending: return "Waiting for VOD"
        case .downloadingVod: return "Downloading VOD"
        case .done: return "Done"
        }
    }

    var color: String {
        switch self {
        case .waiting: return "gray"
        case .downloadingLive: return "red"
        case .vodPending: return "orange"
        case .downloadingVod: return "blue"
        case .done: return "green"
        }
    }
}

struct MonitoredVideo: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var url: String
    var label: String
    var scheduledDate: Date
    var status: VideoStatus = .waiting
    var liveDone: Bool = false
    var vodDone: Bool = false
    var lastChecked: Date? = nil
    var finalFilePath: String? = nil
    /// Of de "premiere is live"-melding al verstuurd is. Losgekoppeld van
    /// liveDone, want dat vlaggetje gaat pas aan bij een geslaagde download —
    /// waardoor een mislukking elke ronde opnieuw dezelfde melding stuurde.
    ///
    /// Optioneel, en dat is geen slordigheid: Swift gebruikt standaardwaarden
    /// níet bij het decoderen, dus een niet-optioneel veld laat het inlezen van
    /// een bestaande videos.json mislukken. Store.swift vangt dat af met
    /// `?? []` — je lijst is dan stilzwijgend leeg en er wordt niets meer
    /// bewaakt. Precies dat gebeurde op 19-09-2026.
    var liveNotified: Bool? = nil
    /// Tot wanneer we deze video met rust laten na een mislukte poging.
    var retryNotBefore: Date? = nil
    /// Of de "nog steeds niet live, we vertragen nu"-melding al verstuurd is.
    /// Optioneel om dezelfde reden als liveNotified hierboven.
    var stillWaitingNotified: Bool? = nil
    /// Of de pre-flight-check (yt-dlp/toegang/link) 1 dag resp. 1 uur van tevoren
    /// al verstuurd is. Optioneel om dezelfde reden als liveNotified hierboven.
    var dayBeforeCheckNotified: Bool? = nil
    var hourBeforeCheckNotified: Bool? = nil

    var youtubeID: String? { extractYouTubeID(from: url) }

    /// YouTube's predictable thumbnail CDN path — no API call needed, just the video ID.
    var thumbnailURL: URL? {
        guard let id = youtubeID else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

/// Shared with MonitorEngine, which needs the same ID (not tied to a MonitoredVideo)
/// to grep leftover files after a false download failure — see reddenNaFout there.
func extractYouTubeID(from url: String) -> String? {
    for pattern in ["[?&]v=([A-Za-z0-9_-]{6,})", "youtu\\.be/([A-Za-z0-9_-]{6,})",
                    "/live/([A-Za-z0-9_-]{6,})"] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(url.startIndex..., in: url)
        if let m = re.firstMatch(in: url, range: range), let r = Range(m.range(at: 1), in: url) {
            return String(url[r])
        }
    }
    return nil
}

/// Compact "in 6d 3h" / "in 2h 14m" / "in 45m" countdown text — used by the status bar's
/// right-click menu, which (unlike SwiftUI's `Text(_:style:.relative)`) is plain AppKit
/// and doesn't update itself, so it's only built fresh each time the menu is opened.
func formattedCountdown(to date: Date) -> String {
    let interval = date.timeIntervalSinceNow
    if interval <= 0 { return "any moment now" }
    let totalMinutes = Int(interval / 60)
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(minutes)m" }
    return "in \(minutes)m"
}

struct AppSettings: Codable, Equatable {
    /// How many minutes before the scheduled time we start checking.
    var checkLeadMinutes: Double = 15
    /// How often (in minutes) we check once LIVE is already captured and we're waiting for the VOD.
    var vodWaitMinutes: Double = 2
    /// Don't send a failure notification for the same premiere more often than this (in minutes).
    var failureCooldownMinutes: Double = 5
    /// Custom download location; nil = default ~/Downloads/Reprise.
    var customDownloadPath: String? = nil
    /// Pushover credentials, set from within the app's own Settings screen.
    /// nil/empty = fall back to the shared ~/htm-rooster/script/config.env
    /// file (the setup this app originally borrowed its keys from). Once you
    /// set your own here — e.g. after making a new Pushover account — these
    /// take over completely; you're not editing a file shared with an
    /// unrelated project anymore.
    var pushoverToken: String? = nil
    var pushoverUserKey: String? = nil
    /// Below this, the disk-space banner/push fires. nil = the 5GB default.
    /// Optional for the same decoding-safety reason as the video flags in
    /// MonitoredVideo above.
    var lowDiskThresholdGB: Double? = nil
    /// Whether Reprise keeps a permanent Dock icon instead of staying menu-bar-only.
    /// nil/false = the original behavior (accessory app, briefly becomes regular only
    /// while a window is open, for keyboard focus — see StatusItemController).
    var showDockIcon: Bool? = nil
    /// Which browser yt-dlp reads YouTube login cookies from: "chrome", "safari", or
    /// nil/anything else for automatic (Chrome if present, else Safari). Explicit so a Mac
    /// with both installed but only logged into one doesn't get the wrong one guessed —
    /// auto-detection prefers Chrome unconditionally, which is wrong if you're actually
    /// logged into YouTube in Safari.
    var cookieBrowserPreference: String? = nil
}
