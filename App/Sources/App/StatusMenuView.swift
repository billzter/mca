import AppKit
import SwiftUI

struct MenuStatusPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case good
        case warning
        case error
    }

    let value: String
    let tone: Tone
    let systemImageName: String?

    init(value: String, tone: Tone = .neutral, systemImageName: String? = nil) {
        self.value = value
        self.tone = tone
        self.systemImageName = systemImageName
    }

    init(recentHealthSummary summary: RecentHealthSummary) {
        let value: String
        if let detail = summary.detail {
            value = "\(summary.title) - \(detail)"
        } else {
            value = summary.title
        }

        switch summary.severity {
        case .neutral:
            self.init(value: value, tone: .neutral, systemImageName: "circle")
        case .healthy:
            self.init(value: value, tone: .good, systemImageName: "checkmark.circle.fill")
        case .degraded:
            self.init(value: value, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .failed:
            self.init(value: value, tone: .error, systemImageName: "xmark.octagon.fill")
        }
    }
}

struct MenuActionPresentation: Equatable, Identifiable {
    enum Action: Equatable {
        case requestMicrophoneAccess
        case checkSystemAudio
        case openSetup
        case quit
    }

    let action: Action
    let title: String
    let systemImageName: String

    var id: Action {
        action
    }
}

struct StatusMenuView: View {
    @ObservedObject var model: AppStatusModel
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)

            VStack(spacing: 6) {
                MenuStatusRow(title: "Device", presentation: deviceStatusPresentation)
                MenuStatusRow(title: "Mic", presentation: microphoneStatusPresentation)
                MenuStatusRow(title: "System", presentation: systemAudioStatusPresentation)
                MenuStatusRow(title: "Mixer", presentation: mixerStatusPresentation)
                MenuStatusRow(title: "Health", presentation: MenuStatusPresentation(recentHealthSummary: model.recentHealthSummary))
            }

            if let guidance = model.microphoneFaultGuidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MenuActionButton(
                    title: "Launch at startup",
                    systemImage: model.launchAtStartupIsEnabled ? "checkmark" : "circle",
                    trailingText: model.launchAtStartupDisplayStatus
                ) {
                    model.toggleLaunchAtStartup()
                }
                if let message = model.launchAtStartupErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(spacing: 4) {
                ForEach(model.statusMenuActions) { action in
                    MenuActionButton(title: action.title, systemImage: action.systemImageName) {
                        perform(action.action)
                    }
                }
            }
        }
        .padding(14)
    }

    private var deviceStatusPresentation: MenuStatusPresentation {
        let value = model.virtualAudioDeviceName ?? displayStatus(model.driverStatus.rawValue)
        switch model.driverStatus {
        case .installed:
            return MenuStatusPresentation(value: value, tone: .good, systemImageName: "checkmark.circle.fill")
        case .installedButNeedsReload:
            return MenuStatusPresentation(value: value, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .missing, .incompatible, .failed:
            return MenuStatusPresentation(value: value, tone: .error, systemImageName: "xmark.octagon.fill")
        case .unknown:
            return MenuStatusPresentation(value: value, tone: .neutral, systemImageName: "circle")
        }
    }

    private var microphoneStatusPresentation: MenuStatusPresentation {
        switch model.microphoneFault {
        case .none where model.microphonePermission == .granted && (model.activeMicrophoneName != nil || model.selectedMicrophoneName != nil):
            return MenuStatusPresentation(value: model.microphoneStatusText, tone: .good, systemImageName: "checkmark.circle.fill")
        case .none:
            return MenuStatusPresentation(value: model.microphoneStatusText, tone: .neutral, systemImageName: "circle")
        case .usingFallback:
            return MenuStatusPresentation(value: model.microphoneStatusText, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .selectedUnavailable, .permissionRevoked:
            return MenuStatusPresentation(value: model.microphoneStatusText, tone: .error, systemImageName: "xmark.octagon.fill")
        }
    }

    private var systemAudioStatusPresentation: MenuStatusPresentation {
        let value = displayStatus(model.systemAudioAccess.rawValue)
        switch model.systemAudioAccess {
        case .receivingAudio:
            return MenuStatusPresentation(value: value, tone: .good, systemImageName: "checkmark.circle.fill")
        case .promptExpected, .starting, .started, .waitingForSignal, .silent, .proceedUnverified:
            return MenuStatusPresentation(value: value, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .deniedOrUnavailable, .failed:
            return MenuStatusPresentation(value: value, tone: .error, systemImageName: "xmark.octagon.fill")
        case .unknown, .notTested:
            return MenuStatusPresentation(value: value, tone: .neutral, systemImageName: "circle")
        }
    }

    private var mixerStatusPresentation: MenuStatusPresentation {
        switch model.liveMixerState {
        case .running:
            return MenuStatusPresentation(value: model.liveMixerDisplayStatus, tone: .good, systemImageName: "checkmark.circle.fill")
        case .starting, .stopping:
            return MenuStatusPresentation(value: model.liveMixerDisplayStatus, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .failed:
            return MenuStatusPresentation(value: model.liveMixerDisplayStatus, tone: .error, systemImageName: "xmark.octagon.fill")
        case .stopped:
            return MenuStatusPresentation(value: model.liveMixerDisplayStatus, tone: .neutral, systemImageName: "circle")
        }
    }

    private func displayStatus(_ status: String) -> String {
        SetupStepPresentation(status: status).displayStatus
    }

    private func perform(_ action: MenuActionPresentation.Action) {
        switch action {
        case .requestMicrophoneAccess:
            Task {
                await model.requestMicrophoneAccess()
            }
        case .checkSystemAudio:
            Task {
                await model.checkSystemAudioAccess()
            }
        case .openSetup:
            openSetup()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }
}

struct StatusMenuPanelChrome<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                width: StatusMenuPanelLayout.width,
                alignment: .topLeading
            )
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.secondary.opacity(0.24), lineWidth: 1)
            }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: AppStatusModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSystemImage)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("MixedCaptureAudio")
                    .font(.headline)
                Text(model.primaryStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct MenuStatusRow: View {
    let title: String
    let presentation: MenuStatusPresentation

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            if let systemImageName = presentation.systemImageName {
                Image(systemName: systemImageName)
                    .foregroundStyle(presentation.tone.foregroundStyle)
                    .frame(width: 14)
            }
            Text(presentation.value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}

private extension MenuStatusPresentation.Tone {
    var foregroundStyle: Color {
        switch self {
        case .neutral:
            .secondary
        case .good:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    var trailingText: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
    }
}

struct HealthSummaryView: View {
    let summary: HealthDiagnosticSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.severity.rawValue)

            if summary.userVisibleFindings.isEmpty {
                Text("No session issues reported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.userVisibleFindings) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.name)
                            .font(.subheadline)
                        Text(finding.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
