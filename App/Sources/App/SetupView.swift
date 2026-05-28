import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum SetupLayout {
    static let actionColumnWidth: CGFloat = 360
}

struct SetupView: View {
    @ObservedObject var model: AppStatusModel
    let sourceLevelMeterModel: SourceLevelMeterModel
    @State private var checklistExpanded = false
    @State private var completedRowsExpanded = false

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

    @ViewBuilder
    private var checklist: some View {
        let presentation = checklistPresentation
        VStack(spacing: 0) {
            SetupChecklistHeader(
                completeCount: presentation.completeCount,
                totalCount: presentation.rows.count,
                status: presentation.headerStatus,
                isExpanded: checklistExpanded
            ) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    checklistExpanded.toggle()
                }
            }
            if checklistExpanded {
                SetupDivider()
                checklistRows(presentation.rows)
            } else {
                let visibleRows = presentation.defaultVisibleRows
                if !visibleRows.isEmpty {
                    SetupDivider()
                    checklistRows(visibleRows)
                }
                if !presentation.completedRows.isEmpty {
                    SetupDivider()
                    CompletedChecklistDisclosureRow(
                        count: presentation.completedRows.count,
                        isExpanded: completedRowsExpanded
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            completedRowsExpanded.toggle()
                        }
                    }
                    if completedRowsExpanded {
                        SetupDivider()
                        checklistRows(presentation.completedRows)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    private var checklistPresentation: SetupChecklistPresentation {
        SetupChecklistPresentation(rows: [
            SetupChecklistRowPresentation(
                id: .virtualAudioDevice,
                title: "Virtual Audio Device",
                primary: model.virtualAudioDeviceName ?? "Mixed Capture Audio",
                status: model.driverStatus.rawValue
            ),
            SetupChecklistRowPresentation(
                id: .microphone,
                title: "Microphone",
                primary: model.microphoneStatusText,
                status: model.microphoneChecklistStatus
            ),
            SetupChecklistRowPresentation(
                id: .systemAudio,
                title: "System Audio",
                primary: systemAudioPrimaryText,
                status: model.systemAudioAccess.rawValue
            ),
            SetupChecklistRowPresentation(
                id: .quickTimeInput,
                title: "QuickTime Input",
                primary: "Mixed Capture Audio",
                status: model.quickTimeDeviceStatus.rawValue
            ),
        ])
    }

    @ViewBuilder
    private func checklistRows(_ rows: [SetupChecklistRowPresentation]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
                SetupDivider()
            }
            SetupChecklistRow(row: row)
        }
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
            if prioritizesSystemAudioPanel {
                SystemAudioAccessPanel(model: model)
            }
            MicrophoneAccessPanel(model: model)
            MicrophoneFaultPanel(model: model)
            MicrophonePriorityPanel(model: model)
            AudioLevelPanel(model: model, sourceLevelMeterModel: sourceLevelMeterModel)
            AppAudioSelectionPanel(model: model)
            if !prioritizesSystemAudioPanel {
                SystemAudioAccessPanel(model: model)
            }

            Button {
                model.refreshPrerequisites()
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prioritizesSystemAudioPanel: Bool {
        SetupActionPanelPlacement.prioritizesSystemAudio(model.systemAudioAccess)
    }

    private var diagnostics: some View {
        DiagnosticsDefinitionsView(summary: model.healthSummary, sharedRingStats: model.sharedRingStats)
            .padding(.top, 2)
    }
}

private struct SetupChecklistHeader: View {
    let completeCount: Int
    let totalCount: Int
    let status: String?
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let status {
                StatusBadge(status: status, isComplete: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Setup")
                    .font(.callout.weight(.semibold))
                Text("\(completeCount) of \(totalCount) items checked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse setup checklist" : "Expand setup checklist")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct SetupChecklistRow: View {
    let row: SetupChecklistRowPresentation

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.callout.weight(.semibold))
                Text(row.primary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusBadge(status: row.displayStatus, isComplete: row.isComplete)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct CompletedChecklistDisclosureRow: View {
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Completed")
                    .font(.callout.weight(.medium))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
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

private struct AudioLevelPanel: View {
    @ObservedObject var model: AppStatusModel
    @ObservedObject var sourceLevelMeterModel: SourceLevelMeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio Balance")
                        .font(.headline)
                    Text("Set computer audio and voice levels for the mixed input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.audioLevelSettings.enhanceVoice },
                    set: { model.setEnhanceVoice($0) }
                )) {
                    Label("Enhance Voice", systemImage: "waveform.and.mic")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                AudioLevelSliderRow(
                    title: "Computer",
                    systemImage: "speaker.wave.2",
                    peak: sourceLevelMeterModel.snapshot.systemPeak,
                    decibels: Binding(
                        get: { model.audioLevelSettings.systemDecibels },
                        set: { model.setSystemAudioLevelDecibels($0) }
                    )
                )
                AudioLevelSliderRow(
                    title: "Voice",
                    systemImage: "mic",
                    peak: sourceLevelMeterModel.snapshot.microphonePeak,
                    decibels: Binding(
                        get: { model.audioLevelSettings.microphoneDecibels },
                        set: { model.setMicrophoneLevelDecibels($0) }
                    )
                )
            }
            .frame(width: SetupLayout.actionColumnWidth, alignment: .trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AudioLevelSliderRow: View {
    let title: String
    let systemImage: String
    let peak: Float
    @Binding var decibels: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.medium))
                    .frame(width: 72, alignment: .leading)
                Slider(
                    value: $decibels,
                    in: AudioLevelSettings.minimumDecibels...AudioLevelSettings.maximumDecibels,
                    step: 1.0
                )
                .frame(width: 166)
                Text(formattedDecibels)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 102, height: 1)
                SourceLevelMeterView(peak: peak)
                    .frame(width: 166, height: 6)
                Text(SourceLevelMeterScale.formattedDecibels(peak))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }

    private var formattedDecibels: String {
        if decibels > 0 {
            return "+\(Int(decibels)) dB"
        }
        return "\(Int(decibels)) dB"
    }
}

private struct SourceLevelMeterView: View {
    let peak: Float

    var body: some View {
        GeometryReader { proxy in
            let fraction = SourceLevelMeterScale.normalizedPeak(peak)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .fill(SourceLevelMeterScale.color(for: peak))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum SourceLevelMeterScale {
    static let floorDecibels = -60.0

    static func decibels(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 0 else {
            return floorDecibels
        }
        return max(floorDecibels, 20.0 * log10(Double(peak)))
    }

    static func normalizedPeak(_ peak: Float) -> CGFloat {
        let value = (decibels(peak) - floorDecibels) / abs(floorDecibels)
        return CGFloat(min(max(value, 0.0), 1.0))
    }

    static func formattedDecibels(_ peak: Float) -> String {
        let value = decibels(peak)
        if value <= floorDecibels {
            return "-60 dBFS"
        }
        if value > 0 {
            return "+\(Int(round(value))) dBFS"
        }
        return "\(Int(round(value))) dBFS"
    }

    static func color(for peak: Float) -> Color {
        let value = decibels(peak)
        if value >= -3.0 {
            return .red
        }
        if value >= -12.0 {
            return .yellow
        }
        return .green
    }
}

private struct AppAudioSelectionPanel: View {
    @ObservedObject var model: AppStatusModel
    @State private var isShowingAppPicker = false
    @State private var appSearchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Program Audio")
                        .font(.headline)
                    Text(selectionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Program Audio", selection: Binding(
                    get: { model.captureMode },
                    set: { model.selectCaptureMode($0) }
                )) {
                    Text("All Apps").tag(ProgramAudioCaptureMode.globalSystemAudio)
                    Text("Selected Apps").tag(ProgramAudioCaptureMode.selectedApps)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            selectedAppsArea
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectionMessage: String {
        switch model.captureMode {
        case .globalSystemAudio:
            model.selectedAppBundleIDs.isEmpty
                ? "Capturing system-wide app audio."
                : "Capturing system-wide app audio. Selected apps are ready."
        case .selectedApps:
            model.selectedAppBundleIDs.isEmpty ? "Choose at least one app." : "Capturing selected app audio."
        }
    }

    private var selectedAppsArea: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                if model.selectedAppAudioSourceItems.isEmpty {
                    Text("No apps selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(model.selectedAppAudioSourceItems) { item in
                        AppAudioSourceRow(
                            item: item,
                            iconName: "minus.circle",
                            helpText: "Remove app audio",
                            toggle: {
                                model.toggleAppAudioSource(bundleID: item.bundleID)
                            }
                        )
                    }
                }
            }
            .frame(width: SetupLayout.actionColumnWidth, alignment: .leading)

            Button {
                appSearchText = ""
                isShowingAppPicker = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .help("Add app audio")
            .popover(isPresented: $isShowingAppPicker, arrowEdge: .trailing) {
                AppAudioPickerPopover(
                    items: model.appAudioSourceItems,
                    searchText: $appSearchText,
                    toggle: { bundleID in
                        model.toggleAppAudioSource(bundleID: bundleID)
                    }
                )
            }
        }
    }
}

private struct AppAudioSourceRow: View {
    let item: AppAudioSourceItem
    let iconName: String
    let helpText: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: iconName)
                    .imageScale(.medium)
                    .foregroundStyle(iconColor)
            }
            .buttonStyle(.plain)
            .help(helpText)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isAvailable ? item.bundleID : "\(item.bundleID) unavailable")
                    .font(.caption2)
                    .foregroundStyle(bundleTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(item.isSelected ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconColor: Color {
        if iconName == "checkmark.circle.fill" {
            return .green
        }
        if iconName == "minus.circle" {
            return .secondary
        }
        return .accentColor
    }

    private var bundleTextColor: Color {
        item.isAvailable ? .secondary : .orange
    }
}

private struct AppAudioPickerPopover: View {
    let items: [AppAudioSourceItem]
    @Binding var searchText: String
    let toggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredItems) { item in
                        AppAudioSourceRow(
                            item: item,
                            iconName: item.isSelected ? "checkmark.circle.fill" : "plus.circle",
                            helpText: item.isSelected ? "Remove app audio" : "Add app audio",
                            toggle: {
                                toggle(item.bundleID)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: 360, height: 280)
        }
        .padding(12)
        .frame(width: 384)
    }

    private var filteredItems: [AppAudioSourceItem] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return items
        }
        return items.filter { item in
            item.name.localizedCaseInsensitiveContains(trimmedSearch) ||
                item.bundleID.localizedCaseInsensitiveContains(trimmedSearch)
        }
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
    let sharedRingStats: SharedRingStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics")
                .font(.headline)
            Text("Transport health only. No recordings or audio content are stored here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SharedRingStatsView(stats: sharedRingStats)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(summary.diagnosticsOnlyTerms.filter { $0.id != "shared_ring_fill" }.prefix(3)) { term in
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

private struct SharedRingStatsView: View {
    let stats: SharedRingStats

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Shared Ring")
                    .frame(width: 150, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(stats.compactValue)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption)

            DisclosureGroup("Shared Ring Details") {
                VStack(alignment: .leading, spacing: 4) {
                    SharedRingDetailRow(label: "Target Fill", value: "\(SharedRingStats.targetFillFrames) frames / \(SharedRingStats.msString(SharedRingStats.targetFillFrames))")
                    SharedRingDetailRow(label: "Current Fill", value: stats.currentFillValue)
                    SharedRingDetailRow(label: "Current Error", value: stats.currentErrorValue)
                    SharedRingDetailRow(label: "Mean Error", value: SharedRingStats.signedMsString(Int32(clamping: Int(stats.meanErrorFrames.rounded()))))
                    SharedRingDetailRow(label: "p95 Abs Error", value: SharedRingStats.msString(stats.p95AbsErrorFrames))
                    SharedRingDetailRow(label: "p99 Abs Error", value: SharedRingStats.msString(stats.p99AbsErrorFrames))
                    SharedRingDetailRow(label: "Max Abs Error", value: SharedRingStats.msString(stats.maxAbsErrorFrames))
                    SharedRingDetailRow(label: "Overrun Frames", value: "\(stats.overrunFrames)")
                    SharedRingDetailRow(label: "Samples", value: "\(stats.sampleCount)")
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(stats.sampleCount == 0)
        }
    }

    private var statusColor: Color {
        switch stats.status {
        case .noRecorder:
            .secondary
        case .warmingUp:
            .secondary
        case .stable:
            .green
        case .watch:
            .orange
        case .overrun:
            .red
        case .waitingForRecorder:
            .secondary
        case .recorderActive:
            .secondary
        }
    }
}

private struct SharedRingDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 150, alignment: .leading)
            Text(value)
        }
    }
}
