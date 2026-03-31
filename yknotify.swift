import Cocoa

let logPredicate = """
(processImagePath == "/kernel" AND senderImagePath ENDSWITH "IOHIDFamily") \
OR (subsystem CONTAINS "CryptoTokenKit")
"""

struct LogEntry {
    let processImagePath: String
    let senderImagePath: String
    let subsystem: String
    let eventMessage: String
}

class YKNotify: NSObject {
    private var statusItem: NSStatusItem!
    private var pulseTimer: Timer?
    private var safetyTimer: Timer?
    private var process: Process?
    private var isPulsing = false
    private var pulsePhase: Double = 0

    private var fido2Needed = false
    private var openPGPNeeded = false
    private var yubiKeyClients: Set<String> = []
    private var lineBuffer = Data()

    override init() {
        super.init()
        setupStatusItem()
        startLogStream()
    }

    private func sfSymbol(_ name: String, size: CGFloat = 14) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "YubiKey")
        return image?.withSymbolConfiguration(config)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = sfSymbol("key")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit yknotify", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
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

    // Called on the readabilityHandler's serial queue.
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

    // MARK: - Detection (runs on main thread)

    private func handleEntry(_ entry: LogEntry) {
        let wasTouchNeeded = fido2Needed || openPGPNeeded

        if entry.processImagePath == "/kernel",
           entry.senderImagePath.hasSuffix("IOHIDFamily") {
            handleFIDO2(entry.eventMessage)
        } else if entry.processImagePath.hasSuffix("usbsmartcardreaderd"),
                  entry.subsystem.hasSuffix("CryptoTokenKit") {
            openPGPNeeded = entry.eventMessage == "Time extension received"
        }

        let isTouchNeeded = fido2Needed || openPGPNeeded
        if isTouchNeeded != wasTouchNeeded {
            isTouchNeeded ? startPulsing() : stopPulsing()
        }
    }

    private func handleFIDO2(_ msg: String) {
        // e.g., AppleUserUSBHostHIDDevice:0x100000c81 open by IOHIDLibUserClient:0x10016f869 (0x1)
        // Other HID types (e.g., AppleUSBTopCaseHIDDriver) do not correspond to YubiKey.
        if msg.contains("AppleUserUSBHostHIDDevice:"),
           msg.contains("open by IOHIDLibUserClient:") {
            let parts = msg.components(separatedBy: " open by ")
            if parts.count == 2 {
                let clientID = parts[1].components(separatedBy: " ")[0]
                yubiKeyClients.insert(clientID)
            }
        }

        // e.g., IOHIDLibUserClient:0x10016f869 startQueue
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

    // MARK: - UI

    private func startPulsing() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            self?.fido2Needed = false
            self?.openPGPNeeded = false
            self?.stopPulsing()
        }
        guard !isPulsing else { return }
        isPulsing = true
        pulsePhase = 0
        if let button = statusItem.button {
            button.image = sfSymbol("key.fill")
            button.image?.isTemplate = true
        }
        // ~60fps smooth sine pulse: alpha oscillates between 0.25 and 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase += (2.0 * .pi) / 60.0  // one full cycle per second
            let alpha = 0.625 + 0.375 * sin(self.pulsePhase)
            self.statusItem.button?.alphaValue = CGFloat(alpha)
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

    @objc private func quit() {
        process?.terminate()
        NSApp.terminate(nil)
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
