import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController: NSObject {
    static var shared: StatusItemController?

    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!
    private var addWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        StatusItemController.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        Publishers.CombineLatest3(
            MonitorEngine.shared.$permissionWarnings,
            MonitorEngine.shared.$videos,
            MonitorEngine.shared.$downloadProgress
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] warnings, videos, progress in
            self?.updateStatusIcon(warnings: warnings, videos: videos, progress: progress)
        }
        .store(in: &cancellables)

        let hosting = NSHostingView(rootView: ContentView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reprise"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        self.mainWindow = window

        // Immediately close any window that isn't ours (e.g. an empty SwiftUI Settings window
        // that sometimes opens automatically) as soon as it appears.
        //
        // Must never touch an NSPanel: NSOpenPanel/NSSavePanel/NSAlert/NSColorPanel are all
        // NSPanel subclasses, and hiding one mid-modal-session is not the same as dismissing
        // it — orderOut() just hides the window while its runModal() keeps waiting forever
        // for an OK/Cancel that can no longer happen. Found 27-09-2026: choosing a custom
        // download folder in Settings opened the standard folder picker, which became key,
        // got auto-hidden by this exact observer, and froze the whole app (app-modal sessions
        // block all of Reprise's own windows too, not just the picker).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let strayWindow = notification.object as? NSWindow, !(strayWindow is NSPanel) else { return }
            if !self.ownedWindows.contains(where: { $0 === strayWindow }) {
                strayWindow.orderOut(nil)
            }
        }
    }

    /// Reflects overall status in the menu bar icon itself, so it's visible without
    /// opening the window at all: red while any check currently has a problem
    /// (permission, disk space, ...) — that always wins, even mid-download, since it's
    /// the more urgent thing to notice — blue while a download is actively running and
    /// nothing's wrong, green while idle and everything passes. Tracks MonitorEngine's
    /// published state directly rather than polling. Added 26-09-2026 alongside the
    /// pre-flight check, for the same reason: a problem you only see once you happen to
    /// open the window is easy to miss.
    private func updateStatusIcon(warnings: [String: String], videos: [MonitoredVideo], progress: [UUID: String]) {
        guard let button = statusItem.button else { return }
        let downloading = videos.first { $0.status == .downloadingLive || $0.status == .downloadingVod }

        let color: NSColor?
        if !warnings.isEmpty {
            color = .systemRed
        } else if downloading != nil {
            color = .systemBlue
        } else {
            color = nil // all good — nothing needs attention
        }

        // Default (nil setting) is minimal: color only draws the eye when something needs
        // it (a problem or an active download); "all good" blends into the menu bar like any
        // other menu extra instead of permanently glowing green. Opt out in Settings to keep
        // the old always-green-when-idle look.
        let minimal = MonitorEngine.shared.settings.minimalMenuBarIcon ?? true
        let useTemplate = color == nil && minimal
        button.image = statusIconImage(color: color ?? .systemGreen, template: useTemplate)
        button.toolTip = statusTooltip(warnings: warnings, videos: videos, downloading: downloading, progress: progress)
    }

    /// Draws the same replay-triangle-in-a-ring shape as the app icon (AppIcon.icns),
    /// recolored per status — was still the plain system "video.badge.plus" symbol here
    /// until 27-09-2026, left over from before the app icon changed, so the two no longer
    /// matched at a glance.
    /// `template: true` draws in black and marks the image as a template — AppKit then
    /// re-tints it automatically to match the menu bar (light or dark), the same way any
    /// ordinary monochrome menu extra behaves, instead of standing out in a fixed color.
    private func statusIconImage(color: NSColor, template: Bool = false) -> NSImage {
        let drawColor: NSColor = template ? .black : color
        let canvas: CGFloat = 64
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let center = CGPoint(x: canvas / 2, y: canvas / 2)
            let ringRadius: CGFloat = canvas * 0.30
            let ringWidth: CGFloat = canvas * 0.10
            let thetaStart = -60.0 * .pi / 180
            let thetaEnd = 240.0 * .pi / 180
            let steps = 200

            ctx.beginPath()
            for i in 0...steps {
                let t = thetaStart + (thetaEnd - thetaStart) * Double(i) / Double(steps)
                let p = CGPoint(x: center.x + ringRadius * CGFloat(cos(t)), y: center.y + ringRadius * CGFloat(sin(t)))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.setStrokeColor(drawColor.cgColor)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            let endPoint = CGPoint(x: center.x + ringRadius * CGFloat(cos(thetaEnd)), y: center.y + ringRadius * CGFloat(sin(thetaEnd)))
            let tangent = thetaEnd + .pi / 2
            let chevron: CGFloat = ringWidth * 1.3
            ctx.saveGState()
            ctx.translateBy(x: endPoint.x, y: endPoint.y)
            ctx.rotate(by: CGFloat(tangent))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -chevron * 0.9, y: chevron))
            ctx.addLine(to: CGPoint(x: chevron * 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: -chevron * 0.9, y: -chevron))
            ctx.setStrokeColor(drawColor.cgColor)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            let R: CGFloat = canvas * 0.155
            ctx.beginPath()
            ctx.move(to: CGPoint(x: center.x + R, y: center.y))
            ctx.addLine(to: CGPoint(x: center.x - R * 0.5, y: center.y + R * 0.866))
            ctx.addLine(to: CGPoint(x: center.x - R * 0.5, y: center.y - R * 0.866))
            ctx.closePath()
            ctx.setFillColor(drawColor.cgColor)
            ctx.fillPath()
        }
        image.unlockFocus()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = template
        return image
    }

    private func statusTooltip(
        warnings: [String: String], videos: [MonitoredVideo], downloading: MonitoredVideo?, progress: [UUID: String]
    ) -> String {
        if let firstProblem = warnings.values.first {
            return "Reprise — ⚠️ \(firstProblem)"
        }
        if let downloading {
            let pct = progress[downloading.id].map { " (\($0))" } ?? ""
            return "Reprise — downloading: \(downloading.label)\(pct)"
        }
        if let next = videos.filter({ $0.status != .done }).min(by: { $0.scheduledDate < $1.scheduledDate }) {
            return "Reprise — next: \(next.label) (\(next.scheduledDate.formatted(date: .abbreviated, time: .shortened)))"
        }
        return "Reprise — no upcoming premieres"
    }

    private var ownedWindows: [NSWindow] {
        [mainWindow, addWindow, settingsWindow].compactMap { $0 }
    }

    @objc private func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if mainWindow.isVisible {
            mainWindow.orderOut(nil)
            updateActivationPolicy()
        } else {
            showMainWindow()
        }
    }

    /// A right-click on the icon shows this instead of opening the full window — active
    /// downloads and the next few premieres with a countdown, glanceable without the
    /// window ever coming on screen. Built fresh on every open (not kept live via
    /// Combine like the icon/tooltip) since it only exists for the few seconds it's open.
    private func showQuickMenu() {
        guard let button = statusItem.button, let event = NSApp.currentEvent else { return }
        let engine = MonitorEngine.shared
        let videos = engine.videos
        let downloading = videos.filter { $0.status == .downloadingLive || $0.status == .downloadingVod }
        let upcoming = videos.filter { $0.status != .done }
            .sorted { $0.scheduledDate < $1.scheduledDate }
            .filter { v in !downloading.contains { $0.id == v.id } }
            .prefix(5)

        let menu = NSMenu()

        if !downloading.isEmpty {
            menu.addItem(withTitle: "Downloading now", action: nil, keyEquivalent: "").isEnabled = false
            for v in downloading {
                let pct = engine.downloadProgress[v.id].map { " — \($0)" } ?? ""
                menu.addItem(withTitle: "   \(v.label)\(pct)", action: nil, keyEquivalent: "")
            }
        }

        if !upcoming.isEmpty {
            if !downloading.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Upcoming", action: nil, keyEquivalent: "").isEnabled = false
            for v in upcoming {
                menu.addItem(withTitle: "   \(v.label) — \(formattedCountdown(to: v.scheduledDate))",
                             action: nil, keyEquivalent: "")
            }
        }

        if downloading.isEmpty && upcoming.isEmpty {
            menu.addItem(withTitle: "No upcoming premieres", action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())
        let openItem = menu.addItem(withTitle: "Open Reprise", action: #selector(openFromQuickMenu), keyEquivalent: "")
        openItem.target = self
        let quitItem = menu.addItem(withTitle: "Quit Reprise", action: #selector(quitFromQuickMenu), keyEquivalent: "")
        quitItem.target = self

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func openFromQuickMenu() {
        showMainWindow()
    }

    @objc private func quitFromQuickMenu() {
        quit()
    }

    /// macOS doesn't easily let accessory apps (no Dock icon) truly become "active", which
    /// can leave keyboard input stuck on the previous app. So whenever we show a window, we
    /// briefly switch to a regular app (a short-lived Dock icon) so activation/focus works
    /// reliably; once everything is closed again, we switch back to accessory.
    private func updateActivationPolicy() {
        if MonitorEngine.shared.settings.showDockIcon == true {
            NSApp.setActivationPolicy(.regular)
            return
        }
        let anyVisible = ownedWindows.contains { $0.isVisible }
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
    }

    /// Called right after Settings saves, so toggling "Show icon in Dock" takes effect
    /// immediately instead of only on the next launch.
    func refreshActivationPolicy() {
        updateActivationPolicy()
    }

    /// Called right after Settings saves "Only color the icon for problems or downloads",
    /// so it takes effect immediately — updateStatusIcon otherwise only redraws in response
    /// to warnings/videos/progress changing, none of which this setting affects on its own.
    func refreshIcon() {
        let engine = MonitorEngine.shared
        updateStatusIcon(warnings: engine.permissionWarnings, videos: engine.videos, progress: engine.downloadProgress)
    }

    /// Closes any window that isn't one of ours (e.g. an accidentally opened empty
    /// SwiftUI Settings window).
    /// Same NSPanel exception as the didBecomeKeyNotification observer above — this runs
    /// from a couple of async callbacks (showMainWindow, showAuxiliaryWindow) that could in
    /// principle fire while a system panel (open/save/alert/color) is up.
    private func closeStrayWindows() {
        for window in NSApp.windows where !(window is NSPanel) && !ownedWindows.contains(where: { $0 === window }) {
            window.orderOut(nil)
        }
    }

    func showMainWindow() {
        closeStrayWindows()
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        positionUnderStatusItem(mainWindow)
        mainWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow.makeKeyAndOrderFront(nil)
            self.closeStrayWindows()
        }
    }

    func showAddWindow(editing video: MonitoredVideo? = nil) {
        closeStrayWindows()
        if addWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            self.addWindow = window
        }
        addWindow?.title = video == nil ? "Add new premiere" : "Edit premiere"
        // Always a fresh view so the form starts with the right (empty or pre-filled) state.
        addWindow?.contentView = NSHostingView(rootView: AddVideoView(editing: video))
        showAuxiliaryWindow(addWindow!)
    }

    func showSettingsWindow() {
        closeStrayWindows()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            self.settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView())
        showAuxiliaryWindow(settingsWindow!)
    }

    private func showAuxiliaryWindow(_ window: NSWindow) {
        // Make sure the main window is visible (in the background) before this window comes in front of it.
        if !mainWindow.isVisible {
            positionUnderStatusItem(mainWindow)
            mainWindow.orderFront(nil)
        }
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        positionUnderStatusItem(window)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.closeStrayWindows()
        }
    }

    func closeAddWindowAndShowMain() {
        addWindow?.orderOut(nil)
        showMainWindow()
    }

    func closeSettingsWindow() {
        settingsWindow?.orderOut(nil)
        showMainWindow()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func positionUnderStatusItem(_ window: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.frame
        let windowSize = window.frame.size
        let x = buttonFrame.origin.x + buttonFrame.width / 2 - windowSize.width / 2
        let y = buttonFrame.origin.y - windowSize.height - 4
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
