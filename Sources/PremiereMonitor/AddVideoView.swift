import SwiftUI

struct AddVideoView: View {
    @ObservedObject private var engine = MonitorEngine.shared

    /// When editing an existing premiere, its id (nil when adding a new one).
    private let editingId: UUID?

    @State private var url: String
    @State private var label: String
    @State private var scheduledDate: Date

    @State private var isLookingUp: Bool = false
    @State private var lookupMessage: String?
    @State private var lookupSucceeded: Bool = false

    init(editing video: MonitoredVideo? = nil) {
        self.editingId = video?.id
        _url = State(initialValue: video?.url ?? "")
        _label = State(initialValue: video?.label ?? "")
        _scheduledDate = State(initialValue: video?.scheduledDate ?? Date().addingTimeInterval(3600))
    }

    private var isEditing: Bool { editingId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit premiere" : "Add new premiere")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("YouTube URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("https://www.youtube.com/watch?v=...", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await lookupInfo() } }

                    Button {
                        Task { await lookupInfo() }
                    } label: {
                        if isLookingUp {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Look up")
                        }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }

                if let lookupMessage {
                    Text(lookupMessage)
                        .font(.caption)
                        .foregroundStyle(lookupSucceeded ? .green : .orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Band name - Concert", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Scheduled time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $scheduledDate)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    StatusItemController.shared?.closeAddWindowAndShowMain()
                }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add") {
                    let succeeded: Bool
                    if let editingId {
                        succeeded = engine.updateVideo(id: editingId, url: url, label: label, scheduledDate: scheduledDate)
                    } else {
                        succeeded = engine.addVideo(url: url, label: label, scheduledDate: scheduledDate)
                    }
                    if succeeded {
                        StatusItemController.shared?.closeAddWindowAndShowMain()
                    } else {
                        lookupMessage = "This URL is already used by another premiere."
                        lookupSucceeded = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func lookupInfo() async {
        isLookingUp = true
        lookupMessage = nil
        let result = await engine.lookupVideoInfo(url: url)
        isLookingUp = false

        if let title = result.title, label.trimmingCharacters(in: .whitespaces).isEmpty {
            label = title
        }
        if let date = result.scheduledDate {
            scheduledDate = date
            lookupMessage = "Scheduled time filled in automatically."
            lookupSucceeded = true
        } else if result.isLiveNow {
            scheduledDate = Date()
            lookupMessage = "This video is already live!"
            lookupSucceeded = true
        } else {
            lookupMessage = result.errorMessage ?? "No scheduled time found — enter it manually."
            lookupSucceeded = false
        }
    }
}
