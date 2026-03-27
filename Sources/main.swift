import AppKit
import IOKit.ps
import IOKit

@MainActor
@main
final class BatteryCountdownApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = SettingsStore()
    private lazy var settings = settingsStore.load()
    private let batteryMonitor = BatteryMonitor()
    private let overlayController = OverlayController()
    private let statusBarContentView = StatusBarContentView()

    private let estimateMenuItem = NSMenuItem(title: "Calculating battery trend…", action: nil, keyEquivalent: "")
    private let explanationMenuItem = NSMenuItem(title: "Collecting enough history to explain the estimate…", action: nil, keyEquivalent: "")
    private let confidenceMenuItem = NSMenuItem(title: "Confidence: warming up", action: nil, keyEquivalent: "")
    private let trendMenuItem = NSMenuItem(title: "Trend: measuring load changes…", action: nil, keyEquivalent: "")
    private let historyHeaderItem = NSMenuItem(title: "Recent Battery History:", action: nil, keyEquivalent: "")
    private let historySummaryMenuItem = NSMenuItem(title: "Collecting recent power history…", action: nil, keyEquivalent: "")
    private let historySparklineMenuItem = NSMenuItem(title: "··················", action: nil, keyEquivalent: "")
    private let learningMenuItem = NSMenuItem(title: "Learning: calibrating prediction buckets…", action: nil, keyEquivalent: "")
    private let significantEnergyHeaderItem = NSMenuItem(title: "Battery Drain Snapshot:", action: nil, keyEquivalent: "")
    private let significantEnergyInfoItem = NSMenuItem(title: "Heuristic: CPU + helper weighting", action: nil, keyEquivalent: "")
    private let settingsHeaderItem = NSMenuItem(title: "Display Settings:", action: nil, keyEquivalent: "")
    private let showPercentMenuItem = NSMenuItem(title: "Show Percent In Menu Bar", action: nil, keyEquivalent: "")
    private let clockStyleMenuItem = NSMenuItem(title: "Use Clock Style In Menu Bar", action: nil, keyEquivalent: "")
    private let showDrainSnapshotMenuItem = NSMenuItem(title: "Show Drain Snapshot", action: nil, keyEquivalent: "")

    private var significantEnergyItems: [NSMenuItem] = []
    private var lastNonEmptySignificantEnergyApps: [SignificantEnergyApp] = []
    private var lastBatteryState: BatteryState?
    private var statusItem: NSStatusItem?
    private weak var statusMenu: NSMenu?
    private var significantEnergyRefreshTimer: Timer?
    private var lastSignificantEnergyRefresh: Date?

    static func main() {
        let application = NSApplication.shared
        let delegate = BatteryCountdownApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()

        batteryMonitor.onUpdate = { [weak self] state in
            self?.handle(state: state)
        }
        batteryMonitor.start()
        scheduleSignificantEnergyRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        batteryMonitor.stop()
        significantEnergyRefreshTimer?.invalidate()
        significantEnergyRefreshTimer = nil
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            return
        }

        button.title = ""
        button.image = nil
        button.toolTip = "Battery Countdown"

        statusBarContentView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusBarContentView)
        NSLayoutConstraint.activate([
            statusBarContentView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
            statusBarContentView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
            statusBarContentView.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            statusBarContentView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1)
        ])

        let menu = NSMenu()
        menu.delegate = self
        configureStaticMenuItems()
        menu.addItem(estimateMenuItem)
        menu.addItem(explanationMenuItem)
        menu.addItem(confidenceMenuItem)
        menu.addItem(trendMenuItem)
        menu.addItem(.separator())
        menu.addItem(historyHeaderItem)
        menu.addItem(historySummaryMenuItem)
        menu.addItem(historySparklineMenuItem)
        menu.addItem(learningMenuItem)
        menu.addItem(.separator())
        menu.addItem(significantEnergyHeaderItem)
        menu.addItem(significantEnergyInfoItem)
        menu.addItem(.separator())
        menu.addItem(settingsHeaderItem)
        menu.addItem(showPercentMenuItem)
        menu.addItem(clockStyleMenuItem)
        menu.addItem(showDrainSnapshotMenuItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Battery Countdown",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
        statusMenu = menu

        refreshSettingsMenuStates()
        applySignificantEnergyApps([])
        renderPlaceholderState()
    }

    private func configureStaticMenuItems() {
        let disabledItems = [
            estimateMenuItem,
            explanationMenuItem,
            confidenceMenuItem,
            trendMenuItem,
            historyHeaderItem,
            historySummaryMenuItem,
            historySparklineMenuItem,
            learningMenuItem,
            significantEnergyHeaderItem,
            significantEnergyInfoItem,
            settingsHeaderItem
        ]
        disabledItems.forEach { $0.isEnabled = false }

        historySparklineMenuItem.attributedTitle = styledSparkline("··················")

        showPercentMenuItem.target = self
        showPercentMenuItem.action = #selector(toggleShowPercentInMenuBar)
        clockStyleMenuItem.target = self
        clockStyleMenuItem.action = #selector(toggleClockStyleInMenuBar)
        showDrainSnapshotMenuItem.target = self
        showDrainSnapshotMenuItem.action = #selector(toggleShowDrainSnapshot)
    }

    private func renderPlaceholderState() {
        let placeholder = BatteryState.placeholder
        statusBarContentView.update(state: placeholder, settings: settings)
        statusItem?.length = statusBarContentView.desiredWidth
        estimateMenuItem.title = placeholder.estimateLine
        explanationMenuItem.title = placeholder.explanationLine
        confidenceMenuItem.title = placeholder.confidenceLine
        trendMenuItem.title = placeholder.trendLine
        historySummaryMenuItem.title = placeholder.sparklineSummary
        historySparklineMenuItem.attributedTitle = styledSparkline(placeholder.sparkline)
        learningMenuItem.title = placeholder.learningLine
    }

    private func handle(state: BatteryState) {
        lastBatteryState = state
        statusBarContentView.update(state: state, settings: settings)
        statusItem?.length = statusBarContentView.desiredWidth
        statusItem?.button?.toolTip = state.tooltipText(settings: settings)

        estimateMenuItem.title = state.estimateLine
        explanationMenuItem.title = state.explanationLine
        confidenceMenuItem.title = state.confidenceLine
        trendMenuItem.title = state.trendLine
        historySummaryMenuItem.title = state.sparklineSummary
        historySparklineMenuItem.attributedTitle = styledSparkline(state.sparkline)
        learningMenuItem.title = state.learningLine

        guard state.shouldShowOverlay else {
            overlayController.hide()
            return
        }

        overlayController.show(text: state.displayText)
    }

    private func styledSparkline(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    private func scheduleSignificantEnergyRefresh() {
        refreshSignificantEnergyMenuAsync()

        significantEnergyRefreshTimer = Timer.scheduledTimer(
            timeInterval: 20,
            target: self,
            selector: #selector(handleSignificantEnergyRefreshTimer),
            userInfo: nil,
            repeats: true
        )

        if let significantEnergyRefreshTimer {
            RunLoop.main.add(significantEnergyRefreshTimer, forMode: .common)
        }
    }

    @objc
    private func handleSignificantEnergyRefreshTimer() {
        refreshSignificantEnergyMenuAsync()
    }

    func menuWillOpen(_ menu: NSMenu) {
        significantEnergyInfoItem.title = "Refreshing live snapshot…"
        refreshSignificantEnergyMenuAsync()
    }

    private func refreshSignificantEnergyMenuAsync() {
        guard settings.showDrainSnapshot else {
            applySignificantEnergyApps([])
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = Self.currentSignificantEnergyApps()
            DispatchQueue.main.async {
                self?.applySignificantEnergyApps(apps)
            }
        }
    }

    private func applySignificantEnergyApps(_ apps: [SignificantEnergyApp]) {
        guard let menu = statusMenu else {
            return
        }

        lastSignificantEnergyRefresh = Date()
        let displayedApps: [SignificantEnergyApp]
        if !settings.showDrainSnapshot {
            displayedApps = []
            significantEnergyInfoItem.title = "Drain snapshot hidden"
        } else if apps.isEmpty, !lastNonEmptySignificantEnergyApps.isEmpty {
            displayedApps = lastNonEmptySignificantEnergyApps
            significantEnergyInfoItem.title = snapshotInfoText(
                appCount: displayedApps.count,
                isLiveResultEmpty: true
            )
        } else {
            displayedApps = apps
            if !apps.isEmpty {
                lastNonEmptySignificantEnergyApps = apps
            }
            significantEnergyInfoItem.title = snapshotInfoText(
                appCount: displayedApps.count,
                isLiveResultEmpty: false
            )
        }

        for item in significantEnergyItems {
            menu.removeItem(item)
        }
        significantEnergyItems.removeAll()

        if !settings.showDrainSnapshot {
            let item = NSMenuItem(title: "Enable in Display Settings below", action: nil, keyEquivalent: "")
            item.isEnabled = false
            significantEnergyItems = [item]
        } else if displayedApps.isEmpty {
            let item = NSMenuItem(title: "No active app load detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            significantEnergyItems = [item]
        } else {
            significantEnergyItems = displayedApps.map { app in
                let item = NSMenuItem(title: app.displayText, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
        }

        guard let infoIndex = menu.items.firstIndex(of: significantEnergyInfoItem) else {
            return
        }

        for (offset, item) in significantEnergyItems.enumerated() {
            menu.insertItem(item, at: infoIndex + 1 + offset)
        }
    }

    private func snapshotInfoText(appCount: Int, isLiveResultEmpty: Bool) -> String {
        guard let lastSignificantEnergyRefresh else {
            return "Heuristic: CPU + helper weighting"
        }

        let age = max(Int(Date().timeIntervalSince(lastSignificantEnergyRefresh).rounded()), 0)
        let appWord = appCount == 1 ? "app" : "apps"
        if isLiveResultEmpty, appCount > 0 {
            return "Heuristic: showing recent snapshot · \(appCount) \(appWord)"
        }

        return "Heuristic: CPU + helper weighting · \(appCount) \(appWord) · \(age)s ago"
    }

    @objc
    private func toggleShowPercentInMenuBar() {
        settings.showPercentInMenuBar.toggle()
        persistSettingsAndRerender()
    }

    @objc
    private func toggleClockStyleInMenuBar() {
        settings.useClockStyleInMenuBar.toggle()
        persistSettingsAndRerender()
    }

    @objc
    private func toggleShowDrainSnapshot() {
        settings.showDrainSnapshot.toggle()
        persistSettingsAndRerender()
        refreshSignificantEnergyMenuAsync()
    }

    private func persistSettingsAndRerender() {
        settingsStore.save(settings: settings)
        refreshSettingsMenuStates()

        if let lastBatteryState {
            handle(state: lastBatteryState)
        } else {
            renderPlaceholderState()
        }
    }

    private func refreshSettingsMenuStates() {
        showPercentMenuItem.state = settings.showPercentInMenuBar ? .on : .off
        clockStyleMenuItem.state = settings.useClockStyleInMenuBar ? .on : .off
        showDrainSnapshotMenuItem.state = settings.showDrainSnapshot ? .on : .off
    }

    nonisolated private static func currentSignificantEnergyApps() -> [SignificantEnergyApp] {
        guard let output = processOutput(
            launchPath: "/bin/ps",
            arguments: ["-axo", "pid=,%cpu=,command="]
        ) else {
            return []
        }

        var statsByApp: [String: AppEnergyStats] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            let parts = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard parts.count == 3, let cpu = Double(parts[1]) else {
                continue
            }

            let command = String(parts[2])
            guard
                let appName = resolvedAppName(for: command),
                cpu > 0.05
            else {
                continue
            }

            var stats = statsByApp[appName] ?? AppEnergyStats()
            stats.totalCPU += cpu
            stats.processCount += 1
            if cpu >= 2 {
                stats.hotProcessCount += 1
            }
            if isHelperProcess(command: command) {
                stats.helperProcessCount += 1
            }
            if cpu > stats.topProcessCPU {
                stats.topProcessCPU = cpu
                stats.topProcessName = summarizedProcessName(from: command)
            }
            statsByApp[appName] = stats
        }

        return statsByApp
            .map { appName, stats in
                SignificantEnergyApp(
                    name: appName,
                    cpuPercent: stats.totalCPU,
                    processCount: stats.processCount,
                    hotProcessCount: stats.hotProcessCount,
                    helperProcessCount: stats.helperProcessCount,
                    topProcessName: stats.topProcessName,
                    topProcessCPU: stats.topProcessCPU
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.name < rhs.name
                }

                return lhs.score > rhs.score
            }
            .prefix(4)
            .map { $0 }
    }

    nonisolated private static func resolvedAppName(for command: String) -> String? {
        if let appRange = command.range(of: ".app") {
            let appPath = String(command[..<appRange.upperBound])
            if appPath.hasPrefix("/") {
                return URL(fileURLWithPath: appPath).lastPathComponent
            }
        }

        let knownApps = [
            "Google Chrome",
            "Cursor",
            "Codex",
            "Claude",
            "Slack",
            "Safari",
            "ChatGPT"
        ]

        for app in knownApps where command.contains(app) {
            return "\(app).app"
        }

        if let helperRange = command.range(of: " Helper") {
            let prefix = String(command[..<helperRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return "\(prefix).app"
            }
        }

        return nil
    }

    nonisolated private static func isHelperProcess(command: String) -> Bool {
        let helperHints = [
            "Helper",
            "Renderer",
            "GPU",
            "Plugin",
            "Utility",
            "extension",
            "Extension"
        ]

        return helperHints.contains { command.contains($0) }
    }

    nonisolated private static func summarizedProcessName(from command: String) -> String {
        let path = command.split(separator: " ").first.map(String.init) ?? command
        let lastPath = URL(fileURLWithPath: path).lastPathComponent
        let cleaned = lastPath.replacingOccurrences(of: ".app", with: "")
        return cleaned.isEmpty ? "process" : cleaned
    }

    nonisolated private static func processOutput(launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private struct BatteryState {
    let isOnBattery: Bool
    let isCharging: Bool
    let batteryPercentage: Int
    let estimatedSecondsRemaining: Double?
    let effectivePowerMilliwatts: Double?
    let historyCoverageMinutes: Int
    let confidenceScore: Double
    let trend: EstimateTrend
    let sparkline: String
    let sparklineSummary: String
    let calibrationBucketCount: Int

    static let placeholder = BatteryState(
        isOnBattery: false,
        isCharging: false,
        batteryPercentage: 0,
        estimatedSecondsRemaining: nil,
        effectivePowerMilliwatts: nil,
        historyCoverageMinutes: 0,
        confidenceScore: 0,
        trend: .insufficient,
        sparkline: "··················",
        sparklineSummary: "Collecting recent power history…",
        calibrationBucketCount: 0
    )

    var shouldShowOverlay: Bool {
        guard isOnBattery, let estimatedSecondsRemaining else {
            return false
        }

        return estimatedSecondsRemaining < 30
    }

    var displayText: String {
        let clampedSeconds = max(estimatedSecondsRemaining ?? 0, 0)

        if clampedSeconds < 10 {
            return String(format: "%.1fs left", clampedSeconds)
        }

        return "\(Int(clampedSeconds.rounded(.up)))s left"
    }

    func menuBarPrimaryText(settings: AppSettings) -> String {
        let percentSuffix = settings.showPercentInMenuBar ? " \(batteryPercentText)" : ""

        if isCharging {
            return batteryPercentText
        }

        guard isOnBattery, let estimatedSecondsRemaining else {
            return batteryPercentText
        }

        return compactDurationText(
            seconds: estimatedSecondsRemaining,
            clockStyle: settings.useClockStyleInMenuBar
        ) + percentSuffix
    }

    var batteryPercentText: String {
        "\(batteryPercentage)%"
    }

    var fillFraction: Double {
        min(max(Double(batteryPercentage) / 100, 0.03), 1.0)
    }

    var fillColor: NSColor {
        if isCharging {
            return NSColor(calibratedRed: 0.18, green: 0.78, blue: 0.35, alpha: 1.0)
        }

        if shouldShowOverlay || batteryPercentage <= 10 {
            return NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.14, alpha: 1.0)
        }

        return NSColor.labelColor
    }

    var confidenceLabel: String {
        switch confidenceScore {
        case ..<0.34: return "Low"
        case ..<0.72: return "Medium"
        default: return "High"
        }
    }

    var estimateLine: String {
        if isCharging {
            return "Charging: \(batteryPercentText)"
        }

        guard isOnBattery, let estimatedSecondsRemaining else {
            return "On AC power: \(batteryPercentText)"
        }

        return "At current draw: \(longDurationText(seconds: estimatedSecondsRemaining)) left"
    }

    var explanationLine: String {
        if isCharging {
            return "Why: external power connected"
        }

        guard isOnBattery, let effectivePowerMilliwatts else {
            return "Why: waiting for battery discharge telemetry"
        }

        return String(
            format: "Why: %.1fW draw • %dm history • %@ confidence",
            effectivePowerMilliwatts / 1000,
            historyCoverageMinutes,
            confidenceLabel.lowercased()
        )
    }

    var confidenceLine: String {
        "Confidence: \(confidenceLabel) • \(historyCoverageMinutes)m history • \(calibrationBucketCount) learned buckets"
    }

    var trendLine: String {
        "Trend: \(trend.description)"
    }

    var learningLine: String {
        if calibrationBucketCount == 0 {
            return "Learning: building calibration from real drain data"
        }

        return "Learning: \(calibrationBucketCount) calibrated power buckets active"
    }

    func tooltipText(settings: AppSettings) -> String {
        if isCharging {
            return "Battery Countdown: charging at \(batteryPercentText)"
        }

        if isOnBattery, let estimatedSecondsRemaining, let effectivePowerMilliwatts {
            return String(
                format: "Battery Countdown: %@ left • %@ • %.1fW • %@ confidence",
                longDurationText(seconds: estimatedSecondsRemaining),
                batteryPercentText,
                effectivePowerMilliwatts / 1000,
                confidenceLabel.lowercased()
            )
        }

        return "Battery Countdown: \(batteryPercentText)"
    }

    var publishBucket: String {
        if isCharging {
            return "charging-\(batteryPercentage)"
        }

        guard isOnBattery, let estimatedSecondsRemaining else {
            return "idle-\(batteryPercentage)"
        }

        if estimatedSecondsRemaining > 15 * 60 {
            let minuteBucket = Int((estimatedSecondsRemaining / 60).rounded(.down))
            return "long-\(batteryPercentage)-\(minuteBucket)"
        }

        if estimatedSecondsRemaining > 60 {
            let fiveSecondBucket = Int((estimatedSecondsRemaining / 5).rounded(.down))
            return "mid-\(batteryPercentage)-\(fiveSecondBucket)"
        }

        let oneSecondBucket = Int(estimatedSecondsRemaining.rounded(.down))
        return "short-\(batteryPercentage)-\(oneSecondBucket)"
    }
}

private enum EstimateTrend {
    case faster
    case slower
    case stable
    case insufficient

    var description: String {
        switch self {
        case .faster: return "draining faster than recent average"
        case .slower: return "draining slower than recent average"
        case .stable: return "stable relative to recent average"
        case .insufficient: return "collecting enough history to classify"
        }
    }
}

private struct SignificantEnergyApp {
    let name: String
    let cpuPercent: Double
    let processCount: Int
    let hotProcessCount: Int
    let helperProcessCount: Int
    let topProcessName: String
    let topProcessCPU: Double

    var score: Double {
        cpuPercent + (Double(hotProcessCount) * 4.5) + (Double(helperProcessCount) * 0.8)
    }

    var displayText: String {
        let cpuText = "\(Int(cpuPercent.rounded()))% CPU"
        let processText = "\(processCount) proc"
        let helperText = helperProcessCount > 0 ? " · \(helperProcessCount) helper" + (helperProcessCount == 1 ? "" : "s") : ""
        let hotText = hotProcessCount > 0 ? " · \(hotProcessCount) hot" : ""
        let topText = topProcessCPU > 0 ? " · top: \(topProcessName) \(Int(topProcessCPU.rounded()))%" : ""
        return "\(name)  \(cpuText) · \(processText)\(helperText)\(hotText)\(topText)"
    }
}

private struct AppEnergyStats {
    var totalCPU: Double = 0
    var processCount: Int = 0
    var hotProcessCount: Int = 0
    var helperProcessCount: Int = 0
    var topProcessName: String = ""
    var topProcessCPU: Double = 0
}

private struct AppSettings: Codable {
    var showPercentInMenuBar = false
    var useClockStyleInMenuBar = false
    var showDrainSnapshot = true
}

@MainActor
private final class StatusBarContentView: NSView {
    private let label = NSTextField(labelWithString: "0%")
    private let batteryView = BatteryGlyphView(frame: NSRect(x: 0, y: 0, width: 28, height: 14))
    private(set) var desiredWidth: CGFloat = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.lineBreakMode = .byClipping
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        batteryView.translatesAutoresizingMaskIntoConstraints = false
        batteryView.setContentCompressionResistancePriority(.required, for: .horizontal)
        batteryView.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(label)
        addSubview(batteryView)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            batteryView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            batteryView.trailingAnchor.constraint(equalTo: trailingAnchor),
            batteryView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.25),
            batteryView.widthAnchor.constraint(equalToConstant: 28),
            batteryView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(state: BatteryState, settings: AppSettings) {
        label.stringValue = state.menuBarPrimaryText(settings: settings)
        label.textColor = state.shouldShowOverlay ? NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.14, alpha: 1.0) : .labelColor
        batteryView.update(
            fillFraction: state.fillFraction,
            fillColor: state.fillColor,
            isCharging: state.isCharging
        )

        let textWidth = ceil(label.intrinsicContentSize.width)
        desiredWidth = max(56, textWidth + 28 + 6 + 14)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: desiredWidth, height: 18)
    }
}

@MainActor
private final class BatteryGlyphView: NSView {
    private var fillFraction: Double = 0
    private var fillColor: NSColor = .labelColor
    private var isCharging = false

    func update(fillFraction: Double, fillColor: NSColor, isCharging: Bool) {
        self.fillFraction = fillFraction
        self.fillColor = fillColor
        self.isCharging = isCharging
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let outlineColor = NSColor.secondaryLabelColor.withAlphaComponent(0.9)
        let bodyRect = NSRect(x: 1.2, y: 2.35, width: 20.9, height: 9.2)
        let capRect = NSRect(x: bodyRect.maxX + 0.9, y: 4.95, width: 1.65, height: 4.0)
        let insetRect = bodyRect.insetBy(dx: 1.45, dy: 1.45)
        let fillWidth = max(CGFloat(fillFraction) * insetRect.width, fillFraction > 0 ? 1.5 : 0)
        let fillRect = NSRect(x: insetRect.minX, y: insetRect.minY, width: min(fillWidth, insetRect.width), height: insetRect.height)

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
        outlineColor.setStroke()
        bodyPath.lineWidth = 0.82
        bodyPath.stroke()

        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 0.55, yRadius: 0.55)
        capPath.lineWidth = 0.72
        capPath.stroke()

        if fillRect.width > 0 {
            let roundedFill = NSBezierPath(roundedRect: fillRect, xRadius: 1.35, yRadius: 1.35)
            fillColor.setFill()
            roundedFill.fill()
        }

        if isCharging {
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 10.5, y: 10.4))
            bolt.line(to: NSPoint(x: 8.9, y: 7.6))
            bolt.line(to: NSPoint(x: 10.7, y: 7.6))
            bolt.line(to: NSPoint(x: 9.6, y: 3.6))
            bolt.line(to: NSPoint(x: 13.0, y: 6.8))
            bolt.line(to: NSPoint(x: 11.1, y: 6.8))
            bolt.close()
            NSColor.black.withAlphaComponent(0.72).setFill()
            bolt.fill()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 14)
    }
}

private func compactDurationText(seconds: Double, clockStyle: Bool) -> String {
    let clampedSeconds = max(seconds, 0)
    if clampedSeconds < 60 {
        return "\(Int(max(clampedSeconds.rounded(.up), 1)))s"
    }

    let totalMinutes = Int((clampedSeconds / 60).rounded(.toNearestOrAwayFromZero))
    if clockStyle {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return "0:\(String(format: "%02d", minutes))"
    }

    if totalMinutes < 600 {
        return "\(totalMinutes)m"
    }

    let hours = Int((Double(totalMinutes) / 60).rounded(.toNearestOrAwayFromZero))
    return "\(hours)h"
}

private func longDurationText(seconds: Double) -> String {
    let clampedSeconds = max(seconds, 0)
    if clampedSeconds < 60 {
        return "\(Int(max(clampedSeconds.rounded(.up), 1)))s"
    }

    let totalMinutes = Int((clampedSeconds / 60).rounded(.down))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

@MainActor
private final class BatteryMonitor {
    var onUpdate: ((BatteryState) -> Void)?

    private let estimatorStore = EstimatorStore()
    private var pollTimer: Timer?
    private var sampleHistory: [BatterySample] = []
    private var smoothedPowerMilliwatts: Double?
    private var calibrationModel = CalibrationModel()
    private var activeSegmentID: String?
    private var lastCapturedSampleDate: Date?
    private var lastPersistedDate = Date.distantPast
    private var lastPublishedBucket: String?
    private var displayedSecondsRemaining: Double?
    private var lastDisplayedEstimateDate: Date?

    init() {
        let persistedState = estimatorStore.load()
        sampleHistory = persistedState.samples.sorted { $0.timestamp < $1.timestamp }
        calibrationModel = persistedState.calibrationModel
        activeSegmentID = persistedState.activeSegmentID
        lastCapturedSampleDate = sampleHistory.last?.timestamp
    }

    func start() {
        publishCurrentState()

        pollTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )

        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        persistState(force: true)
    }

    @objc
    private func handleTimerTick() {
        publishCurrentState()
    }

    private func publishCurrentState() {
        let telemetry = Self.currentBatteryTelemetry()
        let now = Date()

        guard let telemetry, telemetry.isOnBattery else {
            pruneHistory(relativeTo: now)
            smoothedPowerMilliwatts = nil
            activeSegmentID = nil
            displayedSecondsRemaining = nil
            lastDisplayedEstimateDate = nil
            publishIfNeeded(BatteryState(
                isOnBattery: false,
                isCharging: telemetry?.isCharging ?? false,
                batteryPercentage: telemetry?.batteryPercentage ?? 0,
                estimatedSecondsRemaining: nil,
                effectivePowerMilliwatts: nil,
                historyCoverageMinutes: 0,
                confidenceScore: 0,
                trend: .insufficient,
                sparkline: "··················",
                sparklineSummary: "Recent graph resumes once battery discharge starts",
                calibrationBucketCount: calibrationModel.activeBucketCount
            ))
            persistState(force: true)
            return
        }
        let segmentID = currentSegmentID(for: telemetry, now: now)
        pruneHistory(relativeTo: now)

        let fusedPower = Self.fusedPowerEstimate(
            telemetry: telemetry,
            history: sampleHistory,
            calibrationFactor: calibrationModel.factor(
                forPredictedPower: telemetry.instantaneousPowerMilliwatts,
                batteryPercentage: telemetry.batteryPercentage
            ),
            segmentID: segmentID,
            now: now
        )
        let learnedFactor = calibrationModel.factor(
            forPredictedPower: fusedPower,
            batteryPercentage: telemetry.batteryPercentage
        )
        let sanePower = max(fusedPower * learnedFactor, 500)

        if let smoothedPowerMilliwatts {
            self.smoothedPowerMilliwatts = (smoothedPowerMilliwatts * 0.84) + (sanePower * 0.16)
        } else {
            self.smoothedPowerMilliwatts = sanePower
        }

        let effectivePower = max(self.smoothedPowerMilliwatts ?? sanePower, 500)
        let rawEstimatedSecondsRemaining = (telemetry.remainingEnergyMilliwattHours / effectivePower) * 3600

        let currentSample = BatterySample(
            timestamp: now,
            segmentID: segmentID,
            batteryPercentage: telemetry.batteryPercentage,
            remainingEnergyMilliwattHours: telemetry.remainingEnergyMilliwattHours,
            instantaneousPowerMilliwatts: telemetry.instantaneousPowerMilliwatts,
            predictedPowerMilliwatts: effectivePower
        )
        capture(sample: currentSample, now: now)
        refineCalibration(with: currentSample, now: now)
        persistState(force: false)

        let recentSamples = recentSamplesIncludingCurrent(currentSample, now: now)
        let historyCoverageMinutes = historyCoverageMinutes(for: segmentID, now: now)
        let observedWindowCount = Self.availableObservedWindowCount(
            history: sampleHistory,
            segmentID: segmentID,
            currentEnergyMilliwattHours: telemetry.remainingEnergyMilliwattHours,
            now: now
        )
        let trend = Self.estimateTrend(
            history: sampleHistory,
            segmentID: segmentID,
            currentEnergyMilliwattHours: telemetry.remainingEnergyMilliwattHours,
            now: now
        )
        let sparkline = Self.sparkline(from: recentSamples, currentPowerMilliwatts: effectivePower, now: now)
        let sparklineSummary = Self.sparklineSummary(from: recentSamples, currentPowerMilliwatts: effectivePower, now: now)
        let calibrationBucketCount = calibrationModel.activeBucketCount
        let confidenceScore = Self.confidenceScore(
            historyCoverageMinutes: historyCoverageMinutes,
            observedWindowCount: observedWindowCount,
            calibrationBucketCount: calibrationBucketCount,
            instantaneousPowerMilliwatts: telemetry.instantaneousPowerMilliwatts,
            effectivePowerMilliwatts: effectivePower
        )
        let estimatedSecondsRemaining = stabilizedDisplayEstimate(
            rawEstimateSeconds: rawEstimatedSecondsRemaining,
            confidenceScore: confidenceScore,
            historyCoverageMinutes: historyCoverageMinutes,
            now: now
        )

        publishIfNeeded(
            BatteryState(
                isOnBattery: true,
                isCharging: telemetry.isCharging,
                batteryPercentage: telemetry.batteryPercentage,
                estimatedSecondsRemaining: estimatedSecondsRemaining,
                effectivePowerMilliwatts: effectivePower,
                historyCoverageMinutes: historyCoverageMinutes,
                confidenceScore: confidenceScore,
                trend: trend,
                sparkline: sparkline,
                sparklineSummary: sparklineSummary,
                calibrationBucketCount: calibrationBucketCount
            )
        )
    }

    private func publishIfNeeded(_ state: BatteryState) {
        let bucket = state.publishBucket
        guard bucket != lastPublishedBucket else {
            return
        }

        lastPublishedBucket = bucket
        onUpdate?(state)
    }

    private static func currentBatteryTelemetry() -> BatteryTelemetry? {
        let matchingService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard matchingService != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(matchingService) }

        var propertiesReference: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            matchingService,
            &propertiesReference,
            kCFAllocatorDefault,
            0
        )

        guard
            result == KERN_SUCCESS,
            let properties = propertiesReference?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        let externalConnected = (properties["ExternalConnected"] as? Bool) ?? false
        let isCharging = (properties["IsCharging"] as? Bool) ?? false
        let batteryPercentage = Int((numberValue(for: "CurrentCapacity", in: properties) ?? 0).rounded())
        let rawCurrentCapacity = numberValue(for: "AppleRawCurrentCapacity", in: properties)
            ?? numberValue(for: "CurrentCapacity", in: properties)
        let reserveCapacity = numberValue(for: "PackReserve", in: properties) ?? 0
        let voltageMilliVolts = numberValue(for: "AppleRawBatteryVoltage", in: properties)
            ?? numberValue(for: "Voltage", in: properties)
        let instantAmperage = signedNumberValue(for: "InstantAmperage", in: properties)
            ?? signedNumberValue(for: "Amperage", in: properties)
        let appleSecondsRemaining = appleSecondsRemaining()
        let powerTelemetry = properties["PowerTelemetryData"] as? [String: Any]

        guard let rawCurrentCapacity, let instantAmperage, let voltageMilliVolts else {
            return nil
        }

        let remainingChargeMilliampHours = max(rawCurrentCapacity - reserveCapacity, 0)
        let remainingEnergyMilliwattHours = max((remainingChargeMilliampHours * voltageMilliVolts) / 1000, 0)
        let amperagePowerMilliwatts = max((abs(instantAmperage) * voltageMilliVolts) / 1000, 1)
        let telemetryPowerMilliwatts = positiveNumberValue(for: "SystemLoad", in: powerTelemetry)
            ?? positiveNumberValue(for: "BatteryPower", in: powerTelemetry)
        let instantaneousPowerMilliwatts = telemetryPowerMilliwatts.map { max($0, 1) } ?? amperagePowerMilliwatts

        return BatteryTelemetry(
            isOnBattery: !externalConnected && !isCharging,
            isCharging: isCharging,
            batteryPercentage: min(max(batteryPercentage, 0), 100),
            remainingEnergyMilliwattHours: remainingEnergyMilliwattHours,
            instantaneousPowerMilliwatts: instantaneousPowerMilliwatts,
            appleSecondsRemaining: appleSecondsRemaining
        )
    }

    private static func fusedPowerEstimate(
        telemetry: BatteryTelemetry,
        history: [BatterySample],
        calibrationFactor: Double,
        segmentID: String,
        now: Date
    ) -> Double {
        var candidates: [WeightedPower] = [
            WeightedPower(value: telemetry.instantaneousPowerMilliwatts, weight: 0.34)
        ]

        let windows: [(TimeInterval, Double)] = [
            (30, 0.18),
            (90, 0.24),
            (300, 0.18),
            (900, 0.10)
        ]

        for (window, weight) in windows {
            if let observedPower = observedPowerMilliwatts(
                history: history,
                segmentID: segmentID,
                currentEnergyMilliwattHours: telemetry.remainingEnergyMilliwattHours,
                now: now,
                minimumAge: window
            ) {
                candidates.append(WeightedPower(value: observedPower, weight: weight))
            }
        }

        if let appleSecondsRemaining = telemetry.appleSecondsRemaining, appleSecondsRemaining > 0 {
            let applePower = telemetry.remainingEnergyMilliwattHours / (appleSecondsRemaining / 3600)
            candidates.append(WeightedPower(value: applePower, weight: 0.08))
        }

        let learnedPower = telemetry.instantaneousPowerMilliwatts * calibrationFactor
        candidates.append(WeightedPower(value: learnedPower, weight: 0.12))

        let median = weightedMedianPower(candidates) ?? telemetry.instantaneousPowerMilliwatts
        let filteredCandidates = candidates.filter { candidate in
            candidate.value >= median * 0.45 && candidate.value <= median * 2.2
        }
        let usableCandidates = filteredCandidates.isEmpty ? candidates : filteredCandidates

        let weightedSum = usableCandidates.reduce(0.0) { $0 + ($1.value * $1.weight) }
        let totalWeight = usableCandidates.reduce(0.0) { $0 + $1.weight }

        guard totalWeight > 0 else {
            return telemetry.instantaneousPowerMilliwatts
        }

        return weightedSum / totalWeight
    }

    private static func observedPowerMilliwatts(
        history: [BatterySample],
        segmentID: String,
        currentEnergyMilliwattHours: Double,
        now: Date,
        minimumAge: TimeInterval
    ) -> Double? {
        let candidates = history.filter { sample in
            sample.segmentID == segmentID &&
            now.timeIntervalSince(sample.timestamp) >= minimumAge &&
            now.timeIntervalSince(sample.timestamp) <= minimumAge * 2.5 &&
            sample.remainingEnergyMilliwattHours > currentEnergyMilliwattHours
        }
        guard let sample = candidates.min(by: {
            abs(now.timeIntervalSince($0.timestamp) - minimumAge) < abs(now.timeIntervalSince($1.timestamp) - minimumAge)
        }) else {
            return nil
        }

        let hoursElapsed = now.timeIntervalSince(sample.timestamp) / 3600
        guard hoursElapsed > 0 else {
            return nil
        }

        let energyDelta = sample.remainingEnergyMilliwattHours - currentEnergyMilliwattHours
        guard energyDelta > 0 else {
            return nil
        }

        return energyDelta / hoursElapsed
    }

    private func currentSegmentID(for telemetry: BatteryTelemetry, now: Date) -> String {
        if let activeSegmentID,
           let lastSample = sampleHistory.last,
           lastSample.segmentID == activeSegmentID,
           now.timeIntervalSince(lastSample.timestamp) < 300,
           lastSample.remainingEnergyMilliwattHours + 120 >= telemetry.remainingEnergyMilliwattHours {
            return activeSegmentID
        }

        if let lastSample = sampleHistory.last,
           now.timeIntervalSince(lastSample.timestamp) < 300,
           lastSample.remainingEnergyMilliwattHours + 120 >= telemetry.remainingEnergyMilliwattHours {
            activeSegmentID = lastSample.segmentID
            return lastSample.segmentID
        }

        let newSegmentID = UUID().uuidString
        activeSegmentID = newSegmentID
        return newSegmentID
    }

    private func capture(sample: BatterySample, now: Date) {
        let shouldCapture: Bool
        if let lastCapturedSampleDate {
            shouldCapture = now.timeIntervalSince(lastCapturedSampleDate) >= 15
        } else {
            shouldCapture = true
        }

        guard shouldCapture else {
            return
        }

        sampleHistory.append(sample)
        lastCapturedSampleDate = now
        pruneHistory(relativeTo: now)
    }

    private func pruneHistory(relativeTo now: Date) {
        sampleHistory.removeAll { now.timeIntervalSince($0.timestamp) > 43200 }
        if sampleHistory.count > 3200 {
            sampleHistory.removeFirst(sampleHistory.count - 3200)
        }
    }

    private func refineCalibration(with currentSample: BatterySample, now: Date) {
        let learningWindows: [(TimeInterval, Double)] = [
            (120, 0.05),
            (300, 0.06),
            (900, 0.08),
            (1800, 0.10)
        ]

        for (window, alpha) in learningWindows {
            guard let priorSample = sampleClosestTo(
                age: window,
                segmentID: currentSample.segmentID,
                now: now
            ) else {
                continue
            }

            let elapsedHours = now.timeIntervalSince(priorSample.timestamp) / 3600
            guard elapsedHours > 0 else {
                continue
            }

            let realizedEnergyDelta = priorSample.remainingEnergyMilliwattHours - currentSample.remainingEnergyMilliwattHours
            guard realizedEnergyDelta > 0, priorSample.predictedPowerMilliwatts > 0 else {
                continue
            }

            let realizedPower = realizedEnergyDelta / elapsedHours
            let ratio = min(max(realizedPower / priorSample.predictedPowerMilliwatts, 0.65), 1.45)
            calibrationModel.update(
                forPredictedPower: priorSample.predictedPowerMilliwatts,
                batteryPercentage: priorSample.batteryPercentage,
                observedRatio: ratio,
                alpha: alpha
            )
        }
    }

    private func sampleClosestTo(age targetAge: TimeInterval, segmentID: String, now: Date) -> BatterySample? {
        let candidates = sampleHistory.filter { sample in
            sample.segmentID == segmentID &&
            now.timeIntervalSince(sample.timestamp) >= targetAge &&
            now.timeIntervalSince(sample.timestamp) <= targetAge * 2.2
        }

        return candidates.min(by: {
            abs(now.timeIntervalSince($0.timestamp) - targetAge) < abs(now.timeIntervalSince($1.timestamp) - targetAge)
        })
    }

    private func stabilizedDisplayEstimate(
        rawEstimateSeconds: Double,
        confidenceScore: Double,
        historyCoverageMinutes: Int,
        now: Date
    ) -> Double {
        let clampedRaw = max(rawEstimateSeconds, 1)

        guard
            let displayedSecondsRemaining,
            let lastDisplayedEstimateDate
        else {
            self.displayedSecondsRemaining = clampedRaw
            self.lastDisplayedEstimateDate = now
            return clampedRaw
        }

        let elapsed = max(now.timeIntervalSince(lastDisplayedEstimateDate), 0.25)
        let stabilized: Double

        if clampedRaw > displayedSecondsRemaining {
            var increaseBlendPerSecond = historyCoverageMinutes >= 20 ? 0.02 : 0.01
            increaseBlendPerSecond += confidenceScore * 0.01
            if clampedRaw > displayedSecondsRemaining * 1.6 {
                increaseBlendPerSecond *= 0.45
            }

            let blend = min(0.12, increaseBlendPerSecond * elapsed)
            stabilized = displayedSecondsRemaining + ((clampedRaw - displayedSecondsRemaining) * blend)
        } else {
            let decreaseBlendPerSecond = 0.08 + (confidenceScore * 0.04)
            let blend = min(0.35, decreaseBlendPerSecond * elapsed)
            stabilized = displayedSecondsRemaining + ((clampedRaw - displayedSecondsRemaining) * blend)
        }

        self.displayedSecondsRemaining = max(stabilized, 1)
        self.lastDisplayedEstimateDate = now
        return self.displayedSecondsRemaining ?? clampedRaw
    }

    private func historyCoverageMinutes(for segmentID: String, now: Date) -> Int {
        let segmentSamples = sampleHistory.filter { $0.segmentID == segmentID }
        guard let firstSample = segmentSamples.first else {
            return 0
        }

        return max(Int((now.timeIntervalSince(firstSample.timestamp) / 60).rounded(.down)), 0)
    }

    private func recentSamplesIncludingCurrent(_ currentSample: BatterySample, now: Date) -> [BatterySample] {
        let recent = sampleHistory.filter {
            $0.segmentID == currentSample.segmentID &&
            now.timeIntervalSince($0.timestamp) <= 900
        }

        if let last = recent.last, abs(last.timestamp.timeIntervalSince(currentSample.timestamp)) < 1 {
            return recent
        }

        return recent + [currentSample]
    }

    private func persistState(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersistedDate) >= 45 else {
            return
        }

        estimatorStore.save(
            state: PersistedEstimatorState(
                samples: sampleHistory,
                calibrationModel: calibrationModel,
                activeSegmentID: activeSegmentID
            )
        )
        lastPersistedDate = now
    }

    private static func weightedMedianPower(_ candidates: [WeightedPower]) -> Double? {
        let sorted = candidates.sorted { $0.value < $1.value }
        let totalWeight = sorted.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return nil
        }

        var runningWeight = 0.0
        for candidate in sorted {
            runningWeight += candidate.weight
            if runningWeight >= totalWeight / 2 {
                return candidate.value
            }
        }

        return sorted.last?.value
    }

    private static func availableObservedWindowCount(
        history: [BatterySample],
        segmentID: String,
        currentEnergyMilliwattHours: Double,
        now: Date
    ) -> Int {
        let windows: [TimeInterval] = [30, 90, 300, 900, 1800]
        return windows.reduce(into: 0) { count, window in
            if observedPowerMilliwatts(
                history: history,
                segmentID: segmentID,
                currentEnergyMilliwattHours: currentEnergyMilliwattHours,
                now: now,
                minimumAge: window
            ) != nil {
                count += 1
            }
        }
    }

    private static func estimateTrend(
        history: [BatterySample],
        segmentID: String,
        currentEnergyMilliwattHours: Double,
        now: Date
    ) -> EstimateTrend {
        guard
            let shortWindow = observedPowerMilliwatts(
                history: history,
                segmentID: segmentID,
                currentEnergyMilliwattHours: currentEnergyMilliwattHours,
                now: now,
                minimumAge: 90
            ),
            let longWindow = observedPowerMilliwatts(
                history: history,
                segmentID: segmentID,
                currentEnergyMilliwattHours: currentEnergyMilliwattHours,
                now: now,
                minimumAge: 900
            ),
            longWindow > 0
        else {
            return .insufficient
        }

        let ratio = shortWindow / longWindow
        if ratio > 1.12 {
            return .faster
        }
        if ratio < 0.88 {
            return .slower
        }
        return .stable
    }

    private static func confidenceScore(
        historyCoverageMinutes: Int,
        observedWindowCount: Int,
        calibrationBucketCount: Int,
        instantaneousPowerMilliwatts: Double,
        effectivePowerMilliwatts: Double
    ) -> Double {
        let coverage = min(Double(historyCoverageMinutes) / 30, 1) * 0.36
        let observed = min(Double(observedWindowCount) / 5, 1) * 0.34
        let learned = min(Double(calibrationBucketCount) / 10, 1) * 0.18

        let divergence = abs(instantaneousPowerMilliwatts - effectivePowerMilliwatts) / max(effectivePowerMilliwatts, 1)
        let stability = max(0, 1 - min(divergence, 1)) * 0.12

        return min(max(coverage + observed + learned + stability, 0), 1)
    }

    private static func sparkline(
        from samples: [BatterySample],
        currentPowerMilliwatts: Double,
        now: Date
    ) -> String {
        let symbols = Array("▁▂▃▄▅▆▇█")
        let bucketCount = 18
        let window: TimeInterval = 900
        let bucketSize = window / Double(bucketCount)

        var values: [Double] = []
        var lastKnown = currentPowerMilliwatts

        for index in 0..<bucketCount {
            let bucketEnd = now.addingTimeInterval(-window + (Double(index + 1) * bucketSize))
            let bucketStart = bucketEnd.addingTimeInterval(-bucketSize)
            let bucketSamples = samples.filter { sample in
                sample.timestamp >= bucketStart && sample.timestamp < bucketEnd
            }

            if !bucketSamples.isEmpty {
                let average = bucketSamples.reduce(0.0) { $0 + $1.predictedPowerMilliwatts } / Double(bucketSamples.count)
                lastKnown = average
            }

            values.append(lastKnown)
        }

        guard
            let minValue = values.min(),
            let maxValue = values.max()
        else {
            return "··················"
        }

        if abs(maxValue - minValue) < 250 {
            return String(repeating: "▄", count: bucketCount)
        }

        return String(values.map { value in
            let normalized = (value - minValue) / max(maxValue - minValue, 1)
            let index = min(symbols.count - 1, max(0, Int((normalized * Double(symbols.count - 1)).rounded())))
            return symbols[index]
        })
    }

    private static func sparklineSummary(
        from samples: [BatterySample],
        currentPowerMilliwatts: Double,
        now: Date
    ) -> String {
        let recent = samples.filter { now.timeIntervalSince($0.timestamp) <= 900 }
        let powers = recent.map(\.predictedPowerMilliwatts) + [currentPowerMilliwatts]
        guard !powers.isEmpty else {
            return "Collecting recent power history…"
        }

        let average = powers.reduce(0.0, +) / Double(powers.count)
        let peak = powers.max() ?? average
        let floor = powers.min() ?? average

        return String(
            format: "Last 15m: %.1fW avg • %.1fW now • %.1fW peak • %.1fW low",
            average / 1000,
            currentPowerMilliwatts / 1000,
            peak / 1000,
            floor / 1000
        )
    }

    private static func appleSecondsRemaining() -> Double? {
        let estimate = IOPSGetTimeRemainingEstimate()
        let invalidEstimates = [
            kIOPSTimeRemainingUnknown,
            kIOPSTimeRemainingUnlimited
        ]

        guard !invalidEstimates.contains(estimate), estimate.isFinite, estimate > 0 else {
            return nil
        }

        return estimate
    }

    private static func numberValue(for key: String, in properties: [String: Any]) -> Double? {
        if let number = properties[key] as? NSNumber {
            return number.doubleValue
        }

        if let value = properties[key] as? Double {
            return value
        }

        if let value = properties[key] as? Int {
            return Double(value)
        }

        return nil
    }

    private static func positiveNumberValue(for key: String, in properties: [String: Any]?) -> Double? {
        guard
            let properties,
            let value = numberValue(for: key, in: properties),
            value > 0
        else {
            return nil
        }

        return value
    }

    private static func signedNumberValue(for key: String, in properties: [String: Any]) -> Double? {
        if let number = properties[key] as? NSNumber {
            return Double(number.int64Value)
        }

        if let value = properties[key] as? Int64 {
            return Double(value)
        }

        if let value = properties[key] as? Int {
            return Double(value)
        }

        return nil
    }
}

private struct BatteryTelemetry {
    let isOnBattery: Bool
    let isCharging: Bool
    let batteryPercentage: Int
    let remainingEnergyMilliwattHours: Double
    let instantaneousPowerMilliwatts: Double
    let appleSecondsRemaining: Double?
}

private struct BatterySample: Codable {
    let timestamp: Date
    let segmentID: String
    let batteryPercentage: Int
    let remainingEnergyMilliwattHours: Double
    let instantaneousPowerMilliwatts: Double
    let predictedPowerMilliwatts: Double
}

private struct WeightedPower {
    let value: Double
    let weight: Double
}

private struct PersistedEstimatorState {
    var samples: [BatterySample] = []
    var calibrationModel = CalibrationModel()
    var activeSegmentID: String?
}

private struct CalibrationModel {
    private var entries: [CalibrationKey: CalibrationEntry] = [:]

    init() {}

    init(entries persistedEntries: [PersistedCalibrationEntry]) {
        self.entries = Dictionary(
            uniqueKeysWithValues: persistedEntries.map { entry in
                (
                    CalibrationKey(powerBucket: entry.powerBucket, batteryBand: entry.batteryBand),
                    CalibrationEntry(factor: entry.factor, weight: entry.weight)
                )
            }
        )
    }

    var persistedEntries: [PersistedCalibrationEntry] {
        entries.map { key, entry in
            PersistedCalibrationEntry(
                powerBucket: key.powerBucket,
                batteryBand: key.batteryBand,
                factor: entry.factor,
                weight: entry.weight
            )
        }
    }

    var activeBucketCount: Int {
        entries.values.filter { $0.weight >= 0.5 }.count
    }

    func factor(forPredictedPower powerMilliwatts: Double, batteryPercentage: Int) -> Double {
        let key = CalibrationKey(
            powerBucket: Self.powerBucket(for: powerMilliwatts),
            batteryBand: Self.batteryBand(for: batteryPercentage)
        )

        if let entry = entries[key] {
            let confidence = min(entry.weight / 10, 1)
            return 1 + ((entry.factor - 1) * confidence)
        }

        let bucketEntries = entries.filter { $0.key.powerBucket == key.powerBucket }.map(\.value)
        guard !bucketEntries.isEmpty else {
            return 1
        }

        let weightedFactor = bucketEntries.reduce(0.0) { $0 + ($1.factor * $1.weight) }
        let totalWeight = bucketEntries.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return 1
        }

        let averageFactor = weightedFactor / totalWeight
        let confidence = min(totalWeight / 18, 1)
        return 1 + ((averageFactor - 1) * confidence)
    }

    mutating func update(
        forPredictedPower powerMilliwatts: Double,
        batteryPercentage: Int,
        observedRatio: Double,
        alpha: Double
    ) {
        let key = CalibrationKey(
            powerBucket: Self.powerBucket(for: powerMilliwatts),
            batteryBand: Self.batteryBand(for: batteryPercentage)
        )

        var entry = entries[key] ?? CalibrationEntry(factor: 1, weight: 0)
        entry.factor = (entry.factor * (1 - alpha)) + (observedRatio * alpha)
        entry.weight = min(entry.weight + max(alpha * 6, 0.2), 32)
        entries[key] = entry
    }

    private static func powerBucket(for powerMilliwatts: Double) -> Int {
        switch powerMilliwatts {
        case ..<5000: return 0
        case ..<8000: return 1
        case ..<11000: return 2
        case ..<15000: return 3
        case ..<20000: return 4
        default: return 5
        }
    }

    private static func batteryBand(for percentage: Int) -> Int {
        min(max(percentage / 20, 0), 4)
    }
}

private struct CalibrationKey: Hashable {
    let powerBucket: Int
    let batteryBand: Int
}

private struct CalibrationEntry {
    var factor: Double
    var weight: Double
}

private final class EstimatorStore {
    private let fileManager = FileManager.default

    func load() -> PersistedEstimatorState {
        guard
            let fileURL = storageURL(),
            let data = try? Data(contentsOf: fileURL),
            let persisted = try? configuredDecoder().decode(PersistedEstimatorBlob.self, from: data)
        else {
            return PersistedEstimatorState()
        }

        return PersistedEstimatorState(
            samples: persisted.samples,
            calibrationModel: CalibrationModel(entries: persisted.calibrationEntries),
            activeSegmentID: persisted.activeSegmentID
        )
    }

    func save(state: PersistedEstimatorState) {
        guard let fileURL = storageURL() else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let blob = PersistedEstimatorBlob(
            samples: state.samples,
            calibrationEntries: state.calibrationModel.persistedEntries,
            activeSegmentID: state.activeSegmentID
        )

        do {
            let data = try encoder.encode(blob)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            fputs("BatteryCountdown persistence save failed: \(error)\n", stderr)
        }
    }

    private func storageURL() -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryURL = appSupportURL.appendingPathComponent("BatteryCountdown", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        return directoryURL.appendingPathComponent("estimator_state.json")
    }

    private func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class SettingsStore {
    private let fileManager = FileManager.default

    func load() -> AppSettings {
        guard
            let fileURL = storageURL(),
            let data = try? Data(contentsOf: fileURL),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }

        return settings
    }

    func save(settings: AppSettings) {
        guard let fileURL = storageURL() else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("BatteryCountdown settings save failed: \(error)\n", stderr)
        }
    }

    private func storageURL() -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryURL = appSupportURL.appendingPathComponent("BatteryCountdown", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        return directoryURL.appendingPathComponent("settings.json")
    }
}

private struct PersistedEstimatorBlob: Codable {
    let samples: [BatterySample]
    let calibrationEntries: [PersistedCalibrationEntry]
    let activeSegmentID: String?
}

private struct PersistedCalibrationEntry: Codable {
    let powerBucket: Int
    let batteryBand: Int
    let factor: Double
    let weight: Double
}

@MainActor
private final class OverlayController {
    private let window: OverlayWindow
    private let label = NSTextField(labelWithString: "")

    init() {
        window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true

        let contentView = CountdownView(frame: window.contentView?.bounds ?? .zero)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        label.alignment = .center
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        label.textColor = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.0, alpha: 1.0)
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    func show(text: String) {
        label.stringValue = text
        positionWindow()

        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        if window.isVisible {
            window.orderOut(nil)
        }
    }

    private func positionWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let x = visibleFrame.maxX - windowSize.width - 22
        let y = visibleFrame.minY + 22
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CountdownView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.0, alpha: 0.85).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
