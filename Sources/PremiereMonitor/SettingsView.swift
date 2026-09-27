import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var engine = MonitorEngine.shared

    @State private var checkLeadMinutes: Double
    @State private var vodWaitMinutes: Double
    @State private var failureCooldownMinutes: Double
    @State private var customDownloadPath: String
    @State private var lowDiskThresholdGB: Double
    @State private var showDockIcon: Bool
    @State private var cookieBrowserPreference: String
    @State private var pushoverToken: String
    @State private var pushoverUserKey: String
    @State private var usingSharedPushoverConfig: Bool
    @State private var showPushoverToken = false
    @State private var showPushoverUserKey = false

    @State private var isTestingNotification = false
    @State private var notificationTestResult: String?
    @State private var notificationTestSucceeded = false

    @State private var isTestingCookies = false
    @State private var cookieTestResult: String?
    @State private var cookieTestSucceeded = false

    private enum SettingsTab: String, CaseIterable {
        case general = "General", monitoring = "Monitoring", cookies = "Cookies", notifications = "Notifications"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .monitoring: return "clock"
            case .cookies: return "globe"
            case .notifications: return "bell"
            }
        }
    }
    @State private var selectedTab: SettingsTab = .general

    init() {
        let s = MonitorEngine.shared.settings
        _checkLeadMinutes = State(initialValue: s.checkLeadMinutes)
        _vodWaitMinutes = State(initialValue: s.vodWaitMinutes)
        _failureCooldownMinutes = State(initialValue: s.failureCooldownMinutes)
        _customDownloadPath = State(initialValue: s.customDownloadPath ?? "")
        _lowDiskThresholdGB = State(initialValue: s.lowDiskThresholdGB ?? 5)
        _showDockIcon = State(initialValue: s.showDockIcon ?? false)
        _cookieBrowserPreference = State(initialValue: s.cookieBrowserPreference ?? "auto")

        let hasOwnCredentials = !(s.pushoverToken ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(s.pushoverUserKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if hasOwnCredentials {
            _pushoverToken = State(initialValue: s.pushoverToken ?? "")
            _pushoverUserKey = State(initialValue: s.pushoverUserKey ?? "")
            _usingSharedPushoverConfig = State(initialValue: false)
        } else {
            // Show what's actually active right now (from the shared config
            // file) so you're not staring at blank fields wondering why
            // notifications work at all.
            let active = Notifier.activeCredentials(override: (nil, nil))
            _pushoverToken = State(initialValue: active.token ?? "")
            _pushoverUserKey = State(initialValue: active.userKey ?? "")
            _usingSharedPushoverConfig = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.headline)
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
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                    case .cookies: cookiesTab
                    case .notifications: notificationsTab
                    }
                }
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
        .frame(width: 420)
        .frame(maxHeight: 640)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Menu bar icon")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    iconLegendItem(color: .red, label: "Problem")
                    iconLegendItem(color: .blue, label: "Downloading")
                    iconLegendItem(color: .green, label: "All good")
                }
            }

            Toggle("Show icon in Dock", isOn: $showDockIcon)
                .help("Off (default): menu bar only, no Dock icon. On: also keeps a permanent Dock icon, "
                    + "not just while a window happens to be open.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Download location")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(customDownloadPath.isEmpty ? "Default: ~/Downloads/Reprise" : customDownloadPath)
                        .font(.system(size: 11))
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
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $checkLeadMinutes, in: 1...120, step: 1) {
                    Text("\(Int(checkLeadMinutes)) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Check interval while waiting for VOD (minutes)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $vodWaitMinutes, in: 0.5...30, step: 0.5) {
                    Text("every \(vodWaitMinutes.formatted()) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Minimum time between failure notifications (minutes)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $failureCooldownMinutes, in: 1...60, step: 1) {
                    Text("\(Int(failureCooldownMinutes)) minutes")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Warn when free disk space drops below (GB)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $lowDiskThresholdGB, in: 1...100, step: 1) {
                    Text("\(Int(lowDiskThresholdGB)) GB")
                }
            }
        }
    }

    private var cookiesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Read YouTube login cookies from")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $cookieBrowserPreference) {
                    Text("Automatic (Chrome, then Safari)").tag("auto")
                    Text("Chrome").tag("chrome")
                    Text("Safari").tag("safari")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Only matters if you have both installed but are only logged into "
                    + "YouTube in one of them — Automatic always prefers Chrome.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Diagnostics")
                    .font(.caption).foregroundStyle(.secondary)
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
                        .font(.caption2)
                        .foregroundStyle(cookieTestSucceeded ? .green : .orange)
                }
            }
        }
    }

    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Pushover credentials")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(usingSharedPushoverConfig ? "Shared (htm-rooster)" : "Your own")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((usingSharedPushoverConfig ? Color.gray : Color.green).opacity(0.15))
                        .foregroundStyle(usingSharedPushoverConfig ? Color.secondary : Color.green)
                        .clipShape(Capsule())
                }
                if usingSharedPushoverConfig {
                    Text("Currently using the shared config from ~/htm-rooster/script/config.env — "
                        + "that's why notifications show up grouped under \"HTM Rooster\" on your "
                        + "phone. Paste a new Application Token below (from pushover.net) to give "
                        + "Reprise its own name. Leave User key as-is; that's your account, not the app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Application token").font(.caption2).foregroundStyle(.secondary)
                    credentialField("Application token", text: $pushoverToken, revealed: $showPushoverToken)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("User key").font(.caption2).foregroundStyle(.secondary)
                    credentialField("User key", text: $pushoverUserKey, revealed: $showPushoverUserKey)
                }

                Text("Find both at pushover.net after creating an Application (only the token "
                    + "changes — reuse the same User key you already have).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.caption2)
                        .foregroundStyle(notificationTestSucceeded ? .green : .orange)
                }
            }
        }
    }

    @ViewBuilder
    private func iconLegendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
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

    private func save() {
        engine.settings.checkLeadMinutes = checkLeadMinutes
        engine.settings.vodWaitMinutes = vodWaitMinutes
        engine.settings.failureCooldownMinutes = failureCooldownMinutes
        engine.settings.customDownloadPath = customDownloadPath.isEmpty ? nil : customDownloadPath
        engine.settings.lowDiskThresholdGB = lowDiskThresholdGB
        engine.settings.showDockIcon = showDockIcon
        engine.settings.cookieBrowserPreference = cookieBrowserPreference
        StatusItemController.shared?.refreshActivationPolicy()

        // Only store as an override if it actually differs from what's
        // already active via the shared config — otherwise every save would
        // silently "adopt" the shared file's current values as your own,
        // and a later change to that shared file would stop taking effect.
        let active = Notifier.activeCredentials(override: (nil, nil))
        let tokenChanged = pushoverToken != (active.token ?? "")
        let userChanged = pushoverUserKey != (active.userKey ?? "")
        if tokenChanged || userChanged {
            engine.settings.pushoverToken = pushoverToken.isEmpty ? nil : pushoverToken
            engine.settings.pushoverUserKey = pushoverUserKey.isEmpty ? nil : pushoverUserKey
            engine.log("Settings saved: switched to your own Pushover credentials (no longer using the shared config.env).")
            usingSharedPushoverConfig = false
        }

        engine.log("Settings saved: check \(Int(checkLeadMinutes))min ahead, VOD interval \(vodWaitMinutes)min, notification cooldown \(Int(failureCooldownMinutes))min, download folder: \(customDownloadPath.isEmpty ? "default" : customDownloadPath), low disk warning: \(Int(lowDiskThresholdGB))GB")
    }
}
