import SwiftUI
import AppKit

/// Shown instead of the normal main window content whenever Reprise is missing a
/// permission it needs — both the download folder (without it the app can't save
/// anything) and Chrome cookie access (without it login-gated premieres silently
/// fail) block on this screen now, one section per missing permission.
struct PermissionGateView: View {
    @ObservedObject private var engine = MonitorEngine.shared
    @State private var justChecked = false

    private struct Issue: Identifiable {
        let id: String
        let title: String
        let message: String
        let instructions: String
        let settingsURL: URL?
    }

    private var issues: [Issue] {
        var result: [Issue] = []
        if engine.permissionWarnings["download-folder"] != nil {
            result.append(Issue(
                id: "download-folder",
                title: "Download folder access",
                message: "macOS is blocking Reprise from writing to its download folder — without this, "
                    + "Reprise can't save anything it downloads.",
                instructions: "Grant access in System Settings → Privacy & Security → Files and Folders → "
                    + "Reprise → Downloads Folder, then check again below.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_DownloadsFolder")
            ))
        }
        if engine.permissionWarnings["chrome-access"] != nil {
            result.append(Issue(
                id: "chrome-access",
                title: "Chrome cookie access",
                message: "macOS is blocking Reprise from reading Chrome's cookies — without this, "
                    + "premieres that need you to be logged in will fail to download.",
                instructions: "Grant access in System Settings → Privacy & Security → Full Disk Access → "
                    + "enable Reprise, then check again below. (Not the Google Chrome toggle under Files "
                    + "and Folders — that one silently un-checks itself for Reprise.)",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            ))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Reprise needs permission")
                .font(.title2).bold()

            VStack(spacing: 18) {
                ForEach(issues) { issue in
                    VStack(spacing: 8) {
                        Text(issue.title)
                            .font(.headline)
                        Text(issue.message + " " + issue.instructions)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 380)
                        if let url = issue.settingsURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open System Settings", systemImage: "gearshape")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if justChecked {
                Text("Still blocked — grant access above, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                engine.recheckPermissions()
                justChecked = true
            } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)

            Button("Quit Reprise") {
                StatusItemController.shared?.quit()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
