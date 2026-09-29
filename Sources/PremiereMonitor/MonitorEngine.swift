import Foundation
import SwiftUI
import AppKit
import IOKit.pwr_mgt
import UserNotifications

@MainActor
final class MonitorEngine: ObservableObject {
    static let shared = MonitorEngine()

    @Published var videos: [MonitoredVideo]
    @Published var logLines: [String] = []
    @Published var downloadProgress: [UUID: String] = [:]
    @Published var settings: AppSettings {
        didSet { Store.saveSettings(settings) }
    }
    /// Active "something's wrong" warnings, shown as a banner at the top of the main
    /// window — originally just missing permissions, now anything that could quietly
    /// wreck a download (e.g. "disk-space"). Keyed by a stable id per check (e.g.
    /// "cookie-access") so a check can add/remove just its own line without touching
    /// anyone else's — meant to grow as more checks get added, not stay a single
    /// hardcoded message. Added 26-09-2026 after a TCC block on Chrome's cookie folder
    /// ran silently for over an hour with nothing but a log line to show for it.
    @Published var permissionWarnings: [String: String] = [:]

    private var loopTask: Task<Void, Never>?

    /// Checks the usual Homebrew locations (Apple Silicon and Intel) plus a couple of
    /// other common install prefixes — was hardcoded to the Apple Silicon Homebrew path
    /// only, which would have silently broken on an Intel Mac using /usr/local instead.
    private static func findExecutable(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          "/opt/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Falls back to the Apple Silicon Homebrew path even when not found, so existing
    /// error paths (which already report a clear "couldn't run yt-dlp" failure) still have
    /// *some* path to try and fail against, rather than an empty string.
    private var ytDlpPath: String {
        MonitorEngine.findExecutable("yt-dlp") ?? "/opt/homebrew/bin/yt-dlp"
    }
    private var ffmpegPath: String? { MonitorEngine.findExecutable("ffmpeg") }
    private var brewPath: String? { MonitorEngine.findExecutable("brew") }

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    var downloadRoot: URL {
        if let custom = settings.customDownloadPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let downloadsBase = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        return downloadsBase.appendingPathComponent("Reprise", isDirectory: true)
    }

    private var checkLeadTime: TimeInterval { settings.checkLeadMinutes * 60 }
    private var vodWaitInterval: TimeInterval { settings.vodWaitMinutes * 60 }
    private var failureNotifyCooldown: TimeInterval { settings.failureCooldownMinutes * 60 }

    init() {
        self.settings = Store.loadSettings()
        self.videos = Store.load()
        log("Reprise started. Download folder: \(downloadRoot.path)")
        checkDownloadFolderWritable()
        checkCookieBrowserAccess()
        checkDiskSpace()
        checkExternalTools()
        for v in videos {
            log("Loaded: [\(v.label)] scheduled \(v.scheduledDate.formatted(date: .abbreviated, time: .standard)), status=\(v.status.displayName)")
        }
        startLoop()          // tick() draait meteen, en checkt daarbinnen ook yt-dlp
    }

    /// Eén keer bij het opstarten, en daarna hooguit één keer per dag.
    ///
    /// Bewust géén "yt-dlp -U": die vlag is niet alleen een check — vindt hij
    /// een nieuwere versie, dan installeert hij die meteen zelf. Op
    /// 19-08-2026 gemeten in de broncode van yt-dlp zelf (update.py): zonder
    /// update volgt de regel "yt-dlp is up to date", mét update volgt "Updating
    /// to ... / Updated yt-dlp to ...". Zo'n zelf-update gaat buiten Homebrew's
    /// boekhouding om, en dat soort uit-de-pas-lopen tussen wat een
    /// pakketbeheerder denkt dat er staat en wat er werkelijk staat kostte op
    /// 19-09-2026 al een hele avond (de Homebrew-verhuizing en de node-
    /// symlink). Bijwerken blijft dus een bewuste `brew upgrade yt-dlp`.
    ///
    /// In plaats daarvan alleen de eigen versie naast GitHub's laatste release
    /// leggen — dat raakt yt-dlp zelf helemaal niet aan.
    private var lastYtDlpVersionCheck: Date?
    /// Result of the last successful version comparison, so the pre-flight check
    /// (sendReadinessCheck) can report on it without hitting GitHub's rate-limited API
    /// again itself — nil means "up to date" or "couldn't tell", never "outdated".
    private var ytDlpOutdatedVersions: (current: String, latest: String)?

    func checkYtDlpVersion() async {
        if let last = lastYtDlpVersionCheck, Date().timeIntervalSince(last) < 86400 { return }
        lastYtDlpVersionCheck = Date()

        let (huidigRC, huidigOut, _) = await runProcess(ytDlpPath, ["--version"])
        let huidig = huidigOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard huidigRC == 0, !huidig.isEmpty else {
            log("⚠️ Could not read yt-dlp's version.")
            return
        }

        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Distinguishes *why* the check failed instead of lumping everything under "unreachable" —
        // a rate limit, a real network outage, and GitHub returning something unexpected all need
        // a different reaction, and "unreachable" was actively misleading on 26-09-2026 when the
        // real cause was an exhausted GitHub API rate limit (60 req/hour, shared by everything on
        // this network) with the network itself working fine.
        let (nieuwste, reden): (String?, String?) = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(returning: (nil, "no network connection (\(error.localizedDescription))"))
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    continuation.resume(returning: (nil, "no response from GitHub"))
                    return
                }
                if http.statusCode == 403, http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                    var reset = "within the hour"
                    if let resetHeader = http.value(forHTTPHeaderField: "x-ratelimit-reset"),
                       let resetEpoch = TimeInterval(resetHeader) {
                        reset = Date(timeIntervalSince1970: resetEpoch).formatted(date: .omitted, time: .shortened)
                    }
                    continuation.resume(returning: (nil, "GitHub's public API rate limit (60 requests/hour, shared by "
                        + "everything on this network) is used up for now — resets \(reset)"))
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    continuation.resume(returning: (nil, "unexpected response from GitHub (HTTP \(http.statusCode))"))
                    return
                }
                continuation.resume(returning: (tag, nil))
            }.resume()
        }

        guard let nieuwste else {
            // Nooit fataal: morgen proberen we het gewoon opnieuw.
            log("· Could not check whether yt-dlp is up to date — \(reden ?? "unknown reason").")
            return
        }

        if nieuwste == huidig {
            log("✅ yt-dlp is up to date (\(huidig)).")
            ytDlpOutdatedVersions = nil
            return
        }
        ytDlpOutdatedVersions = (huidig, nieuwste)
        log("⚠️ yt-dlp is outdated: \(huidig), latest is \(nieuwste). "
           + "YouTube changes often break older versions silently. Run: brew upgrade yt-dlp")
        notify(title: "Reprise — yt-dlp is outdated",
              message: "\(huidig) → \(nieuwste) available. Run in Terminal: brew upgrade yt-dlp")
    }

    /// Actually tests whether we can write to the download folder (macOS protects Downloads
    /// with TCC permission; a silently failing creation would otherwise only surface on the
    /// day itself). Result is logged clearly.
    private func checkDownloadFolderWritable(silent: Bool = false) {
        do {
            try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
            let testFile = downloadRoot.appendingPathComponent(".writetest")
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testFile)
            log("✅ Download folder write test passed — file permissions are fine.")
            permissionWarnings["download-folder"] = nil
        } catch {
            log("❌ WRITE TEST FAILED: cannot write to \(downloadRoot.path) — \(error.localizedDescription). macOS probably needs to grant access to the Downloads folder (System Settings → Privacy & Security → Files and Folders).")
            permissionWarnings["download-folder"] = "Can't write to the download folder — grant access in "
                + "System Settings → Privacy & Security → Files and Folders → Reprise → Downloads Folder, then restart Reprise."
            if !silent {
                notify(title: "Reprise: write problem!", message: "Cannot write to the download folder. Check System Settings → Privacy & Security → Files and Folders.")
            }
        }
    }

    /// Chrome first (best-tested), Safari as a fallback for Macs without Chrome — yt-dlp
    /// supports both via --cookies-from-browser. nil means neither is available, in which
    /// case cookie-gated premieres just won't work; public videos are unaffected either
    /// way. Re-evaluated on every check rather than cached once, so installing Chrome
    /// later while Reprise is already running gets picked up without a restart.
    ///
    /// Added 27-09-2026: this used to be hardcoded to Chrome everywhere, so a Mac with
    /// only Safari installed got a single quiet log line ("Chrome not found") and nothing
    /// else — no banner, no push, and yt-dlp kept getting passed "--cookies-from-browser
    /// chrome" regardless, failing and silently retrying without cookies every single time.
    private enum CookieBrowser {
        case chrome, safari

        var ytdlpName: String {
            switch self {
            case .chrome: return "chrome"
            case .safari: return "safari"
            }
        }

        var displayName: String {
            switch self {
            case .chrome: return "Chrome"
            case .safari: return "Safari"
            }
        }

        /// Just an "is it there at all" probe for our own permission banner — not
        /// necessarily the exact path yt-dlp itself reads cookies from, which it locates
        /// internally per browser.
        var probePath: String {
            switch self {
            case .chrome: return ("~/Library/Application Support/Google/Chrome" as NSString).expandingTildeInPath
            case .safari: return ("~/Library/Cookies" as NSString).expandingTildeInPath
            }
        }
    }

    private var cookieBrowser: CookieBrowser? {
        // An explicit choice in Settings always wins — auto-detection prefers Chrome
        // unconditionally, which is the wrong guess on a Mac that has both installed but
        // is only actually logged into YouTube in Safari.
        switch settings.cookieBrowserPreference {
        case "chrome":
            return FileManager.default.fileExists(atPath: CookieBrowser.chrome.probePath) ? .chrome : nil
        case "safari":
            return FileManager.default.fileExists(atPath: CookieBrowser.safari.probePath) ? .safari : nil
        default:
            if FileManager.default.fileExists(atPath: CookieBrowser.chrome.probePath) { return .chrome }
            if FileManager.default.fileExists(atPath: CookieBrowser.safari.probePath) { return .safari }
            return nil
        }
    }

    /// Tests whether we can actually read the detected browser's cookie data — the same
    /// TCC permission (Full Disk Access) that yt-dlp's --cookies-from-browser needs.
    /// Distinct from testCookies(): this only checks file-level access, not whether
    /// YouTube accepts the login inside. Runs once at startup, same pattern as
    /// checkDownloadFolderWritable() above.
    ///
    /// Added 26-09-2026: without this, a TCC block here was invisible until
    /// someone thought to check the log — it produced no notification at
    /// all (unlike a download failure), so it ran silently, once every
    /// 30 seconds, for over an hour during the Living Colour premiere,
    /// before anyone noticed something was wrong.
    ///
    /// Points people at Full Disk Access rather than the granular "Files and Folders →
    /// Reprise → Google Chrome" toggle: that per-app-target grant is a newer, flakier TCC
    /// category that macOS silently un-toggles for ad-hoc-signed apps (no stable Developer
    /// ID) — confirmed 26-09-2026, toggling it on and then triggering another access
    /// attempt (e.g. this check) made it flip back off by itself. Full Disk Access is the
    /// older, sticky category and doesn't have that problem.
    private func checkCookieBrowserAccess(silent: Bool = false) {
        guard let browser = cookieBrowser else {
            log("· No supported browser (Chrome or Safari) found — cookie-based login won't be available; downloads of public videos still work.")
            return
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: browser.probePath)
            log("✅ Can read \(browser.displayName)'s cookie data — cookie access should work.")
            permissionWarnings["cookie-access"] = nil
        } catch {
            log("❌ CANNOT READ \(browser.displayName)'s cookie data: \(error.localizedDescription). macOS is blocking access.")
            permissionWarnings["cookie-access"] = "Can't read \(browser.displayName)'s cookies — grant access in "
                + "System Settings → Privacy & Security → Full Disk Access → enable Reprise, then restart Reprise. "
                + "Downloads of public videos still work meanwhile."
            if !silent {
                notify(title: "Reprise: \(browser.displayName) access blocked",
                      message: "Cannot read \(browser.displayName)'s cookies — macOS is blocking it. Grant access in "
                             + "System Settings → Privacy & Security → Full Disk Access → enable Reprise, "
                             + "then restart Reprise. Downloads of public videos still work meanwhile.")
            }
        }
    }

    /// Below this, a download is at real risk of running out of space mid-recording —
    /// a typical HD concert recording lands in the multiple-GB range, so leave real
    /// headroom rather than cutting it close.
    private var lowDiskThresholdBytes: Int64 {
        Int64((settings.lowDiskThresholdGB ?? 5) * 1_000_000_000)
    }

    private func freeDiskSpaceBytes() -> Int64? {
        try? FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        let values = try? downloadRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Whether the low-disk-space push has already gone out for the *current* low
    /// spell — reset once space recovers, so a disk that stays full doesn't re-notify
    /// every 30 seconds, but a second, later low spell still gets its own warning.
    private var diskSpaceWarned = false

    /// Same idea as diskSpaceWarned, for checkExternalTools() below — needed now that
    /// it also runs every tick (30s), not just at startup (see 27-09-2026 fix: missing
    /// yt-dlp/ffmpeg was only ever detected once, at launch). Without this it would
    /// re-notify every 30 seconds for as long as the tools stay missing.
    private var externalToolsWarned = false

    /// Checked at startup and every tick (not just once, unlike the folder/Chrome
    /// checks above) since free space genuinely changes over time — other downloads,
    /// other apps, Time Machine locals, all eat into it between one premiere and the
    /// next.
    private func checkDiskSpace(silent: Bool = false) {
        guard let free = freeDiskSpaceBytes() else {
            permissionWarnings["disk-space"] = nil
            return
        }
        let low = free < lowDiskThresholdBytes
        let msg = "Only \(formattedBytes(free)) free on the download disk — a live recording can easily "
            + "need several GB. Free up space before the next premiere."
        permissionWarnings["disk-space"] = low ? msg : nil

        guard low else {
            diskSpaceWarned = false
            return
        }
        guard !diskSpaceWarned else { return }
        diskSpaceWarned = true
        log("❌ LOW DISK SPACE: \(formattedBytes(free)) free at \(downloadRoot.path).")
        if !silent {
            notify(title: "Reprise: low disk space", message: msg)
        }
    }

    /// Without yt-dlp or ffmpeg, Reprise can't download anything at all — more fundamental
    /// even than the Chrome/Safari cookie check, since that only affects login-gated
    /// premieres. Added 27-09-2026: previously undetected until the first real check near
    /// a premiere's scheduled time, which then failed with a raw, cryptic system error
    /// ("Error Domain=NSCocoaErrorDomain Code=4 ...") instead of a clear "install this"
    /// message — exactly the kind of late, unreadable failure every other check here was
    /// already built to avoid.
    private func checkExternalTools(silent: Bool = false) {
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: ytDlpPath) { missing.append("yt-dlp") }
        if ffmpegPath == nil { missing.append("ffmpeg") }

        guard !missing.isEmpty else {
            permissionWarnings["external-tools"] = nil
            externalToolsWarned = false
            return
        }
        let names = missing.joined(separator: " and ")
        let msg = "\(names) not found — Reprise can't download anything without "
            + "\(missing.count > 1 ? "them" : "it"). Install via Homebrew: brew install \(missing.joined(separator: " "))"
        permissionWarnings["external-tools"] = msg

        guard !externalToolsWarned else { return }
        externalToolsWarned = true
        log("❌ \(msg)")
        if !silent {
            notify(title: "Reprise: missing \(names)", message: msg)
        }
    }

    /// Opens Terminal and runs `brew install <missing tools>` directly, so fixing this
    /// doesn't require leaving the app to go figure out the right command. Deliberately
    /// visible in a real Terminal window rather than run invisibly inside Reprise — this
    /// installs system software via Homebrew, and that's worth seeing happen for real
    /// rather than trusting a black box.
    func installMissingTools() {
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: ytDlpPath) { missing.append("yt-dlp") }
        if ffmpegPath == nil { missing.append("ffmpeg") }
        guard !missing.isEmpty else { return }

        guard let brew = brewPath else {
            log("⚠️ Homebrew itself isn't installed — install it first from https://brew.sh, then try again.")
            notify(title: "Reprise: Homebrew not found",
                  message: "Install Homebrew first from https://brew.sh, then use \"Install via Homebrew\" again.")
            return
        }

        let command = "\(brew) install \(missing.joined(separator: " "))"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        log("Opening Terminal to run: \(command)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// Re-runs the startup checks on demand (the "Check again" button in
    /// PermissionGateView), without re-sending push notifications for a state the
    /// user already knows about — they just clicked the button because of it.
    func recheckPermissions() {
        checkDownloadFolderWritable(silent: true)
        checkCookieBrowserAccess(silent: true)
        checkDiskSpace(silent: true)
        checkExternalTools(silent: true)
    }

    /// Your own Pushover credentials from Settings, if you've set them.
    private var pushoverOverride: (token: String?, userKey: String?) {
        (settings.pushoverToken, settings.pushoverUserKey)
    }

    /// Sends both a Pushover push (for when you're away from this Mac) and a local
    /// banner on this Mac itself (for when you're sitting right here and don't want to
    /// depend on your phone being nearby/charged/in range). Single funnel for every
    /// notification in the app, so both channels stay in sync without each call site
    /// needing to remember to do both.
    func notify(title: String, message: String) {
        Notifier.send(title: title, message: message, override: pushoverOverride) { [weak self] ok, detail in
            Task { @MainActor in
                self?.log(ok ? "Pushover: \(message)" : "Pushover failed: \(detail)")
            }
        }
        sendLocalNotification(title: title, message: message)
    }

    private func sendLocalNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.log("⚠️ Could not show local notification: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a real test Pushover notification and reports success/failure directly,
    /// so you can verify it works without waiting for a real event.
    func sendTestNotification(completion: @escaping (Bool, String) -> Void) {
        Notifier.send(title: "Reprise test", message: "If you see this, Pushover notifications are working.",
                     override: pushoverOverride) { [weak self] ok, detail in
            Task { @MainActor in
                self?.log(ok ? "Test notification sent successfully." : "Test notification failed: \(detail)")
                completion(ok, detail)
            }
        }
    }

    /// Tests whether yt-dlp can actually read the detected browser's YouTube login
    /// cookies right now, using one of the tracked premieres (or a known-stable channel)
    /// as the target.
    func testCookies() async -> (ok: Bool, message: String) {
        let testUrl = videos.first?.url ?? "https://www.youtube.com/@LofiGirl/live"
        let browserName = cookieBrowser?.displayName ?? "your browser"

        // Bewust níet via fetchMeta: die valt bij geweigerde cookies terug op
        // een poging zónder, en dan zou deze test "cookies werken" melden
        // terwijl ze juist stuk zijn. Hier willen we het eerlijke antwoord.
        let (rc, out, err) = await runProcess(ytDlpPath, metaArgs(url: testUrl, metCookies: true))
        if rc == 0, !out.isEmpty {
            cookiesGeweigerd = false          // usable again after a fresh login
            log("Cookie test passed — YouTube accepts your \(browserName) login.")
            return (true, "Success — YouTube accepts your \(browserName) login.")
        }
        cookiesGeweigerd = true
        let detail = tail(err)
        log("Cookie test FAILED (rc=\(rc)): \(detail)")
        if cookieFoutmelding(err) {
            return (false, "YouTube is rejecting your \(browserName) cookies. Log in again using the button "
                        + "next to this one. Downloads of public videos keep working without cookies.")
        }
        return (false, "Failed: \(detail.isEmpty ? "could not fetch YouTube data." : detail)")
    }

    /// Opens YouTube in whichever browser Reprise is reading cookies from, so you can log
    /// in there again — the only real fix for rejected cookies, since yt-dlp reads them
    /// from that browser's own profile, so a valid login needs to live there.
    func openYouTubeLogin() {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let youtube = URL(string: "https://www.youtube.com/account")!
        if FileManager.default.fileExists(atPath: chrome.path) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([youtube], withApplicationAt: chrome, configuration: config)
            log("Opened Chrome on YouTube — log in there, then run the cookie test again.")
        } else {
            NSWorkspace.shared.open(youtube)
            let browserName = cookieBrowser?.displayName ?? "your browser"
            log("Opened YouTube in your default browser. Note: yt-dlp reads cookies from "
                + "\(browserName), so log in there, then run the cookie test again.")
        }
    }

    func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(msg)"
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        Store.appendLog(line)
    }

    /// Adds a premiere. Returns false (and adds nothing) if the URL is already in the list.
    @discardableResult
    func addVideo(url: String, label: String, scheduledDate: Date) -> Bool {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if videos.contains(where: { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedUrl }) {
            log("Not added (already in the list): \(trimmedUrl)")
            return false
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = MonitoredVideo(url: trimmedUrl, label: trimmedLabel.isEmpty ? trimmedUrl : trimmedLabel, scheduledDate: scheduledDate)
        videos.append(v)
        Store.save(videos)
        log("Added: \(v.label)")
        return true
    }

    func removeVideo(_ video: MonitoredVideo) {
        videos.removeAll { $0.id == video.id }
        Store.save(videos)
        log("Removed: \(video.label)")
    }

    /// Clears finished premieres from the tracked list. Only the list entry goes —
    /// downloaded files on disk are never touched by this.
    func clearCompleted() {
        let removed = videos.filter { $0.status == .done }.count
        guard removed > 0 else { return }
        videos.removeAll { $0.status == .done }
        Store.save(videos)
        log("Cleared \(removed) completed premiere(s) from the list.")
    }

    /// Updates an existing premiere's URL/label/scheduled time. Returns false (and changes
    /// nothing) if the new URL matches a *different* premiere already in the list.
    @discardableResult
    func updateVideo(id: UUID, url: String, label: String, scheduledDate: Date) -> Bool {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return false }
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if videos.contains(where: { $0.id != id && $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedUrl }) {
            log("Not updated (URL already used by another premiere): \(trimmedUrl)")
            return false
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var v = videos[index]

        // Without these resets: (1) editing a "Done" premiere's URL to point at a different
        // video left it stuck showing "Done" forever — checkOneVideo's very first line
        // returns immediately once vodDone is true, so the new URL was never actually
        // checked. (2) rescheduling a premiere (common on YouTube) after its day-before
        // pre-flight push had already fired meant that push could never fire again for the
        // new date. Both found 26-09-2026.
        let urlChanged = v.url.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedUrl
        let dateChanged = v.scheduledDate != scheduledDate

        v.url = trimmedUrl
        v.label = trimmedLabel.isEmpty ? trimmedUrl : trimmedLabel
        v.scheduledDate = scheduledDate

        if urlChanged {
            // A different video entirely: none of the old tracking state still applies.
            v.status = .waiting
            v.liveDone = false
            v.vodDone = false
            v.finalFilePath = nil
            v.liveNotified = nil
            v.retryNotBefore = nil
            v.stillWaitingNotified = nil
            v.dayBeforeCheckNotified = nil
            v.hourBeforeCheckNotified = nil
        } else if dateChanged {
            // Same video, new time: let the pre-flight pushes fire again for the new date.
            v.dayBeforeCheckNotified = nil
            v.hourBeforeCheckNotified = nil
        }

        videos[index] = v
        Store.save(videos)
        log("Updated: \(v.label)" + (urlChanged ? " (URL changed — tracking state reset)" : "")
            + (dateChanged ? " (rescheduled — pre-flight checks will fire again)" : ""))
        return true
    }

    /// Forces an immediate check for this premiere, regardless of the check window.
    func checkNow(_ video: MonitoredVideo) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
        log("[\(video.label)] Manual check started...")
        Task {
            await self.checkOneVideo(index: index, forceCheck: true)
            Store.save(self.videos)
        }
    }

    /// Runs the same yt-dlp/access/disk-space/link check as the automatic 24h/1h
    /// pre-flight push, on demand — doesn't touch dayBeforeCheckNotified /
    /// hourBeforeCheckNotified, so using this never skips or delays the automatic ones.
    func runPreflightCheckNow(_ video: MonitoredVideo) {
        log("[\(video.label)] Manual pre-flight check started...")
        Task {
            await self.sendReadinessCheck(for: video, milestone: "manual check")
        }
    }

    func openDownloadFolder() {
        try? FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadRoot)
    }

    func revealFile(_ video: MonitoredVideo) {
        if let path = video.finalFilePath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: downloadRoot.path)
        } else {
            openDownloadFolder()
        }
    }

    private func startLoop() {
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    // MARK: - Process helpers

    private func runProcess(_ path: String, _ args: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "", "\(error)"))
                return
            }
            // Eerst leegdrinken, dán pas wachten. Andersom loopt het vast: een
            // pijp houdt ongeveer 64 kB vast, en zolang niemand leest blijft
            // yt-dlp hangen op schrijven — terwijl waitUntilExit() wacht tot
            // yt-dlp stopt. Beide wachten dan op elkaar.
            //
            // Dat gebeurde op 19-09-2026 en het verklaart waarom het jarenlang
            // leek te werken: bij een lopende uitzending is de metadata klein
            // genoeg, maar zodra dezelfde video een VOD wordt staat de hele
            // formatlijst erin — 636 kB, dus ruim tien keer de buffer. Elke
            // VOD-controle liep daarop vast, zonder foutmelding.
            var outData = Data()
            var errData = Data()
            let leesGroep = DispatchGroup()
            leesGroep.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                leesGroep.leave()
            }
            leesGroep.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                leesGroep.leave()
            }
            process.waitUntilExit()
            leesGroep.wait()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""
            continuation.resume(returning: (process.terminationStatus, out, err))
        }
    }

    /// Runs a download command and reads stdout line by line, so we can show progress
    /// (yt-dlp's "[download]  NN.N% ..." lines) and capture the final file path.
    private func runDownloadProcess(_ path: String, _ args: [String], videoId: UUID) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var stdoutBuffer = ""
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                stdoutBuffer += chunk
                while let range = stdoutBuffer.range(of: "\n") {
                    let line = String(stdoutBuffer[stdoutBuffer.startIndex..<range.lowerBound])
                    stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
                    Task { @MainActor in
                        self?.processDownloadLine(line, videoId: videoId)
                    }
                }
            }

            var stderrData = Data()
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrData.append(data) }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, err))
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (-1, "\(error)"))
            }
        }
    }

    private var lastCapturedFilePath: [UUID: String] = [:]

    /// De fragmentstand uit een yt-dlp-regel, als tekst om te tonen.
    ///
    /// Gemeten op 19-09-2026 met precies de vlaggen die dit script gebruikt;
    /// een regel ziet er zo uit:
    ///   [download]   0.4% of ~  13.01MiB at   29.67KiB/s ETA Unknown (frag 1/588)
    /// Bij een lopende uitzending ontbreekt het totaal en staat er "(frag 942)".
    private func fragmentStand(_ line: String) -> String? {
        for (patroon, metTotaal) in [("\\(frag (\\d+)/(\\d+)\\)", true),
                                     ("\\(frag (\\d+)\\)", false),
                                     ("fragment (\\d+)", false)] {
            guard let re = try? NSRegularExpression(pattern: patroon, options: [.caseInsensitive]) else { continue }
            let bereik = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: bereik),
                  let r1 = Range(m.range(at: 1), in: line) else { continue }
            if metTotaal, m.numberOfRanges > 2, let r2 = Range(m.range(at: 2), in: line) {
                return "fragment \(line[r1]) of \(line[r2])"
            }
            return "fragment \(line[r1])"
        }
        return nil
    }

    /// Draaiend streepje, zodat je aan de beweging ziet dat er nog iets gebeurt.
    private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerTick: [UUID: Int] = [:]

    private func draaiend(_ videoId: UUID) -> String {
        let tick = (spinnerTick[videoId] ?? 0) + 1
        spinnerTick[videoId] = tick
        return spinnerFrames[tick % spinnerFrames.count]
    }

    /// Het percentage plus totaalgrootte uit een downloadregel.
    ///
    /// Alleen bruikbaar als de grootte vaststaat. Bij fragmenten schat yt-dlp
    /// het totaal en springt het percentage alle kanten op — gemeten: 100%,
    /// 0.5%, 0.4%, 0.2% achter elkaar. Dat is geen voortgang om te tonen;
    /// daar is de fragmentteller voor. Staat er "of ~" (een schatting), dan
    /// slaan we het dus over.
    private func percentage(_ regel: String) -> String? {
        guard !regel.contains("of ~"), let re = try? NSRegularExpression(
            pattern: "(\\d{1,3}\\.\\d)%\\s+of\\s+([\\d.]+\\s*[KMG]i?B)") else { return nil }
        let bereik = NSRange(regel.startIndex..., in: regel)
        guard let m = re.firstMatch(in: regel, range: bereik),
              let pct = Range(m.range(at: 1), in: regel),
              let totaal = Range(m.range(at: 2), in: regel) else { return nil }
        return "\(regel[pct])% of \(regel[totaal])"
    }

    /// Een afgelopen live-uitzending laat yt-dlp afsluiten met een foutcode —
    /// "Did not get any data blocks" — terwijl de opname gewoon compleet op
    /// schijf staat. Op 19-09-2026 gebeurde precies dat: 1,8 GB beeld en 60 MB
    /// geluid, allebei 3811 seconden, en toch een melding "download failed"
    /// plus geen samengevoegd bestand.
    ///
    /// Vandaar: na een foutcode eerst kijken wat er écht ligt. Is het er, dan
    /// is het geslaagd; liggen beeld en geluid nog los, dan voegen we ze hier
    /// alsnog samen. Geeft het uiteindelijke pad terug, of nil als er niets
    /// bruikbaars staat.
    private func reddenNaFout(url: String, tag: String, label: String) -> String? {
        guard let vid = extractYouTubeID(from: url) else { return nil }
        let fm = FileManager.default
        guard let alles = try? fm.contentsOfDirectory(atPath: downloadRoot.path) else { return nil }

        // Bewust niet filteren op .mkv of op vaste formaatnummers: yt-dlp kiest
        // per video wat het beste past. De live-opname van 19-09-2026 kwam
        // binnen als .f137.mkv + .f140.mkv, maar dezelfde video als VOD werd
        // .f137.mp4 + .f251.webm. Filteren op ".mkv" of op ".f14" had die dus
        // gemist — en juist die moest gered worden.
        let mediaExt = ["mkv", "mp4", "webm", "m4a"]
        let pad = { (naam: String) in self.downloadRoot.appendingPathComponent(naam).path }
        let grootte = { (naam: String) -> Int64 in
            ((try? fm.attributesOfItem(atPath: pad(naam)))?[.size] as? Int64) ?? 0
        }
        let vanDitItem = alles.filter {
            $0.contains(vid) && $0.contains("[\(tag)]")
                && mediaExt.contains(($0 as NSString).pathExtension.lowercased())
                && grootte($0) > 5_000_000          // halve downloads tellen niet mee
        }

        // Een losse track heet "… .f137.mp4"; zonder dat stuk is het al
        // samengevoegd en zijn we klaar.
        let isLosseTrack = { (naam: String) in
            naam.range(of: "\\.f\\d+\\.[a-z0-9]+$", options: .regularExpression) != nil
        }
        if let klaar = vanDitItem.first(where: { !isLosseTrack($0) }) {
            log("[\(label)] Stream ended, but the file is fully there.")
            return pad(klaar)
        }

        // Beeld en geluid uit elkaar houden op grootte in plaats van op
        // formaatnummer: het beeldspoor is altijd vele malen groter.
        let tracks = vanDitItem.filter(isLosseTrack).sorted { grootte($0) > grootte($1) }
        guard tracks.count >= 2, let v = tracks.first, let a = tracks.last, v != a else { return nil }

        // "… [LIVE].f137.mp4" → "… [LIVE].mkv": mkv slikt elke combinatie.
        let doelNaam = v.replacingOccurrences(of: "\\.f\\d+\\.[a-z0-9]+$", with: ".mkv",
                                              options: .regularExpression)
        let doel = pad(doelNaam)
        log("[\(label)] Stream ended before merging — merging video and audio myself…")
        guard let ffmpeg = ffmpegPath else {
            log("[\(label)] No ffmpeg found — video and audio remain as separate files.")
            return nil
        }
        let proces = Process()
        proces.executableURL = URL(fileURLWithPath: ffmpeg)
        proces.arguments = ["-v", "error", "-y", "-i", pad(v), "-i", pad(a),
                            "-c", "copy", "-map", "0:v:0", "-map", "1:a:0", doel]
        do {
            try proces.run()
            proces.waitUntilExit()
        } catch {
            log("[\(label)] Merge failed: \(error.localizedDescription)")
            return nil
        }
        guard proces.terminationStatus == 0, fm.fileExists(atPath: doel) else {
            log("[\(label)] Merge failed (ffmpeg exited \(proces.terminationStatus)).")
            return nil
        }
        log("[\(label)] Merged → \(doel)")
        return doel
    }

    /// Wanneer we voor het laatst een voortgangsregel in het log zetten.
    private var laatsteVoortgangLog: [UUID: Date] = [:]

    /// yt-dlp's eigen uitvoer in het log, zoals je het in een terminal zou
    /// zien. Voortgangsregels worden afgeremd: met --newline komt er per
    /// update een regel binnen, en ongefilterd zou dat het log (500 regels in
    /// beeld, en alles gaat ook naar schijf) binnen een minuut vullen met
    /// louter percentages. Fases en fouten gaan er wél meteen in, want dat is
    /// precies wat je wilt kunnen terugzoeken.
    private func echoNaarLog(_ regel: String, videoId: UUID, isVoortgang: Bool) {
        if isVoortgang {
            let nu = Date()
            if let vorige = laatsteVoortgangLog[videoId], nu.timeIntervalSince(vorige) < 3 { return }
            laatsteVoortgangLog[videoId] = nu
        }
        log(regel)
    }

    private func processDownloadLine(_ line: String, videoId: UUID) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("[") {
            echoNaarLog(trimmed, videoId: videoId, isVoortgang: trimmed.hasPrefix("[download]"))
        }
        // Na het downloaden komt het samenvoegen van het aparte beeld- en
        // geluidsspoor, en daarna soms nog een reparatieslag. Dat kan bij een
        // bestand van twee gigabyte een paar minuten duren, en tot 19-09-2026
        // liet de app in die tijd niets zien — dan lijkt hij vastgelopen
        // terwijl hij gewoon staat te werken.
        if trimmed.hasPrefix("[Merger]") {
            downloadProgress[videoId] = "\(draaiend(videoId)) merging video and audio…"
        } else if trimmed.hasPrefix("[Fixup") {
            downloadProgress[videoId] = "\(draaiend(videoId)) repairing file…"
        } else if trimmed.hasPrefix("[ffmpeg]") || trimmed.hasPrefix("[VideoRemuxer]") {
            downloadProgress[videoId] = "\(draaiend(videoId)) post-processing…"
        } else if trimmed.hasPrefix("[download]") {
            let cleaned = trimmed.replacingOccurrences(of: "[download]", with: "")
                .trimmingCharacters(in: .whitespaces)

            // Bij een lopende uitzending is de totale lengte nog onbekend, dus
            // yt-dlp meldt geen zinnig percentage — het bleef op 0% staan,
            // wat eruitziet alsof er niets gebeurt terwijl er 3 MB/s
            // binnenkwam. Het fragmentnummer zegt dan wél iets. Bij een VOD is
            // de lengte wél bekend en is het percentage juist de beste maat.
            if let frag = fragmentStand(trimmed) {
                downloadProgress[videoId] = "\(draaiend(videoId)) \(frag)"
            } else if let pct = percentage(cleaned) {
                downloadProgress[videoId] = "\(draaiend(videoId)) \(pct)"
            } else {
                downloadProgress[videoId] = "\(draaiend(videoId)) working…"
            }
        } else if !trimmed.hasPrefix("[") && !trimmed.hasPrefix("ERROR") && !trimmed.hasPrefix("WARNING") {
            // This is presumably the --print after_move:filepath line.
            lastCapturedFilePath[videoId] = trimmed
        }
    }

    // MARK: - URL lookup for the add screen

    struct VideoLookupResult {
        var title: String?
        var scheduledDate: Date?
        var isLiveNow: Bool
        var errorMessage: String?
    }

    func lookupVideoInfo(url: String) async -> VideoLookupResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VideoLookupResult(title: nil, scheduledDate: nil, isLiveNow: false, errorMessage: "No URL entered.")
        }
        let result = await fetchMeta(url: trimmed)
        guard let meta = result.meta else {
            let detail = tail(result.stderr)
            let msg = detail.isEmpty
                ? "Could not fetch information for this URL."
                : "Could not fetch information: \(detail)"
            return VideoLookupResult(title: nil, scheduledDate: nil, isLiveNow: false, errorMessage: msg)
        }
        let title = meta["title"] as? String
        let liveStatus = meta["live_status"] as? String
        let isLive = liveStatus == "is_live"

        var scheduledDate: Date?
        if let releaseTs = meta["release_timestamp"] as? Double {
            scheduledDate = Date(timeIntervalSince1970: releaseTs)
        } else if let releaseTsInt = meta["release_timestamp"] as? Int {
            scheduledDate = Date(timeIntervalSince1970: Double(releaseTsInt))
        }

        var errorMessage: String?
        if scheduledDate == nil && !isLive {
            errorMessage = "No scheduled premiere time found — enter it manually."
        }

        return VideoLookupResult(title: title, scheduledDate: scheduledDate, isLiveNow: isLive, errorMessage: errorMessage)
    }

    // MARK: - yt-dlp logic (ported from the Python script)

    struct FetchMetaResult {
        var meta: [String: Any]?
        var exitCode: Int32
        var stderr: String
    }

    /// Foutmeldingen waarbij het aan de meegestuurde cookies ligt en niet aan
    /// de video zelf. "The page needs to be reloaded" is wat YouTube teruggeeft
    /// op een sessie die het niet vertrouwt.
    ///
    /// "could not find chrome cookies database" hoort hier ook bij, ook al is
    /// de oorzaak anders (macOS TCC blokkeert de toegang tot Chrome's profiel,
    /// i.p.v. een door YouTube geweigerde sessie). Op 26-09-2026 ontbrak deze
    /// regel: elke poging crashte op een onherkende fout, een vol uur lang bij
    /// elke aanroep opnieuw, zonder ooit de zonder-cookies-fallback te
    /// proberen — exact het scenario waar deze functie voor bedoeld is.
    private func cookieFoutmelding(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("page needs to be reloaded")
            || s.contains("sign in to confirm")
            || s.contains("could not copy chrome cookie")
            || s.contains("could not find chrome cookies database")
            || s.contains("no video formats found")
    }

    private func metaArgs(url: String, metCookies: Bool) -> [String] {
        var args = [
            "--force-ipv4", "--no-warnings", "--skip-download", "--dump-single-json",
            "--ignore-no-formats-error",
            "--user-agent", userAgent,
        ]
        if metCookies, let browser = cookieBrowser { args += ["--cookies-from-browser", browser.ytdlpName] }
        args.append(url)
        return args
    }

    /// Zodra YouTube de Chrome-cookies één keer heeft geweigerd, blijven we ze
    /// niet bij elke aanroep opnieuw aanbieden: dat kost een mislukte poging
    /// van een paar seconden vóór élke download. Juist bij het begin van een
    /// live-uitzending wil je die seconden niet kwijt. Bij een herstart
    /// proberen we het weer, want een verse login lost het op.
    private var cookiesGeweigerd = false

    private func fetchMeta(url: String) async -> FetchMetaResult {
        var (rc, out, err) = await runProcess(ytDlpPath, metaArgs(url: url, metCookies: !cookiesGeweigerd))

        // Bedorven Chrome-cookies zijn erger dan geen cookies: YouTube wijst het
        // verzoek dan af met "The page needs to be reloaded", terwijl dezelfde
        // video anoniem gewoon op te halen is. Gemeten op 19-09-2026 — élke
        // video faalde mét cookies en slaagde zonder, ook een willekeurige
        // andere. Cookies blijven de eerste keus (nodig voor besloten of
        // leeftijdsbeperkte video's), maar ze mogen niet de enige zijn.
        if rc != 0, cookieFoutmelding(err) {
            if !cookiesGeweigerd {
                log("Chrome cookies were rejected by YouTube — proceeding without cookies from now on.")
                cookiesGeweigerd = true
            }
            (rc, out, err) = await runProcess(ytDlpPath, metaArgs(url: url, metCookies: false))
        }

        guard rc == 0, let data = out.data(using: .utf8) else {
            return FetchMetaResult(meta: nil, exitCode: rc, stderr: err)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FetchMetaResult(meta: nil, exitCode: rc, stderr: "Could not parse yt-dlp output as JSON.")
        }
        if let entries = json["entries"] as? [[String: Any]], let first = entries.first {
            return FetchMetaResult(meta: first, exitCode: rc, stderr: "")
        }
        return FetchMetaResult(meta: json, exitCode: rc, stderr: "")
    }

    /// Last N lines of a (possibly multi-line) error message, for readable logs.
    private func tail(_ text: String, lines: Int = 8) -> String {
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let last = allLines.suffix(lines)
        return last.joined(separator: " | ")
    }

    private func desiredPhase(meta: [String: Any]?, scheduled: Date) -> String? {
        guard let meta = meta else { return nil }
        let availability = (meta["availability"] as? String ?? "").lowercased()
        if ["private", "needs_auth", "premium_only"].contains(availability) { return nil }

        let liveStatus = meta["live_status"] as? String
        let hasFormats = !((meta["formats"] as? [Any])?.isEmpty ?? true)

        if liveStatus == "is_live" { return "live" }
        if let liveStatus, ["was_live", "not_live"].contains(liveStatus), Date() >= scheduled, hasFormats {
            return "vod"
        }
        if let releaseTs = meta["release_timestamp"] as? Double {
            let releaseDate = Date(timeIntervalSince1970: releaseTs)
            if releaseDate <= Date() { return "vod" }
        }
        return nil
    }

    /// One IOPM "no idle sleep" assertion shared across however many downloads are
    /// active at once, so an unattended Mac doesn't sleep mid-recording and silently
    /// cut a live capture short — reference-counted so it only releases once every
    /// concurrent download has finished, not after the first one.
    private var sleepAssertionID: IOPMAssertionID = 0
    private var sleepAssertionActive = false
    private var activeDownloadCount = 0

    private func preventSleepIfNeeded() {
        activeDownloadCount += 1
        guard !sleepAssertionActive else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Reprise is recording a live premiere" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = id
            sleepAssertionActive = true
            log("Preventing sleep while downloading.")
        } else {
            log("⚠️ Could not prevent sleep during download (IOPMAssertionCreateWithName failed, code \(result)).")
        }
    }

    private func allowSleepIfIdle() {
        activeDownloadCount = max(0, activeDownloadCount - 1)
        guard activeDownloadCount == 0, sleepAssertionActive else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionActive = false
        log("Download(s) finished — no longer preventing sleep.")
    }

    private func downloadVideo(url: String, label: String, tag: String, isLive: Bool, videoId: UUID) async -> (ok: Bool, path: String?) {
        preventSleepIfNeeded()
        defer { allowSleepIfIdle() }

        // "2026-09-19 — Title [LIVE] (videoID).ext" instead of
        // "20260919 - Title - videoID [LIVE].ext": a readable date, and the
        // video ID tucked away at the end in parens instead of jammed into
        // the middle of the title with dashes on both sides. The ID still has
        // to appear somewhere in the name — reddenNaFout() greps for it to
        // salvage a stream that ended before the merge — but where it sits is
        // free, so it doesn't need to clutter the part you actually read.
        let outTemplate = downloadRoot.appendingPathComponent(
            "%(upload_date>%Y-%m-%d)s — %(title)s [\(tag)] (%(id)s).%(ext)s").path
        var args = [
            "--force-ipv4",
            "-S", "codec:h264,res",
            "-f", "bv*[vcodec^=avc1]+ba/b",
            "--merge-output-format", "mkv",
            "--no-warnings",
            "--no-overwrites",
            "--retries", "10",
            "--retry-sleep", "linear=3:60",
            "--concurrent-fragments", "3",
            // --no-call-home stond hier tot 19-09-2026. Die vlag bestaat niet
            // meer; yt-dlp waarschuwde er bij elke aanroep over en zal hem
            // later als fout behandelen.
            "--newline",
            // --print zet yt-dlp stilletjes in quiet-modus, en daarmee
            // verdwijnen de voortgangsregels volledig. Dát is de reden dat de
            // app altijd "0%" toonde: er kwam niets binnen om te lezen, niet
            // omdat er niets gebeurde. --progress dwingt ze alsnog af.
            "--progress",
            // Zonder deze vlag vervangt yt-dlp standaard tekens als "|" en ":" door
            // fullwidth Unicode-lookalikes (｜, ：) om Windows-compatibel te blijven,
            // ook op macOS — waar een gewone "|" gewoon toegestaan is. Dat gaf
            // bestandsnamen met rare tekens terwijl het origineel prima kon.
            "--no-windows-filenames",
            "--print", "after_move:%(filepath)s",
            "-o", outTemplate
        ]
        let browser = cookieBrowser
        if !cookiesGeweigerd, let browser {
            args += ["--cookies-from-browser", browser.ytdlpName]
        }
        if isLive {
            args += ["--live-from-start", "--hls-use-mpegts", "--hls-prefer-ffmpeg"]
        }
        args.append(url)

        log("[\(label)] Starting download (\(tag))")
        downloadProgress[videoId] = "0%"
        lastCapturedFilePath[videoId] = nil
        var (rc, err) = await runDownloadProcess(ytDlpPath, args, videoId: videoId)

        // Zelfde verhaal als bij het ophalen van de gegevens: wijst YouTube de
        // cookies af, dan is het anoniem vaak gewoon op te halen.
        if rc != 0, cookieFoutmelding(err), !cookiesGeweigerd {
            log("[\(label)] Cookies rejected — proceeding without cookies from now on.")
            cookiesGeweigerd = true
            let zonder = args.filter { $0 != "--cookies-from-browser" && $0 != browser?.ytdlpName }
            (rc, err) = await runDownloadProcess(ytDlpPath, zonder, videoId: videoId)
        }
        downloadProgress[videoId] = nil
        let capturedPath = lastCapturedFilePath[videoId]
        lastCapturedFilePath[videoId] = nil

        if rc == 0 {
            log("[\(label)] Download complete (\(tag)) → \(capturedPath ?? outTemplate)")
            return (true, capturedPath)
        }

        // Foutcode is hier geen eindoordeel: zie reddenNaFout. Eerst kijken wat
        // er op schijf staat, dan pas iemand wakker maken.
        if let gered = reddenNaFout(url: url, tag: tag, label: label) {
            log("[\(label)] Done despite the error code (\(tag)) → \(gered)")
            return (true, gered)
        }

        log("[\(label)] Download failed (\(tag), rc=\(rc)): \(tail(err, lines: 12))")
        return (false, nil)
    }

    /// Which videos already logged a "check window started" line (not persisted).
    private var loggedWindowStart: Set<UUID> = []

    /// Last time each video was checked while waiting for the VOD (not persisted).
    private var lastVodCheck: [UUID: Date] = [:]

    /// How long past the scheduled time we keep checking every 30 seconds
    /// before assuming something's off and backing way down.
    private let stillWaitingThreshold: TimeInterval = 3 * 24 * 3600
    /// The check interval once we've backed off.
    private let stalledCheckInterval: TimeInterval = 30 * 60
    private var lastStalledCheck: [UUID: Date] = [:]

    /// Last time a failure notification was sent per video (not persisted).
    private var lastFailureNotify: [UUID: Date] = [:]

    private func notifyFailureThrottled(videoId: UUID, title: String, message: String) {
        let last = lastFailureNotify[videoId]
        if last == nil || Date().timeIntervalSince(last!) > failureNotifyCooldown {
            lastFailureNotify[videoId] = Date()
            notify(title: title, message: message)
        } else {
            log("(notification suppressed, already reported recently: \(title))")
        }
    }

    /// Videos currently mid-check, so "Check Now" and the automatic 30-second
    /// loop can never both be running for the same video at once. Without
    /// this, clicking Check Now at the wrong moment could start a second
    /// yt-dlp download in parallel with the automatic one — and if both reach
    /// the merge step, two ffmpeg processes writing the same output file at
    /// the same time.
    private var checkingNow: Set<UUID> = []

    /// Writes a mutated copy back by id, not by a possibly-stale index. checkOneVideo and
    /// checkReadinessMilestones both hold `index` across long `await` points (a live
    /// capture can take hours) — if something else (e.g. deleting a different premiere)
    /// changes `videos` in the meantime, that captured index can point past the end of the
    /// array or at an entirely different row. Looking the row up fresh by id means a late
    /// write either lands on the right row or silently no-ops if the row is gone, instead
    /// of crashing or overwriting an unrelated premiere's data. Confirmed reachable
    /// 26-09-2026: the row's trash button isn't disabled during an active download.
    private func writeBack(_ v: MonitoredVideo, id: UUID) {
        guard let idx = videos.firstIndex(where: { $0.id == id }) else { return }
        videos[idx] = v
    }

    private func checkOneVideo(index: Int, forceCheck: Bool = false) async {
        guard videos.indices.contains(index) else { return }
        let videoId = videos[index].id
        guard !checkingNow.contains(videoId) else {
            log("[\(videos[index].label)] Already checking this one — skipped a second, overlapping check.")
            return
        }
        checkingNow.insert(videoId)
        defer { checkingNow.remove(videoId) }

        var v = videos[index]
        // De VOD alleen is genoeg om klaar te zijn. Eerst moesten liveDone én
        // vodDone waar zijn, maar dat loopt vast zodra de live-opname als
        // mislukt is weggeschreven: er valt dan niets meer te downloaden, de
        // laatste tak zet de status terug op "wachten", en hij blijft tot in
        // de eeuwigheid elke 35 seconden de metadata ophalen. Precies dat
        // gebeurde op 19-09-2026.
        //
        // Inhoudelijk is de VOD ook de volledige versie; de live-opname is het
        // vangnet voor als er nooit een VOD komt.
        if v.vodDone {
            if v.status != .done { v.status = .done; writeBack(v, id: videoId) }
            return
        }

        if !forceCheck {
            // Before the window around the scheduled time: don't check anything at all.
            if !v.liveDone {
                let checkFrom = v.scheduledDate.addingTimeInterval(-checkLeadTime)
                if Date() < checkFrom {
                    if v.status != .waiting { v.status = .waiting; writeBack(v, id: videoId) }
                    return
                }
            }

            // A premiere that never goes live had no upper bound here before:
            // once the window opened, this ran every 30 seconds forever. A
            // postponed or cancelled premiere would get checked, unattended,
            // for days or weeks straight — needless battery/CPU use, and
            // exactly the kind of relentless automated traffic that gets an
            // IP flagged by YouTube's bot detection over time. Rather than
            // silently give up (which would miss a premiere that really is
            // just late), slow way down instead: one heads-up notification,
            // then a check every 30 minutes instead of every 30 seconds.
            if !v.liveDone && Date().timeIntervalSince(v.scheduledDate) > stillWaitingThreshold {
                if v.stillWaitingNotified != true {
                    v.stillWaitingNotified = true
                    writeBack(v, id: videoId)
                    log("[\(v.label)] Still not live \(Int(stillWaitingThreshold / 86400)) days after the "
                       + "scheduled time — slowing down to a check every 30 minutes instead of every 30 seconds.")
                    notify(title: "\(v.label) — still not live",
                          message: "It's been a few days past the scheduled time with no sign of it. "
                                 + "Still watching, just far less often now.")
                }
                let last = lastStalledCheck[v.id]
                if let last, Date().timeIntervalSince(last) < stalledCheckInterval {
                    return
                }
                lastStalledCheck[v.id] = Date()
            }

            // Once LIVE is already captured and we're only waiting for the VOD: check less often.
            if v.liveDone && !v.vodDone {
                let last = lastVodCheck[v.id]
                if let last, Date().timeIntervalSince(last) < vodWaitInterval {
                    return
                }
                lastVodCheck[v.id] = Date()
            }
        }

        if !loggedWindowStart.contains(v.id) {
            loggedWindowStart.insert(v.id)
            log("[\(v.label)] Check window started (scheduled time: \(v.scheduledDate.formatted(date: .abbreviated, time: .standard)))")
        }

        let result = await fetchMeta(url: v.url)
        v.lastChecked = Date()
        guard let meta = result.meta else {
            let detail = tail(result.stderr)
            log("[\(v.label)] Check failed — could not fetch metadata (rc=\(result.exitCode)): \(detail)")
            writeBack(v, id: videoId)
            // Tot 26-09-2026 bleef dit stil: alleen een download-mislukking
            // stuurde een melding, een mislukte metadata-check nooit. Precies
            // dát liet die dag een uur lang voorbijgaan zonder dat er ook
            // maar één pushmelding afging — de gebruiker had geen idee dat
            // er iets mis was tot hij het zelf navroeg. Dezelfde afkoeltijd
            // als de andere mislukkingen, zodat dit niet elke 30 seconden
            // opnieuw afgaat.
            notifyFailureThrottled(videoId: v.id, title: "\(v.label) — check failing",
                                   message: "Could not fetch video info: \(detail.isEmpty ? "see the log on the Mac Mini." : detail)")
            return
        }

        let liveStatus = meta["live_status"] as? String ?? "unknown"
        let availability = meta["availability"] as? String ?? "unknown"
        let phase = desiredPhase(meta: meta, scheduled: v.scheduledDate)
        log("[\(v.label)] Check: live_status=\(liveStatus), availability=\(availability), phase=\(phase ?? "not yet")")

        if phase == "live", !v.liveDone {
            // Na een mislukking even wachten. Zonder dit startte elke ronde van
            // dertig seconden een nieuwe poging die binnen twee seconden weer
            // faalde — op 19-09-2026 ruim een kwartier lang, mét telkens een
            // nieuwe "download started"-melding.
            if let wacht = v.retryNotBefore, Date() < wacht {
                writeBack(v, id: videoId)
                return
            }
            if v.liveNotified != true {
                notify(title: "Premiere is live!", message: "\(v.label) went live, download started.")
                v.liveNotified = true
            }
            v.status = .downloadingLive
            writeBack(v, id: videoId)
            let (ok, path) = await downloadVideo(url: v.url, label: v.label, tag: "LIVE", isLive: true, videoId: v.id)
            v.liveDone = ok
            if let path { v.finalFilePath = path }
            v.status = ok ? .vodPending : .waiting
            if ok {
                notify(title: "Live download complete", message: "\(v.label) — now waiting for the VOD version.")
            } else {
                v.retryNotBefore = Date().addingTimeInterval(5 * 60)
                log("[\(v.label)] Failed — next attempt not before 5 minutes from now.")
                notifyFailureThrottled(videoId: v.id, title: "Live download failed", message: "\(v.label) — check the log on the Mac Mini.")
            }
        } else if phase == "vod", !v.vodDone {
            v.status = .downloadingVod
            writeBack(v, id: videoId)
            let (ok, path) = await downloadVideo(url: v.url, label: v.label, tag: "VOD", isLive: false, videoId: v.id)
            v.vodDone = ok
            if let path { v.finalFilePath = path }
            v.status = ok ? .done : .vodPending
            if ok {
                // "vod" is reachable two ways: after a successful LIVE capture (v.liveDone
                // true), or directly — e.g. the live window was missed entirely (a permission
                // block, the app being closed, or the stream simply ending before the first
                // check landed), in which case liveDone is still false here. Claiming "both
                // LIVE and VOD" in that second case is just wrong; said exactly that on
                // 26-09-2026 for a recording where the live capture never ran at all.
                if v.liveDone {
                    notify(title: "Premiere captured!", message: "\(v.label) — both LIVE and VOD have been downloaded.")
                } else {
                    notify(title: "VOD downloaded", message: "\(v.label) — VOD saved. The live broadcast wasn't "
                        + "captured separately (the live window was likely missed).")
                }
            } else {
                notifyFailureThrottled(videoId: v.id, title: "VOD download failed", message: "\(v.label) — check the log on the Mac Mini.")
            }
        } else if v.status != .downloadingLive && v.status != .downloadingVod {
            // Stay in .vodPending (not .waiting) if LIVE was already captured — desiredPhase
            // can briefly return nil right after a live capture (e.g. YouTube hasn't finished
            // processing the ended stream into a VOD yet), and resetting to .waiting here made
            // the row look like it hadn't started at all despite liveDone already being true.
            v.status = v.liveDone ? .vodPending : .waiting
        }
        writeBack(v, id: videoId)
    }

    /// Sends a one-shot "is everything ready" push a day before and an hour before a
    /// premiere: yt-dlp's version, folder/Chrome access, and whether the link itself
    /// still resolves — the three things that, if broken, only get discovered *during*
    /// the live attempt otherwise, when there's no time left to fix them. Added
    /// 26-09-2026 after chasing exactly that kind of surprise (Chrome access silently
    /// broken, outdated yt-dlp) live, mid-premiere, more than once.
    private func sendReadinessCheck(for video: MonitoredVideo, milestone: String) async {
        var problems: [String] = []

        if let outdated = ytDlpOutdatedVersions {
            problems.append("yt-dlp is outdated (\(outdated.current) → \(outdated.latest)) — run: brew upgrade yt-dlp")
        }
        if permissionWarnings["download-folder"] != nil {
            problems.append("Can't write to the download folder — check Full Disk Access.")
        }
        if let browser = cookieBrowser, permissionWarnings["cookie-access"] != nil {
            problems.append("Can't read \(browser.displayName)'s cookies — login-gated premieres will fail.")
        } else if cookieBrowser == nil {
            problems.append("No supported browser (Chrome or Safari) found — login-gated premieres will fail.")
        }
        if let diskWarning = permissionWarnings["disk-space"] {
            problems.append(diskWarning)
        }

        let linkResult = await fetchMeta(url: video.url)
        if linkResult.meta == nil {
            let detail = tail(linkResult.stderr)
            problems.append("Can't fetch video info (rc=\(linkResult.exitCode))\(detail.isEmpty ? "" : ": \(detail)")")
        } else if let availability = (linkResult.meta?["availability"] as? String)?.lowercased(),
                  ["private", "needs_auth", "premium_only"].contains(availability) {
            problems.append("Video availability is \"\(availability)\" — may not be downloadable.")
        }

        if problems.isEmpty {
            log("[\(video.label)] Pre-flight check (\(milestone)): all good — yt-dlp up to date, access OK, disk space OK, link OK.")
            notify(title: "\(video.label) — ready", message: "\(milestone): yt-dlp up to date, folder/Chrome access OK, disk space OK, link OK.")
        } else {
            let summary = problems.joined(separator: " · ")
            log("[\(video.label)] Pre-flight check (\(milestone)) found problems: \(summary)")
            notify(title: "\(video.label) — pre-flight check found a problem", message: "\(milestone): \(summary)")
        }
    }

    /// Fires sendReadinessCheck once per milestone per video, in a window that closes
    /// before the next milestone opens — so a late app launch doesn't fire a "1 day
    /// before" notice five minutes before showtime, and a stalled/cancelled premiere
    /// doesn't get an "1 hour before" notice days after the fact.
    private func checkReadinessMilestones(index: Int) async {
        guard videos.indices.contains(index) else { return }
        let videoId = videos[index].id
        var v = videos[index]
        guard !v.liveDone, !v.vodDone else { return }

        let now = Date()
        let dayBefore = v.scheduledDate.addingTimeInterval(-86400)
        let hourBefore = v.scheduledDate.addingTimeInterval(-3600)

        if v.dayBeforeCheckNotified != true, now >= dayBefore, now < hourBefore {
            v.dayBeforeCheckNotified = true
            writeBack(v, id: videoId)
            await sendReadinessCheck(for: v, milestone: "1 day before")
        }
        if v.hourBeforeCheckNotified != true, now >= hourBefore, now < v.scheduledDate.addingTimeInterval(900) {
            v.hourBeforeCheckNotified = true
            writeBack(v, id: videoId)
            await sendReadinessCheck(for: v, milestone: "1 hour before")
        }
    }

    /// Reprise's own current version, read from the bundle — stamped from Resources/VERSION
    /// into Info.plist by install.sh at build time, not hardcoded here too (see that file
    /// for why: Info.plist alone had already drifted three releases stale once before).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The newer version's tag if GitHub has one, nil if up to date/unknown/not yet
    /// checked. Read by the About tab; also drives a one-time notification when it changes.
    @Published var updateAvailable: String?

    private var lastUpdateCheck: Date?

    /// Same once-a-day throttle as checkYtDlpVersion, same reason: this hits GitHub's
    /// rate-limited public API (60 req/hour, shared with everything else on this network
    /// that calls it — including that same yt-dlp check), so it shouldn't run more than
    /// necessary. `force` bypasses the throttle for the manual "Check for updates" button.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 86400 { return }
        lastUpdateCheck = Date()

        guard let url = URL(string: "https://api.github.com/repos/reprise-labs/reprise/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let latestTag: String? = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: tag)
            }.resume()
        }

        guard let latestTag else {
            log("· Could not check for Reprise updates (GitHub unreachable or rate-limited).")
            return
        }

        if isVersion(latestTag, newerThan: currentVersion) {
            let wasAlreadyKnown = updateAvailable == latestTag
            updateAvailable = latestTag
            log("⬆️ Reprise \(latestTag) is available — you have \(currentVersion). See About in Settings.")
            if !wasAlreadyKnown {
                notify(title: "Reprise update available",
                      message: "\(latestTag) is available (you have \(currentVersion)). See About in Settings.")
            }
        } else {
            updateAvailable = nil
            log("✅ Reprise is up to date (\(currentVersion)).")
        }
    }

    /// Plain numeric dotted-version comparison ("1.10.0" > "1.9.0") — a string compare
    /// would wrongly say "1.9.0" is newer than "1.10.0".
    private func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").map { Int($0) ?? 0 }
        let partsB = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads the available update's release zip, unpacks it, and swaps it in for the
    /// currently-running app — then quits so the swap can happen safely (macOS doesn't
    /// lock a running executable's file, but replacing it out from under yourself while
    /// still executing is fragile; letting a detached script do it after this process is
    /// gone is the standard approach, same idea Sparkle and other updaters use).
    ///
    /// The old app bundle is renamed aside (Reprise.app.backup-<timestamp>), not deleted —
    /// same "never destroy without a way back" pattern install.sh already uses for the
    /// executable. Relaunches via `launchctl kickstart` on the LaunchAgent, not a plain
    /// `open`, so the auto-restart-on-crash supervision (KeepAlive) stays attached to the
    /// new process instead of silently going stale until the next login.
    func downloadAndInstallUpdate() async -> (ok: Bool, message: String) {
        guard let tag = updateAvailable else {
            return (false, "No update available.")
        }
        guard let url = URL(string: "https://github.com/reprise-labs/reprise/releases/download/\(tag)/Reprise.zip") else {
            return (false, "Invalid update URL.")
        }

        log("Downloading Reprise \(tag)...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RepriseUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return (false, "Could not create a temp folder: \(error.localizedDescription)")
        }
        let zipPath = tempDir.appendingPathComponent("Reprise.zip")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return (false, "Download failed: unexpected server response.")
            }
            try data.write(to: zipPath)
        } catch {
            return (false, "Download failed: \(error.localizedDescription)")
        }

        // ditto (not /usr/bin/unzip): the release zip was itself made with ditto, which
        // preserves the code signature and extended attributes an app bundle needs —
        // plain unzip can silently mangle those.
        let unzipDir = tempDir.appendingPathComponent("unzipped")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, unzipDir.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                return (false, "Could not unpack the downloaded update.")
            }
        } catch {
            return (false, "Could not unpack the downloaded update: \(error.localizedDescription)")
        }

        let newAppPath = unzipDir.appendingPathComponent("Reprise.app")
        guard FileManager.default.fileExists(atPath: newAppPath.path) else {
            return (false, "The downloaded update didn't contain Reprise.app.")
        }

        let scriptPath = tempDir.appendingPathComponent("apply_update.sh")
        let script = """
            #!/bin/bash
            sleep 1
            TS=$(date +%Y%m%d-%H%M%S)
            if [ -d "/Applications/Reprise.app" ]; then
                mv "/Applications/Reprise.app" "/Applications/Reprise.app.backup-$TS"
            fi
            mv "\(newAppPath.path)" "/Applications/Reprise.app"
            # Keep only the 2 most recent backups — otherwise every update leaves
            # another full app bundle behind forever (28-09-2026: found 3+ piled up
            # in /Applications after repeated update testing). Still a rollback
            # trail, just a bounded one instead of unbounded growth. Sorted by the
            # timestamp embedded in the name (sort -r), not mtime (ls -t) — mtime
            # turned out to not reliably match creation order for these directories.
            ls -d /Applications/Reprise.app.backup-* 2>/dev/null | sort -r | tail -n +3 | xargs rm -rf
            launchctl kickstart -k "gui/$(id -u)/com.media.reprise" 2>/dev/null || open -a "/Applications/Reprise.app"
            rm -rf "\(tempDir.path)"
            """
        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            return (false, "Could not prepare the update script: \(error.localizedDescription)")
        }

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptPath.path]
        do {
            try launcher.run()
        } catch {
            return (false, "Could not start the update script: \(error.localizedDescription)")
        }

        log("Update \(tag) downloaded — quitting to install and relaunch...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        return (true, "Installing \(tag) — Reprise will quit and reopen automatically.")
    }

    private func tick() async {
        // Vóór de guard: deze mag ook draaien als er (nog) geen video's
        // gevolgd worden. checkYtDlpVersion() remt zichzelf af tot 1x/dag.
        await checkYtDlpVersion()
        await checkForUpdates()
        checkDiskSpace()
        checkExternalTools()

        guard !videos.isEmpty else { return }
        for index in videos.indices {
            await checkReadinessMilestones(index: index)
            await checkOneVideo(index: index)
        }
        Store.save(videos)
    }
}
