import AppKit
import Combine

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

struct StatusMenuStatusRow: Equatable, Identifiable {
    enum RowID: Hashable {
        case device
        case microphone
        case systemAudio
        case mixer
        case health
    }

    let id: RowID
    let title: String
    let presentation: MenuStatusPresentation
}

struct StatusMenuSnapshot: Equatable {
    let title: String
    let primaryStatus: String
    let rows: [StatusMenuStatusRow]
    let microphoneGuidance: String?
    let launchAtStartupEnabled: Bool
    let launchAtStartupStatus: String
    let launchAtStartupErrorMessage: String?
    let actions: [MenuActionPresentation]
}

@MainActor
extension AppStatusModel {
    var statusMenuSnapshot: StatusMenuSnapshot {
        StatusMenuSnapshot(
            title: "MixedCaptureAudio",
            primaryStatus: primaryStatusLine,
            rows: [
                StatusMenuStatusRow(id: .device, title: "Device", presentation: deviceStatusPresentation),
                StatusMenuStatusRow(id: .microphone, title: "Mic", presentation: microphoneStatusPresentation),
                StatusMenuStatusRow(id: .systemAudio, title: "System", presentation: systemAudioStatusPresentation),
                StatusMenuStatusRow(id: .mixer, title: "Mixer", presentation: mixerStatusPresentation),
                StatusMenuStatusRow(
                    id: .health,
                    title: "Health",
                    presentation: MenuStatusPresentation(recentHealthSummary: recentHealthSummary)
                )
            ],
            microphoneGuidance: microphoneFaultGuidance,
            launchAtStartupEnabled: launchAtStartupIsEnabled,
            launchAtStartupStatus: launchAtStartupDisplayStatus,
            launchAtStartupErrorMessage: launchAtStartupErrorMessage,
            actions: statusMenuActions
        )
    }

    private var deviceStatusPresentation: MenuStatusPresentation {
        let value = virtualAudioDeviceName ?? displayStatus(driverStatus.rawValue)
        switch driverStatus {
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
        switch microphoneFault {
        case .none where microphonePermission == .granted && (activeMicrophoneName != nil || selectedMicrophoneName != nil):
            return MenuStatusPresentation(value: microphoneStatusText, tone: .good, systemImageName: "checkmark.circle.fill")
        case .none:
            return MenuStatusPresentation(value: microphoneStatusText, tone: .neutral, systemImageName: "circle")
        case .usingFallback:
            return MenuStatusPresentation(value: microphoneStatusText, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .selectedUnavailable, .permissionRevoked:
            return MenuStatusPresentation(value: microphoneStatusText, tone: .error, systemImageName: "xmark.octagon.fill")
        }
    }

    private var systemAudioStatusPresentation: MenuStatusPresentation {
        let value = displayStatus(systemAudioAccess.rawValue)
        switch systemAudioAccess {
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
        switch liveMixerState {
        case .running:
            return MenuStatusPresentation(value: liveMixerDisplayStatus, tone: .good, systemImageName: "checkmark.circle.fill")
        case .starting, .stopping:
            return MenuStatusPresentation(value: liveMixerDisplayStatus, tone: .warning, systemImageName: "exclamationmark.triangle.fill")
        case .failed:
            return MenuStatusPresentation(value: liveMixerDisplayStatus, tone: .error, systemImageName: "xmark.octagon.fill")
        case .stopped:
            return MenuStatusPresentation(value: liveMixerDisplayStatus, tone: .neutral, systemImageName: "circle")
        }
    }

    private func displayStatus(_ status: String) -> String {
        SetupStepPresentation(status: status).displayStatus
    }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let model: AppStatusModel
    private let openSetup: @MainActor () -> Void
    private let terminate: @MainActor () -> Void
    private var cancellable: AnyCancellable?
    private var headerView: StatusMenuHeaderView?
    private var statusRows: [StatusMenuStatusRow.RowID: StatusMenuStatusRowView] = [:]
    private var launchAtStartupItem: NSMenuItem?
    private var launchAtStartupView: StatusMenuLaunchAtStartupView?
    private var displayedSnapshot: StatusMenuSnapshot?
    private var isMenuOpen = false

    init(model: AppStatusModel, openSetup: @escaping @MainActor () -> Void, terminate: @escaping @MainActor () -> Void = {
        NSApplication.shared.terminate(nil)
    }) {
        self.model = model
        self.openSetup = openSetup
        self.terminate = terminate
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateVisibleMenu()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        model.refreshLaunchAtStartupStatus()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func rebuildMenu() {
        let snapshot = model.statusMenuSnapshot
        displayedSnapshot = snapshot
        headerView = nil
        statusRows.removeAll(keepingCapacity: true)
        launchAtStartupItem = nil
        launchAtStartupView = nil
        menu.removeAllItems()

        menu.addItem(headerItem(snapshot: snapshot))

        for row in snapshot.rows {
            let rowView = StatusMenuStatusRowView(row: row)
            statusRows[row.id] = rowView
            menu.addItem(viewItem(rowView))
        }

        if let guidance = snapshot.microphoneGuidance {
            menu.addItem(viewItem(StatusMenuMessageView(message: guidance)))
        }

        menu.addItem(.separator())
        menu.addItem(viewItem(StatusMenuSectionHeaderView(title: "Settings")))
        menu.addItem(launchAtStartupItem(snapshot: snapshot))

        if let message = snapshot.launchAtStartupErrorMessage {
            menu.addItem(viewItem(StatusMenuMessageView(message: message)))
        }

        menu.addItem(.separator())
        for action in snapshot.actions {
            menu.addItem(menuItem(for: action))
        }
    }

    private func updateVisibleMenu() {
        guard isMenuOpen else {
            return
        }
        let snapshot = model.statusMenuSnapshot
        guard canUpdateInPlace(from: displayedSnapshot, to: snapshot) else {
            rebuildMenu()
            return
        }
        for row in snapshot.rows {
            statusRows[row.id]?.update(row: row)
        }
        headerView?.update(
            symbolName: model.menuBarSystemImage,
            title: snapshot.title,
            subtitle: snapshot.primaryStatus
        )
        launchAtStartupItem?.toolTip = snapshot.launchAtStartupStatus
        launchAtStartupView?.update(
            isEnabled: snapshot.launchAtStartupEnabled,
            status: snapshot.launchAtStartupStatus
        )
        displayedSnapshot = snapshot
    }

    private func canUpdateInPlace(from old: StatusMenuSnapshot?, to new: StatusMenuSnapshot) -> Bool {
        guard let old else {
            return false
        }
        return old.rows.map(\.id) == new.rows.map(\.id) &&
            old.microphoneGuidance == new.microphoneGuidance &&
            old.launchAtStartupErrorMessage == new.launchAtStartupErrorMessage &&
            old.actions.map(\.id) == new.actions.map(\.id)
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func headerItem(snapshot: StatusMenuSnapshot) -> NSMenuItem {
        let view = StatusMenuHeaderView(
            symbolName: model.menuBarSystemImage,
            title: snapshot.title,
            subtitle: snapshot.primaryStatus
        )
        headerView = view
        return viewItem(view)
    }

    private func launchAtStartupItem(snapshot: StatusMenuSnapshot) -> NSMenuItem {
        let view = StatusMenuLaunchAtStartupView(
            title: "Launch at startup",
            isEnabled: snapshot.launchAtStartupEnabled,
            status: snapshot.launchAtStartupStatus,
            onToggle: { [weak self] in
                self?.toggleLaunchAtStartup()
            }
        )
        launchAtStartupView = view
        let item = NSMenuItem(title: "Launch at startup", action: nil, keyEquivalent: "")
        item.view = view
        item.toolTip = snapshot.launchAtStartupStatus
        launchAtStartupItem = item
        return item
    }

    private func menuItem(for presentation: MenuActionPresentation) -> NSMenuItem {
        let item = NSMenuItem(
            title: presentation.title,
            action: selector(for: presentation.action),
            keyEquivalent: ""
        )
        item.target = self
        item.image = menuImage(systemName: presentation.systemImageName)
        return item
    }

    private func selector(for action: MenuActionPresentation.Action) -> Selector {
        switch action {
        case .requestMicrophoneAccess:
            return #selector(requestMicrophoneAccess)
        case .checkSystemAudio:
            return #selector(checkSystemAudio)
        case .openSetup:
            return #selector(openSetupAction)
        case .quit:
            return #selector(quitAction)
        }
    }

    private func toggleLaunchAtStartup() {
        model.toggleLaunchAtStartup()
        updateVisibleMenu()
    }

    @objc private func requestMicrophoneAccess() {
        Task { @MainActor in
            await model.requestMicrophoneAccess()
        }
    }

    @objc private func checkSystemAudio() {
        Task { @MainActor in
            await model.checkSystemAudioAccess()
        }
    }

    @objc private func openSetupAction() {
        openSetup()
    }

    @objc private func quitAction() {
        terminate()
    }
}

final class StatusMenuHeaderView: NSView {
    private static let rowWidth: CGFloat = 360
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")

    private(set) var symbolName: String = ""
    private(set) var titleText: String = ""
    private(set) var subtitleText: String = ""

    init(symbolName: String, title: String, subtitle: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 54))
        translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.font = .systemFont(ofSize: 12)
        buildLayout()
        update(symbolName: symbolName, title: title, subtitle: subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: 54)
    }

    func update(symbolName: String, title: String, subtitle: String) {
        self.symbolName = symbolName
        titleText = title
        subtitleText = subtitle
        imageView.image = menuImage(systemName: symbolName)
        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        setAccessibilityLabel("\(title), \(subtitle)")
    }

    private func buildLayout() {
        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        for view in [imageView, stack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

final class StatusMenuStatusRowView: NSView {
    private static let rowWidth: CGFloat = 360
    private let titleField = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let valueField = NSTextField(labelWithString: "")

    private(set) var titleText: String = ""
    private(set) var valueText: String = ""
    private(set) var symbolName: String?

    init(row: StatusMenuStatusRow) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        titleField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 13)
        valueField.font = .systemFont(ofSize: 13)
        valueField.lineBreakMode = .byTruncatingMiddle
        buildLayout()
        update(row: row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: 28)
    }

    func update(row: StatusMenuStatusRow) {
        titleText = row.title
        valueText = row.presentation.value
        symbolName = row.presentation.systemImageName

        titleField.stringValue = row.title
        valueField.stringValue = row.presentation.value
        setAccessibilityLabel("\(row.title), \(row.presentation.value)")
        if let systemImageName = row.presentation.systemImageName {
            imageView.image = menuImage(systemName: systemImageName)
        } else {
            imageView.image = nil
        }
        imageView.contentTintColor = row.presentation.tone.nsColor
    }

    private func buildLayout() {
        for view in [titleField, imageView, valueField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.widthAnchor.constraint(equalToConstant: 92),
            imageView.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            valueField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

final class StatusMenuSectionHeaderView: NSView {
    private static let rowWidth: CGFloat = 360

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 24))
        setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: 24)
    }
}

final class StatusMenuLaunchAtStartupView: NSView {
    private static let rowWidth: CGFloat = 360
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "")
    private let onToggle: () -> Void

    private(set) var titleText: String
    private(set) var statusText: String
    private(set) var isChecked: Bool

    init(title: String, isEnabled: Bool, status: String, onToggle: @escaping () -> Void) {
        titleText = title
        statusText = status
        isChecked = isEnabled
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 36))
        translatesAutoresizingMaskIntoConstraints = false
        checkbox.title = title
        checkbox.font = .systemFont(ofSize: 13)
        checkbox.target = self
        checkbox.action = #selector(toggle)
        statusField.textColor = .secondaryLabelColor
        statusField.font = .systemFont(ofSize: 13)
        buildLayout()
        update(isEnabled: isEnabled, status: status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: 36)
    }

    func update(isEnabled: Bool, status: String) {
        isChecked = isEnabled
        statusText = status
        checkbox.state = isEnabled ? .on : .off
        statusField.stringValue = status
        setAccessibilityLabel("\(titleText), \(status)")
    }

    func performToggleForTesting() {
        toggle()
    }

    @objc private func toggle() {
        onToggle()
    }

    private func buildLayout() {
        for view in [checkbox, statusField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -12),
            statusField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

final class StatusMenuMessageView: NSView {
    private static let rowWidth: CGFloat = 360
    private let rowHeight: CGFloat

    init(message: String) {
        let labelWidth = Self.rowWidth - 28
        let font = NSFont.systemFont(ofSize: 11)
        let measuredHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height)
        rowHeight = max(32, measuredHeight + 12)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: rowHeight))
        setAccessibilityLabel(message)
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.font = font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.rowWidth, height: rowHeight)
    }
}

private extension MenuStatusPresentation.Tone {
    var nsColor: NSColor {
        switch self {
        case .neutral:
            .secondaryLabelColor
        case .good:
            .systemGreen
        case .warning:
            .systemOrange
        case .error:
            .systemRed
        }
    }
}

private func menuImage(systemName: String) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    image?.isTemplate = true
    return image
}
