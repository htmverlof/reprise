import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var engine = MonitorEngine.shared

    /// Which half of the (formerly single, now tabbed) top pane is showing — split out
    /// 01-10-2026 because the old single "Found on watched channels" banner pushed the
    /// tracked list down every time a channel found something, instead of living in its
    /// own clearly-separate place.
    private enum MainSection { case tracked, upcoming }
    @State private var selectedSection: MainSection = .tracked

    private var sortedVideos: [MonitoredVideo] {
        engine.videos.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    @ViewBuilder
    private func sectionTabButton(_ section: MainSection, title: String, badgeCount: Int?) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.title2).bold()
                    .foregroundStyle(selectedSection == section ? Color.primary : Color.secondary)
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var isBlockedByPermissions: Bool {
        engine.permissionWarnings["download-folder"] != nil || engine.permissionWarnings["cookie-access"] != nil
            || engine.permissionWarnings["external-tools"] != nil
    }

    /// The video list pane used to have a flat .frame(minHeight: 260) regardless of how
    /// many premieres were tracked — with just 1-2, that left a big blank gap below the
    /// last row before the log section started (28-09-2026 feedback). Capping its max
    /// height to roughly what the current rows actually need means VSplitView gives any
    /// leftover window height to the log pane below instead, which can always use more
    /// room. Still grows normally up to the original 260 once there's enough content to
    /// fill it (3+ rows).
    private var videoListMaxHeight: CGFloat {
        let header: CGFloat = 56
        let approxRowHeight: CGFloat = 72
        let rowCount = selectedSection == .tracked ? sortedVideos.count : engine.discoveredVideos.count
        let content = header + CGFloat(max(rowCount, 1)) * approxRowHeight
        return min(max(content, 160), 260)
    }

    var body: some View {
        if isBlockedByPermissions {
            PermissionGateView()
                .frame(minWidth: 620, minHeight: 480)
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    sectionTabButton(.tracked, title: "Tracked", badgeCount: nil)
                    sectionTabButton(.upcoming, title: "Upcoming", badgeCount: engine.discoveredVideos.count)
                    Spacer()
                    Button {
                        engine.openDownloadFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open download folder")

                    Button {
                        confirmClearHistory()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!engine.videos.contains { $0.status == .done })
                    .help("Clear completed premieres from the list (downloaded files stay put)")

                    Button {
                        StatusItemController.shared?.showSettingsWindow()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")

                    Button {
                        StatusItemController.shared?.showAddWindow()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }

                    Button {
                        confirmQuit()
                    } label: {
                        Image(systemName: "power")
                    }
                    .help("Quit Reprise")
                }
                .padding([.horizontal, .top])

                if !engine.permissionWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(engine.permissionWarnings.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(engine.permissionWarnings[key] ?? "")
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                if selectedSection == .tracked {
                    if sortedVideos.isEmpty {
                        ContentUnavailableView(
                            "No premieres yet",
                            systemImage: "video.badge.plus",
                            description: Text("Click Add to track a YouTube premiere.")
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(sortedVideos) { video in
                                    VideoRow(video: video, onDelete: { confirmDelete(video) })
                                    Divider()
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 4)
                        }
                    }
                } else {
                    if engine.discoveredVideos.isEmpty {
                        ContentUnavailableView(
                            "No new premieres found",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Reprise checks your watched channels once a day.")
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(engine.discoveredVideos) { discovered in
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(discovered.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                            Text(discovered.channelName)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Dismiss") {
                                            engine.dismissDiscovered(discovered)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        Button("Add") {
                                            Task { await engine.addDiscovered(discovered) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 8)
                                    Divider()
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: videoListMaxHeight)

            VStack(alignment: .leading, spacing: 0) {
                Text("Log")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: engine.logLines.count) { _, _ in
                        if let last = engine.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(minHeight: 120)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private func confirmDelete(_ video: MonitoredVideo) {
        let alert = NSAlert()
        alert.messageText = "Delete premiere?"
        alert.informativeText = "\"\(video.label)\" will no longer be tracked."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.removeVideo(video)
        }
    }

    private func confirmClearHistory() {
        let doneCount = engine.videos.filter { $0.status == .done }.count
        guard doneCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear completed premieres?"
        alert.informativeText = "Removes \(doneCount) finished premiere\(doneCount == 1 ? "" : "s") from the list. "
            + "Downloaded files themselves are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.clearCompleted()
        }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Quit Reprise?"
        alert.informativeText = "Automatic checking and downloading will stop until you open the app again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            StatusItemController.shared?.quit()
        }
    }
}

struct VideoRow: View {
    let video: MonitoredVideo
    let onDelete: () -> Void
    @ObservedObject private var engine = MonitorEngine.shared

    private var isBusy: Bool {
        video.status == .downloadingLive || video.status == .downloadingVod
    }

    private var fileSizeText: String? {
        guard video.status == .done, let path = video.finalFilePath,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        HStack {
            AsyncImage(url: video.thumbnailURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.15)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                // Without a line limit, a title just a bit longer than the others eats into
                // the Spacer below and nudges the icon buttons out of column with every other
                // row — truncating keeps every row's trailing icons at the exact same x.
                Text(video.label)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(video.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if video.status == .waiting {
                    // SwiftUI's built-in relative style ticks down on its own — no timer needed.
                    Text("in \(video.scheduledDate, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let lastChecked = video.lastChecked {
                    Text("Last checked \(lastChecked, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isBusy, let progress = engine.downloadProgress[video.id] {
                    Text(progress)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                if let fileSizeText {
                    Text(fileSizeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                MonitorEngine.shared.checkNow(video)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help("Check now")

            Button {
                MonitorEngine.shared.runPreflightCheckNow(video)
            } label: {
                Image(systemName: "checkmark.shield")
            }
            .buttonStyle(.plain)
            .help("Run pre-flight check now (yt-dlp, access, disk space, link)")

            Button {
                StatusItemController.shared?.showAddWindow(editing: video)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help("Edit")

            Button {
                MonitorEngine.shared.revealFile(video)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Show in Finder")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(isBusy)
            .help(isBusy ? "Can't delete while downloading" : "Delete")

            HStack(spacing: 4) {
                if video.status == .done {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(video.status.displayName)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: 66)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch video.status {
        case .waiting: return .gray
        case .downloadingLive: return .red
        case .vodPending: return .orange
        case .downloadingVod: return .blue
        case .done: return .green
        }
    }
}
