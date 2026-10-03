import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var engine = MonitorEngine.shared

    @State private var checkLeadMinutes: Double
    @State private var vodWaitMinutes: Double
    @State private var failureCooldownMinutes: Double
    @State private var customDownloadPath: String
    @State private var lowDiskThresholdGB: Double
    @State private var showDockIcon: Bool
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var startAtLoginNote: String?
    @State private var minimalMenuBarIcon: Bool
    @State private var cookieBrowserPreference: String
    @State private var pushoverToken: String
    @State private var pushoverUserKey: String
    @State private var showPushoverToken = false
    @State private var showPushoverUserKey = false

    @State private var newChannelURL = ""

    @State private var isTestingNotification = false
    @State private var notificationTestResult: String?
    @State private var notificationTestSucceeded = false

    @State private var isTestingCookies = false
    @State private var cookieTestResult: String?
    @State private var cookieTestSucceeded = false

    private enum SettingsTab: String, CaseIterable {
        case general = "General", monitoring = "Monitoring", channels = "Channels", cookies = "Cookies",
             notifications = "Notifications", about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .monitoring: return "clock"
            case .channels: return "person.2"
            case .cookies: return "globe"
            case .notifications: return "bell"
            case .about: return "info.circle"
            }
        }
    }
    @State private var selectedTab: SettingsTab = .general

    @State private var isCheckingUpdate = false
    @State private var updateCheckResult: String?
    @State private var isInstallingUpdate = false
    @State private var installResult: String?
    @State private var logCopied = false

    init() {
        let s = MonitorEngine.shared.settings
        _checkLeadMinutes = State(initialValue: s.checkLeadMinutes)
        _vodWaitMinutes = State(initialValue: s.vodWaitMinutes)
        _failureCooldownMinutes = State(initialValue: s.failureCooldownMinutes)
        _customDownloadPath = State(initialValue: s.customDownloadPath ?? "")
        _lowDiskThresholdGB = State(initialValue: s.lowDiskThresholdGB ?? 5)
        _showDockIcon = State(initialValue: s.showDockIcon ?? false)
        _minimalMenuBarIcon = State(initialValue: s.minimalMenuBarIcon ?? true)
        _cookieBrowserPreference = State(initialValue: s.cookieBrowserPreference ?? "auto")
        _pushoverToken = State(initialValue: s.pushoverToken ?? "")
        _pushoverUserKey = State(initialValue: s.pushoverUserKey ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 16)

            // A hand-rolled tab strip instead of SwiftUI's TabView: on macOS 26, TabView
            // tries to integrate tabs into the title bar and collapses into a hidden ">>"
            // overflow menu when that doesn't fit cleanly in a plain AppKit-hosted window
            // like this one — found 27-09-2026, the tabs were invisible except via that
            // chevron. A plain row of buttons has no such adaptive behavior to fight.
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15))
                            Text(tab.rawValue)
                                .font(.system(size: 12))
                                // Was wrapping "Notifications" onto its own second line once
                                // the Channels tab brought the total to 6 — each tab's share of
                                // the fixed-width strip got too narrow for its longest label at
                                // 12pt (01-10-2026). Shrinking instead of wrapping keeps every
                                // tab's label on one line regardless of how many tabs there are.
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        // Without this, .buttonStyle(.plain) only makes the icon/text glyphs
                        // themselves clickable, not the padded/colored area around them —
                        // exactly the "have to click precisely on the icon" symptom.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .general: generalTab
                    case .monitoring: monitoringTab
                    case .channels: channelsTab
                    case .cookies: cookiesTab
                    case .notifications: notificationsTab
                    case .about: aboutTab
                    }
                }
                // Without this, a tab whose content is all short Text/Button views (no
                // full-width TextField or Picker to stretch it) sizes to its own narrow
                // intrinsic width inside the ScrollView and then sits centered in the
                // leftover space — Monitoring and About looked "randomly centered"
                // while General/Channels/Cookies/Notifications looked fine purely by
                // accident, because something in each of those already happened to be
                // wide enough to fill the row (user feedback, 03-10-2026).
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    StatusItemController.shared?.closeSettingsWindow()
                }
                Button("Save") {
                    save()
                    StatusItemController.shared?.closeSettingsWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460)
        // This cap turned out to be a red herring for actual window sizing — the
        // window itself is a plain NSWindow created with a fixed contentRect
        // (StatusItemController.showSettingsWindow), so raising this SwiftUI-side
        // number alone had zero visual effect (found 03-10-2026 while chasing why
        // About's "Copy log to clipboard" needed a scroll). The real fix lives in
        // StatusItemController.resizeSettingsWindow, called below on tab change —
        // this is just a generous ceiling so the ScrollView never fights the window.
        .frame(maxHeight: 560)
        .onChange(of: selectedTab) { _, newValue in
            StatusItemController.shared?.resizeSettingsWindow(forAboutTab: newValue == .about)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Menu bar icon")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    iconLegendItem(color: .red, label: "Problem")
                    iconLegendItem(color: .blue, label: "Downloading")
                    iconLegendItem(color: minimalMenuBarIcon ? .primary : .green, label: "All good")
                }
                Toggle("Only color the icon for problems or downloads", isOn: $minimalMenuBarIcon)
                    .help("On (default): the icon blends into the menu bar when everything's fine, "
                        + "only turning red or blue when something needs attention. Off: always green "
                        + "when idle and healthy, like before.")
            }

            Toggle("Show icon in Dock", isOn: $showDockIcon)
                .help("Off (default): menu bar only, no Dock icon. On: also keeps a permanent Dock icon, "
                    + "not just while a window happens to be open.")

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Start at login", isOn: $startAtLogin)
                    .help("Automatically launches Reprise in the background when you log in to your Mac.")
                    .onChange(of: startAtLogin) { _, wantsEnabled in setStartAtLogin(wantsEnabled) }
                if let startAtLoginNote {
                    Text(startAtLoginNote)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Download location")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Text(customDownloadPath.isEmpty ? "Default: ~/Downloads/Reprise" : customDownloadPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    if !customDownloadPath.isEmpty {
                        Button("Default") { customDownloadPath = "" }
                    }
                }
            }
        }
    }

    private var monitoringTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start checking (minutes before scheduled time)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Stepper(value: $checkLeadMinutes, in: 1...120, step: 1) {
                    Text("\(Int(checkLeadMinutes)) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Check interval while waiting for VOD (minutes)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Stepper(value: $vodWaitMinutes, in: 0.5...30, step: 0.5) {
                    Text("every \(vodWaitMinutes.formatted()) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Minimum time between failure notifications (minutes)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Stepper(value: $failureCooldownMinutes, in: 1...60, step: 1) {
                    Text("\(Int(failureCooldownMinutes)) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Warn when free disk space drops below (GB)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Stepper(value: $lowDiskThresholdGB, in: 1...100, step: 1) {
                    Text("\(Int(lowDiskThresholdGB)) GB")
                }
            }
        }
    }

    private var channelsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Watch a channel for new premieres")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Checked once a day. Found premieres show up in the main window for you "
                    + "to add with one click — no need to go find the URL on YouTube yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Channel URL or @handle", text: $newChannelURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addChannel)
                    Button("Add", action: addChannel)
                        .disabled(newChannelURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if engine.channels.isEmpty {
                Text("No channels watched yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.channels) { channel in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name ?? channel.url)
                                    .font(.system(size: 13, weight: .medium))
                                if let lastChecked = channel.lastChecked {
                                    Text("Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not checked yet")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                engine.checkChannelNow(channel)
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.plain)
                            .help("Check this channel now")
                            Button {
                                engine.removeChannel(channel)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Stop watching this channel")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func addChannel() {
        let trimmed = newChannelURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if engine.addChannel(url: trimmed) {
            newChannelURL = ""
        }
    }

    private var cookiesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Read YouTube login cookies from")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Picker("", selection: $cookieBrowserPreference) {
                    Text("Automatic (Chrome, then Safari)").tag("auto")
                    Text("Chrome").tag("chrome")
                    Text("Safari").tag("safari")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Only matters if you have both installed but are only logged into "
                    + "YouTube in one of them — Automatic always prefers Chrome.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        Task { await testCookies() }
                    } label: {
                        if isTestingCookies {
                            ProgressView().controlSize(.small).frame(width: 14, height: 14)
                        } else {
                            Text("Test YouTube login")
                        }
                    }
                    .disabled(isTestingCookies)

                    Button("Log in to YouTube again") {
                        engine.openYouTubeLogin()
                    }
                    .help("Opens YouTube in your cookie browser. Log in there, then run the "
                          + "test again.")
                }
                if let cookieTestResult {
                    Text(cookieTestResult)
                        .font(.system(size: 12))
                        .foregroundStyle(cookieTestSucceeded ? .green : .orange)
                }
            }
        }
    }

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pushover credentials")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Optional — push notifications when you're away from this Mac. Get your "
                    + "keys at pushover.net.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Application token").font(.system(size: 12)).foregroundStyle(.secondary)
                    credentialField("Application token", text: $pushoverToken, revealed: $showPushoverToken)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("User key").font(.system(size: 12)).foregroundStyle(.secondary)
                    credentialField("User key", text: $pushoverUserKey, revealed: $showPushoverUserKey)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    testNotification()
                } label: {
                    if isTestingNotification {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Text("Send test notification")
                    }
                }
                .disabled(isTestingNotification)
                if let notificationTestResult {
                    Text(notificationTestResult)
                        .font(.system(size: 12))
                        .foregroundStyle(notificationTestSucceeded ? .green : .orange)
                }
            }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Fixed minHeight so the "Links"/"Troubleshooting" sections below don't
            // jump around as this block's content changes shape (no update → update
            // available → downloading) — user feedback, 02-10-2026, with screenshots
            // showing everything below sliding down a different amount per state.
            // 150 (the first guess) wasn't quite enough: measured live across all
            // three states on 03-10-2026 (triggered with a temporary dummy GitHub
            // release), the downloading+banner combo sat 14pt taller than the other
            // two, so Links/Troubleshooting still shifted down slightly. 165 covers
            // the actual tallest state with a small margin. The result-text rows
            // reserve their line even when empty (opacity 0) rather than being added
            // and removed, which is the other half of what was causing the jump.
            VStack(alignment: .leading, spacing: 6) {
                if let progress = engine.updateProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading update…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress)
                            .frame(maxWidth: 220)
                    }
                } else {
                    Text("Reprise \(engine.currentVersion)")
                        .font(.system(size: 15, weight: .semibold))
                }
                if let updateAvailable = engine.updateAvailable {
                    Text("⬆️ \(updateAvailable) is available")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    HStack(spacing: 10) {
                        Button {
                            confirmInstallUpdate(version: updateAvailable)
                        } label: {
                            if isInstallingUpdate {
                                ProgressView().controlSize(.small).frame(width: 14, height: 14)
                            } else {
                                Label("Download & Install", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstallingUpdate)

                        Link("Release notes",
                             destination: URL(string: "https://github.com/reprise-labs/reprise/releases/tag/\(updateAvailable)")!)
                            .font(.system(size: 12))
                    }
                } else if engine.updateProgress == nil {
                    Text("You're on the latest known version.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(installResult ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(installResult == nil ? 0 : 1)

                Button {
                    Task { await checkForUpdatesNow() }
                } label: {
                    if isCheckingUpdate {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Text("Check for updates")
                    }
                }
                .disabled(isCheckingUpdate)
                .padding(.top, 4)
                Text(updateCheckResult ?? " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(updateCheckResult == nil ? 0 : 1)
            }
            .frame(minHeight: 165, alignment: .top)

            VStack(alignment: .leading, spacing: 6) {
                Text("Links")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Link("GitHub repository", destination: URL(string: "https://github.com/reprise-labs/reprise")!)
                    .font(.system(size: 12))
                Link("Release notes", destination: URL(string: "https://github.com/reprise-labs/reprise/releases")!)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Troubleshooting")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Button {
                    copyLog()
                } label: {
                    Label(logCopied ? "Copied!" : "Copy log to clipboard", systemImage: logCopied ? "checkmark" : "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private func iconLegendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// A text field with an eye button to reveal/hide it. A plain SecureField
    /// hides both what's already saved AND what you're about to paste over
    /// it — you can't check you typed the right thing, or that you didn't
    /// accidentally touch the field you meant to leave alone. Defaults to
    /// hidden (it's a credential), but one click shows it in plain text.
    @ViewBuilder
    private func credentialField(_ title: String, text: Binding<String>, revealed: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Group {
                if revealed.wrappedValue {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                revealed.wrappedValue.toggle()
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.wrappedValue ? "Hide" : "Show")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            customDownloadPath = url.path
        }
    }

    /// SMAppService.mainApp registers/unregisters Reprise as a Login Item without touching
    /// any plist by hand — the modern macOS 13+ replacement for the old LaunchAgent-file
    /// approach, and it shows up correctly in System Settings → General → Login Items.
    /// Registering can succeed but leave the item in .requiresApproval state (macOS wants
    /// the user to flip it on themselves in System Settings first) — surfaced here instead
    /// of silently doing nothing, since a toggle that looks "on" but isn't would be worse
    /// than not having the feature at all.
    private func setStartAtLogin(_ wantsEnabled: Bool) {
        startAtLoginNote = nil
        do {
            if wantsEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            startAtLoginNote = "Couldn't change this: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        startAtLogin = status == .enabled
        if wantsEnabled && status == .requiresApproval {
            startAtLoginNote = "Needs approval — open System Settings → General → Login Items and enable Reprise."
        }
    }

    private func testNotification() {
        isTestingNotification = true
        notificationTestResult = nil
        engine.sendTestNotification { ok, detail in
            isTestingNotification = false
            notificationTestSucceeded = ok
            notificationTestResult = ok ? "Sent — check your phone." : "Failed: \(detail)"
        }
    }

    private func testCookies() async {
        isTestingCookies = true
        cookieTestResult = nil
        // Apply the picker's current value before testing, not just on Save — otherwise
        // picking Safari and immediately hitting Test still tests against whatever browser
        // was saved before, which looks like the picker did nothing.
        engine.settings.cookieBrowserPreference = cookieBrowserPreference
        let (ok, message) = await engine.testCookies()
        isTestingCookies = false
        cookieTestSucceeded = ok
        cookieTestResult = message
    }

    private func checkForUpdatesNow() async {
        isCheckingUpdate = true
        updateCheckResult = nil
        await engine.checkForUpdates(force: true)
        isCheckingUpdate = false
        if let updateAvailable = engine.updateAvailable {
            updateCheckResult = "\(updateAvailable) is available."
        } else {
            updateCheckResult = "You're on the latest version (\(engine.currentVersion))."
        }
    }

    private func confirmInstallUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update to \(version)?"
        alert.informativeText = "Reprise will download the update, quit, and reopen automatically with the "
            + "new version. Tracked premieres and settings aren't affected."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isInstallingUpdate = true
        installResult = nil
        Task {
            let (ok, message) = await engine.downloadAndInstallUpdate()
            // Only reachable on failure — a successful install quits the app before this
            // line would run, so seeing this means it's safe to let the user try again.
            isInstallingUpdate = false
            installResult = message
            if !ok {
                engine.log("⚠️ Update install failed: \(message)")
            }
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.logLines.joined(separator: "\n"), forType: .string)
        logCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            logCopied = false
        }
    }

    private func save() {
        engine.settings.checkLeadMinutes = checkLeadMinutes
        engine.settings.vodWaitMinutes = vodWaitMinutes
        engine.settings.failureCooldownMinutes = failureCooldownMinutes
        engine.settings.customDownloadPath = customDownloadPath.isEmpty ? nil : customDownloadPath
        engine.settings.lowDiskThresholdGB = lowDiskThresholdGB
        engine.settings.showDockIcon = showDockIcon
        engine.settings.minimalMenuBarIcon = minimalMenuBarIcon
        engine.settings.cookieBrowserPreference = cookieBrowserPreference
        engine.settings.pushoverToken = pushoverToken.isEmpty ? nil : pushoverToken
        engine.settings.pushoverUserKey = pushoverUserKey.isEmpty ? nil : pushoverUserKey
        StatusItemController.shared?.refreshActivationPolicy()
        StatusItemController.shared?.refreshIcon()

        engine.log("Settings saved: check \(Int(checkLeadMinutes))min ahead, VOD interval \(vodWaitMinutes)min, notification cooldown \(Int(failureCooldownMinutes))min, download folder: \(customDownloadPath.isEmpty ? "default" : customDownloadPath), low disk warning: \(Int(lowDiskThresholdGB))GB")
    }
}
