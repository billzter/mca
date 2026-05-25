import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SetupLayout {
    static let actionColumnWidth: CGFloat = 360
}

struct SetupView: View {
    @ObservedObject var model: AppStatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                checklist
                actionPanels
                diagnostics
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("MixedCaptureAudio")
                .font(.largeTitle.weight(.semibold))
            Text("Set up the mixed input QuickTime will use.")
                .foregroundStyle(.secondary)
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            SetupChecklistRow(
                title: "Virtual Audio Device",
                primary: model.virtualAudioDeviceName ?? "Mixed Capture Audio",
                status: model.driverStatus.rawValue
            )
            SetupDivider()
            SetupChecklistRow(
                title: "Microphone",
                primary: model.microphoneStatusText,
                status: model.microphoneChecklistStatus
            )
            SetupDivider()
            SetupChecklistRow(
                title: "System Audio",
                primary: systemAudioPrimaryText,
                status: model.systemAudioAccess.rawValue
            )
            SetupDivider()
            SetupChecklistRow(
                title: "QuickTime Input",
                primary: "Mixed Capture Audio",
                status: model.quickTimeDeviceStatus.rawValue
            )
        }
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    private var systemAudioPrimaryText: String {
        switch model.systemAudioAccess {
        case .receivingAudio:
            "Audio detected"
        case .proceedUnverified:
            "Previously verified"
        default:
            "Awaiting test"
        }
    }

    private var actionPanels: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicrophoneAccessPanel(model: model)
            MicrophoneFaultPanel(model: model)
            MicrophonePriorityPanel(model: model)
            SystemAudioAccessPanel(model: model)

            Button {
                model.refreshPrerequisites()
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnostics: some View {
        DiagnosticsDefinitionsView(summary: model.healthSummary)
            .padding(.top, 2)
    }
}

private struct SetupChecklistRow: View {
    let title: String
    let primary: String
    let status: String

    var body: some View {
        let presentation = SetupStepPresentation(status: status)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(primary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusBadge(status: presentation.displayStatus, isComplete: presentation.isComplete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct SetupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

private struct StatusBadge: View {
    let status: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .imageScale(.small)
            Text(status)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isComplete ? .green : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isComplete ? Color.green.opacity(0.10) : Color.primary.opacity(0.04)), in: Capsule())
    }
}

private struct SystemAudioAccessPanel: View {
    @ObservedObject var model: AppStatusModel

    var body: some View {
        ActionPanel(
            title: "System Audio",
            message: model.systemAudioGuidance ?? "Play audible, unmuted system audio before running the check.",
            isVisible: model.canCheckSystemAudioAccess || model.systemAudioGuidance != nil
        ) {
            if model.canCheckSystemAudioAccess {
                Button {
                    Task {
                        await model.checkSystemAudioAccess()
                        await refocusSetupWindowAfterPrompt()
                    }
                } label: {
                    Label("Check System Audio", systemImage: "speaker.wave.2")
                }
            }
            if model.systemAudioAccess == .deniedOrUnavailable || model.systemAudioAccess == .failed {
                Button {
                    openSystemAudioSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
            }
        }
    }

    private func openSystemAudioSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct MicrophoneFaultPanel: View {
    @ObservedObject var model: AppStatusModel

    var body: some View {
        ActionPanel(
            title: "Microphone Needs Attention",
            message: model.microphoneFaultGuidance ?? "",
            isVisible: model.microphoneFaultGuidance != nil
        ) {
            if model.microphoneFault == .permissionRevoked {
                Button {
                    openMicrophoneSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
            }
            Button {
                model.refreshPrerequisites()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct MicrophoneAccessPanel: View {
    @ObservedObject var model: AppStatusModel

    var body: some View {
        ActionPanel(
            title: "Microphone",
            message: model.microphoneDeniedGuidance ?? "Allow access before using the mixed input.",
            isVisible: model.canRequestMicrophoneAccess || model.microphoneDeniedGuidance != nil
        ) {
            if model.canRequestMicrophoneAccess {
                Button {
                    Task {
                        await model.requestMicrophoneAccess()
                        await refocusSetupWindowAfterPrompt()
                    }
                } label: {
                    Label("Request Microphone Access", systemImage: "mic")
                }
            }
            if let _ = model.microphoneDeniedGuidance {
                Button {
                    openMicrophoneSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                Button {
                    model.refreshPrerequisites()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private func refocusSetupWindowAfterPrompt() async {
    AppServices.shared.showSetupWindow()
    try? await Task.sleep(nanoseconds: 300_000_000)
    AppServices.shared.showSetupWindow()
    try? await Task.sleep(nanoseconds: 900_000_000)
    AppServices.shared.showSetupWindow()
}

private struct MicrophonePriorityPanel: View {
    @ObservedObject var model: AppStatusModel
    @State private var draggedMicrophoneID: String?
    @State private var dropTargetInsertionIndex: Int?

    var body: some View {
        ActionPanel(
            title: "Microphone Priority",
            message: "Click a microphone to make it active. Drag to set fallback order.",
            isVisible: model.microphonePermission == .granted && !model.microphonePriorityItems.isEmpty
        ) {
            let items = model.microphonePriorityItems
            VStack(spacing: 0) {
                ForEach(Array(0...items.count), id: \.self) { index in
                    MicrophonePriorityInsertionSlot(isActive: dropTargetInsertionIndex == index)
                        .onDrop(
                            of: [UTType.text],
                            delegate: MicrophonePriorityInsertionDropDelegate(
                                insertionIndex: index,
                                model: model,
                                draggedMicrophoneID: $draggedMicrophoneID,
                                dropTargetInsertionIndex: $dropTargetInsertionIndex
                            )
                    )
                    if index < items.count {
                        let item = items[index]
                        MicrophonePriorityRow(
                            item: item,
                            isDragging: draggedMicrophoneID == item.id,
                            isSelectionDisabled: draggedMicrophoneID != nil,
                            dragProvider: {
                            draggedMicrophoneID = item.id
                            return NSItemProvider(object: item.id as NSString)
                            },
                            select: {
                            model.selectMicrophone(id: item.id)
                            }
                        )
                    }
                }
            }
            .frame(width: SetupLayout.actionColumnWidth, alignment: .trailing)
        }
    }
}

private struct MicrophonePriorityInsertionDropDelegate: DropDelegate {
    let insertionIndex: Int
    @ObservedObject var model: AppStatusModel
    @Binding var draggedMicrophoneID: String?
    @Binding var dropTargetInsertionIndex: Int?

    func dropEntered(info: DropInfo) {
        guard draggedMicrophoneID != nil else {
            return
        }
        dropTargetInsertionIndex = insertionIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetInsertionIndex == insertionIndex {
            dropTargetInsertionIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = draggedMicrophoneID else {
            return false
        }
        withAnimation(.snappy(duration: 0.18)) {
            model.moveMicrophonePriority(
                draggedID: draggedID,
                toInsertionIndex: insertionIndex,
                reconcileMixer: false
            )
        }
        dropTargetInsertionIndex = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            draggedMicrophoneID = nil
            model.reconcileLiveMixerAfterPriorityChange()
        }
        return true
    }
}

private struct MicrophonePriorityInsertionSlot: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(height: 3)
            }
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct MicrophonePriorityRow: View {
    let item: MicrophonePriorityItem
    let isDragging: Bool
    let isSelectionDisabled: Bool
    let dragProvider: () -> NSItemProvider
    let select: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
                .contentShape(Rectangle())
                .onDrag(dragProvider)
                .help("Drag to change fallback priority")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            Button(action: select) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.medium)
                    .foregroundStyle(item.isSelected ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled || item.isSelected || !item.isAvailable)
            .help(item.isSelected ? "Active microphone" : "Use this microphone")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .opacity(isDragging ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var rowBackground: Color {
        return Color.primary.opacity(item.isActive ? 0.06 : 0.035)
    }

    private var statusText: String {
        if item.isSelected && item.isActive {
            "Active"
        } else if item.isSelected && !item.isAvailable {
            "Selected unavailable"
        } else if item.isSelected {
            "Selected"
        } else if item.isActive {
            "Fallback active"
        } else if item.isAvailable {
            "Available"
        } else {
            "Unavailable"
        }
    }

    private var statusColor: Color {
        if item.isSelected && item.isAvailable {
            .green
        } else if item.isActive {
            .blue
        } else if item.isAvailable {
            .secondary
        } else {
            .orange
        }
    }
}

private struct ActionPanel<Actions: View>: View {
    let title: String
    let message: String
    let isVisible: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if isVisible {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 8) {
                    actions()
                }
                .frame(width: SetupLayout.actionColumnWidth, alignment: .trailing)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DiagnosticsDefinitionsView: View {
    let summary: HealthDiagnosticSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            Text("Transport health only. No recordings or audio content are stored here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(summary.diagnosticsOnlyTerms.prefix(4)) { term in
                    HStack(alignment: .firstTextBaseline) {
                        Text(term.name)
                            .frame(width: 150, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(term.explanation)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
