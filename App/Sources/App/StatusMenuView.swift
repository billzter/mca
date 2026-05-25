import AppKit
import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var model: AppStatusModel
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(model: model)

            VStack(spacing: 6) {
                MenuStatusRow(title: "Device", value: model.virtualAudioDeviceName ?? displayStatus(model.driverStatus.rawValue))
                MenuStatusRow(title: "Mic", value: model.microphoneStatusText)
                MenuStatusRow(title: "System", value: displayStatus(model.systemAudioAccess.rawValue))
                MenuStatusRow(title: "Mixer", value: model.liveMixerDisplayStatus)
                MenuStatusRow(title: "Health", value: model.healthSummary.severity.rawValue)
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
                if model.canRequestMicrophoneAccess {
                    MenuActionButton(title: "Request Microphone Access", systemImage: "mic") {
                        Task {
                            await model.requestMicrophoneAccess()
                        }
                    }
                }
                if model.canCheckSystemAudioAccess {
                    MenuActionButton(title: "Check System Audio", systemImage: "speaker.wave.2") {
                        Task {
                            await model.checkSystemAudioAccess()
                        }
                    }
                }
                MenuActionButton(title: "Open Setup", systemImage: "slider.horizontal.3") {
                    openSetup()
                }
                MenuActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
                    model.refreshPrerequisites()
                }
                MenuActionButton(title: "Quit", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
    }

    private func displayStatus(_ status: String) -> String {
        SetupStepPresentation(status: status).displayStatus
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
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
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
