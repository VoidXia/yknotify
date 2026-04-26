import Cocoa
import SwiftUI
import UserNotifications
import ServiceManagement

let logPredicate = """
(processImagePath == "/kernel" AND senderImagePath ENDSWITH "IOHIDFamily") \
OR (subsystem CONTAINS "CryptoTokenKit")
"""

// MARK: - Models

struct LogEntry {
    let processImagePath: String
    let senderImagePath: String
    let subsystem: String
    let eventMessage: String
}

struct TouchEvent: Codable, Identifiable {
    let id: UUID
    let type: String
    let timestamp: Date

    init(type: String) {
        self.id = UUID()
        self.type = type
        self.timestamp = Date()
    }
}

// MARK: - YKNotify

class YKNotify: NSObject, ObservableObject {
    @Published var isTouchNeeded = false
    @Published var activeOperation: String?
    @Published var history: [TouchEvent] = []

    private var statusItem: NSStatusItem!
    private var contextMenu: NSMenu!
    private var preferencesWindow: NSWindow?
    private var pulseTimer: Timer?
    private var safetyTimer: Timer?
    private var process: Process?
    private var isPulsing = false
    private var isSSHRunning = false

    private var fido2Needed = false
    private var openPGPNeeded = false
    private var yubiKeyClients: Set<String> = []
    private var lineBuffer = Data()

    override init() {
        super.init()
        registerDefaults()
        loadHistory()
        pruneHistory()
        requestNotificationPermission()
        setupContextMenu()
        setupStatusItem()
        startLogStream()
        syncLoginItem()
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "showNotifications": true,
            "playSound": false,
            "watchFIDO2": true,
            "watchOpenPGP": true,
            "safetyTimeout": 30.0,
            "historyRetentionDays": 7,
            "startAtLogin": false
        ])
    }

    // MARK: - SF Symbols

    private func sfSymbol(_ name: String, size: CGFloat = 14) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "YubiKey")
        return image?.withSymbolConfiguration(config)
    }

    private func makeAlertIcon() -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()

            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(.init(hierarchicalColor: .white))
            if let sym = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let origin = NSPoint(
                    x: (rect.width - sym.size.width) / 2,
                    y: (rect.height - sym.size.height) / 2
                )
                sym.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = sfSymbol("key")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        let wantsMenu = event.type == .rightMouseUp ||
            (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if wantsMenu {
            statusItem.menu = contextMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else {
            triggerSSHRefresh()
        }
    }

    // MARK: - SSH refresh

    private func triggerSSHRefresh() {
        guard !isSSHRunning else { return }
        isSSHRunning = true
        flashStatusItem()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "git@github.com"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.isSSHRunning = false }
        }

        do {
            try proc.run()
        } catch {
            isSSHRunning = false
        }
    }

    private func flashStatusItem() {
        guard let button = statusItem.button, !isPulsing else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            button.animator().alphaValue = 0.35
        }, completionHandler: { [weak self] in
            guard let self, !self.isPulsing else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.statusItem.button?.animator().alphaValue = 1.0
            }
        })
    }

    // MARK: - Context menu

    private func setupContextMenu() {
        contextMenu = NSMenu()
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferencesAction), keyEquivalent: ",")
        prefsItem.target = self
        contextMenu.addItem(prefsItem)
        contextMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit yknotify", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    // MARK: - Preferences window

    @objc private func showPreferencesAction() { showPreferences() }

    func showPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.contentView = NSHostingView(rootView: PreferencesView(controller: self))
            window.title = "yknotify Preferences"
            window.center()
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Log stream

    private func startLogStream() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = ["stream", "--level", "debug", "--style", "ndjson",
                          "--predicate", logPredicate]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.startLogStream()
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.processData(data)
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startLogStream()
            }
        }
    }

    // MARK: - Log parsing

    private func processData(_ data: Data) {
        lineBuffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer[lineBuffer.startIndex..<idx]
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: idx)...])

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let pip = json["processImagePath"] as? String,
                  let sip = json["senderImagePath"] as? String,
                  let sub = json["subsystem"] as? String,
                  let msg = json["eventMessage"] as? String else {
                continue
            }

            let entry = LogEntry(processImagePath: pip, senderImagePath: sip,
                                 subsystem: sub, eventMessage: msg)
            DispatchQueue.main.async { [weak self] in
                self?.handleEntry(entry)
            }
        }
    }

    // MARK: - Detection

    private func handleEntry(_ entry: LogEntry) {
        let wasFido2 = fido2Needed
        let wasOpenPGP = openPGPNeeded
        let wasTouchNeeded = wasFido2 || wasOpenPGP
        var fido2Completed = false
        var openPGPCompleted = false

        if entry.processImagePath == "/kernel",
           entry.senderImagePath.hasSuffix("IOHIDFamily") {
            if UserDefaults.standard.bool(forKey: "watchFIDO2") {
                handleFIDO2(entry.eventMessage)
                fido2Completed = wasFido2 && !fido2Needed
            } else {
                fido2Needed = false
            }
        } else if entry.processImagePath.hasSuffix("usbsmartcardreaderd"),
                  entry.subsystem.hasSuffix("CryptoTokenKit") {
            if UserDefaults.standard.bool(forKey: "watchOpenPGP") {
                openPGPNeeded = entry.eventMessage == "Time extension received"
                openPGPCompleted = wasOpenPGP && !openPGPNeeded
            } else {
                openPGPNeeded = false
            }
        }

        // Record only actual completions (not monitoring-disable clears)
        if fido2Completed { recordTouch(type: "FIDO2") }
        if openPGPCompleted { recordTouch(type: "OpenPGP") }

        // Update displayed operation
        if fido2Needed { activeOperation = "FIDO2" }
        else if openPGPNeeded { activeOperation = "OpenPGP" }
        else { activeOperation = nil }

        let nowTouchNeeded = fido2Needed || openPGPNeeded
        if nowTouchNeeded != wasTouchNeeded {
            if nowTouchNeeded {
                isTouchNeeded = true
                startPulsing()
                sendNotification(operation: activeOperation ?? "")
            } else {
                isTouchNeeded = false
                stopPulsing()
                dismissNotification()
            }
        } else if nowTouchNeeded, activeOperation != (wasFido2 ? "FIDO2" : wasOpenPGP ? "OpenPGP" : nil) {
            // Operation changed while still needing touch — update notification
            if let op = activeOperation {
                sendNotification(operation: op)
            }
        }
    }

    private func handleFIDO2(_ msg: String) {
        if msg.contains("AppleUserUSBHostHIDDevice:"),
           msg.contains("open by IOHIDLibUserClient:") {
            let parts = msg.components(separatedBy: " open by ")
            if parts.count == 2 {
                let clientID = parts[1].components(separatedBy: " ")[0]
                yubiKeyClients.insert(clientID)
            }
        }

        if msg.hasSuffix("startQueue") {
            let clientID = msg.components(separatedBy: " ")[0]
            fido2Needed = yubiKeyClients.contains(clientID)
        } else if msg.hasSuffix("stopQueue") {
            let clientID = msg.components(separatedBy: " ")[0]
            if yubiKeyClients.contains(clientID) {
                fido2Needed = false
            }
        }
    }

    // MARK: - Pulsing

    private func startPulsing() {
        let timeout = UserDefaults.standard.double(forKey: "safetyTimeout")
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.fido2Needed = false
            self?.openPGPNeeded = false
            self?.activeOperation = nil
            self?.isTouchNeeded = false
            self?.stopPulsing()
            self?.dismissNotification()
        }
        guard !isPulsing else { return }
        isPulsing = true
        statusItem.button?.image = makeAlertIcon()
        var blinkOn = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            blinkOn.toggle()
            self.statusItem.button?.alphaValue = blinkOn ? 1.0 : 0.2
        }
    }

    private func stopPulsing() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        isPulsing = false
        if let button = statusItem.button {
            button.image = sfSymbol("key")
            button.image?.isTemplate = true
            button.alphaValue = 1.0
        }
    }

    // MARK: - History

    private func recordTouch(type: String) {
        let retention = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        guard retention > 0 else { return }
        let event = TouchEvent(type: type)
        history.insert(event, at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "touchHistory"),
              let events = try? JSONDecoder().decode([TouchEvent].self, from: data) else { return }
        history = events
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "touchHistory")
        }
    }

    func pruneHistory() {
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        guard days > 0 else { history = []; saveHistory(); return }
        let cutoff: Date
        if days == 1 {
            cutoff = Calendar.current.startOfDay(for: Date())
        } else {
            guard let c = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
            cutoff = c
        }
        history = history.filter { $0.timestamp >= cutoff }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(operation: String) {
        guard UserDefaults.standard.bool(forKey: "showNotifications") else { return }
        let content = UNMutableNotificationContent()
        content.title = "YubiKey Touch Needed"
        content.body = operation == "FIDO2" ? "FIDO2 authentication waiting" : "OpenPGP operation waiting"
        if UserDefaults.standard.bool(forKey: "playSound") {
            content.sound = .default
        }
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "yknotify-touch", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func dismissNotification() {
        let ids = ["yknotify-touch"]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Login item

    private func syncLoginItem() {
        let actual = SMAppService.mainApp.status == .enabled
        let stored = UserDefaults.standard.bool(forKey: "startAtLogin")
        if stored != actual {
            UserDefaults.standard.set(actual, forKey: "startAtLogin")
        }
        if stored && !actual {
            try? SMAppService.mainApp.register()
        }
    }

    @objc func quit() {
        process?.terminate()
        NSApp.terminate(nil)
    }
}

// MARK: - PreferencesView

struct PreferencesView: View {
    @ObservedObject var controller: YKNotify
    @AppStorage("startAtLogin") private var startAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("playSound") private var playSound = false
    @AppStorage("watchFIDO2") private var watchFIDO2 = true
    @AppStorage("watchOpenPGP") private var watchOpenPGP = true
    @AppStorage("safetyTimeout") private var safetyTimeout = 30.0
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 7

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab.tabItem { Label("Notifications", systemImage: "bell") }
            monitoringTab.tabItem { Label("Monitoring", systemImage: "magnifyingglass") }
            historyTab.tabItem { Label("History", systemImage: "list.clipboard") }
        }
        .frame(width: 400, height: 180)
        .padding(8)
    }

    private var generalTab: some View {
        Form {
            Toggle("Start at login", isOn: $startAtLogin)
                .onChange(of: startAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        startAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .padding()
    }

    private var notificationsTab: some View {
        Form {
            Toggle("Show notification banner", isOn: $showNotifications)
            Toggle("Play sound", isOn: $playSound)
                .disabled(!showNotifications)
        }
        .padding()
    }

    private var monitoringTab: some View {
        Form {
            Toggle("Watch FIDO2 events", isOn: $watchFIDO2)
            Toggle("Watch OpenPGP events", isOn: $watchOpenPGP)
            HStack {
                Text("Safety timeout")
                Slider(value: $safetyTimeout, in: 10...60, step: 5)
                Text("\(Int(safetyTimeout))s")
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding()
    }

    private var historyTab: some View {
        Form {
            Picker("Keep history for", selection: $historyRetentionDays) {
                Text("Today only").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("Never").tag(0)
            }
            .onChange(of: historyRetentionDays) { _, _ in controller.pruneHistory() }
            Button("Clear History") { controller.clearHistory() }
        }
        .padding()
    }
}

// MARK: - Entry point

let app = NSApplication.shared

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: YKNotify!
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = YKNotify()
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
