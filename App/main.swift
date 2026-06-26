import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var windowMarginField: NSTextField!
    private var windowMarginStepper: NSStepper!
    private var dockMarginField: NSTextField!
    private var dockMarginStepper: NSStepper!
    private var autoInstallButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        loadSettingsIntoUI()
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let w: CGFloat = 400
        let h: CGFloat = 380
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "N-Dock"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = content

        var y: CGFloat = h - 36

        func addLabel(_ text: String, x: CGFloat, width: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: y, width: width, height: 18)
            label.font = NSFont.systemFont(ofSize: 12)
            content.addSubview(label)
        }

        addLabel("Margin app (pt mỗi cạnh)", x: 20, width: 220)
        windowMarginField = NSTextField(frame: NSRect(x: 250, y: y - 2, width: 44, height: 22))
        windowMarginField.alignment = .right
        windowMarginField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        windowMarginStepper = NSStepper(frame: NSRect(x: 298, y: y - 2, width: 24, height: 22))
        windowMarginStepper.minValue = 0
        windowMarginStepper.maxValue = 100
        windowMarginStepper.increment = 1
        windowMarginStepper.target = self
        windowMarginStepper.action = #selector(windowMarginStepped)
        content.addSubview(windowMarginField)
        content.addSubview(windowMarginStepper)

        y -= 36
        addLabel("Margin Dock (pt mỗi cạnh)", x: 20, width: 220)
        dockMarginField = NSTextField(frame: NSRect(x: 250, y: y - 2, width: 44, height: 22))
        dockMarginField.alignment = .right
        dockMarginField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        dockMarginStepper = NSStepper(frame: NSRect(x: 298, y: y - 2, width: 24, height: 22))
        dockMarginStepper.minValue = 0
        dockMarginStepper.maxValue = 100
        dockMarginStepper.increment = 1
        dockMarginStepper.target = self
        dockMarginStepper.action = #selector(dockMarginStepped)
        content.addSubview(dockMarginField)
        content.addSubview(dockMarginStepper)

        y -= 28
        let hint = NSTextField(wrappingLabelWithString: "Mặc định 5 pt/cạnh (tổng 10 pt). Dock restart ngay; app cần zoom lại hoặc mở lại.")
        hint.frame = NSRect(x: 20, y: y - 28, width: 360, height: 36)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)

        y -= 48
        let saveBtn = NSButton(title: "Lưu settings", target: self, action: #selector(saveSettingsTapped))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: 20, y: y, width: 120, height: 32)
        content.addSubview(saveBtn)

        y -= 52
        let sep = NSBox(frame: NSRect(x: 20, y: y, width: 360, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)

        y -= 36
        autoInstallButton = NSButton(checkboxWithTitle: "Tự Install khi đăng nhập", target: self, action: #selector(autoInstallTapped))
        autoInstallButton.frame = NSRect(x: 20, y: y, width: 360, height: 22)
        autoInstallButton.toolTip = "Mỗi lần login chạy NDock install ngầm — không mở cửa sổ app."
        content.addSubview(autoInstallButton)

        y -= 40
        let installBtn = NSButton(title: "Install", target: self, action: #selector(installTapped))
        installBtn.bezelStyle = .rounded
        installBtn.frame = NSRect(x: 20, y: y, width: 80, height: 32)

        let uninstallBtn = NSButton(title: "Uninstall", target: self, action: #selector(uninstallTapped))
        uninstallBtn.bezelStyle = .rounded
        uninstallBtn.frame = NSRect(x: 108, y: y, width: 90, height: 32)

        let openBtn = NSButton(title: "Open App…", target: self, action: #selector(openTapped))
        openBtn.bezelStyle = .rounded
        openBtn.frame = NSRect(x: 206, y: y, width: 90, height: 32)

        content.addSubview(installBtn)
        content.addSubview(uninstallBtn)
        content.addSubview(openBtn)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 16, width: 360, height: 80)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        window.makeKeyAndOrderFront(nil)
    }

    private func loadSettingsIntoUI() {
        let s = NDockSettings.load()
        windowMarginStepper.doubleValue = s.windowMarginPerSide
        windowMarginField.stringValue = "\(Int(s.windowMarginPerSide))"
        dockMarginStepper.doubleValue = s.dockMarginPerSide
        dockMarginField.stringValue = "\(Int(s.dockMarginPerSide))"
        autoInstallButton.state = NDockCore.isAutoInstallEnabled() ? .on : .off
    }

    private func currentSettings() -> NDockSettings {
        let s = NDockSettings.load()
        return NDockSettings(
            windowMarginPerSide: windowMarginStepper.doubleValue,
            dockMarginPerSide: dockMarginStepper.doubleValue,
            autoInstallAtLogin: s.autoInstallAtLogin,
            autoInstallAppPath: s.autoInstallAppPath
        )
    }

    @objc private func windowMarginStepped() {
        windowMarginField.stringValue = "\(Int(windowMarginStepper.doubleValue))"
    }

    @objc private func dockMarginStepped() {
        dockMarginField.stringValue = "\(Int(dockMarginStepper.doubleValue))"
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    @objc private func refreshStatus() {
        setStatus(NDockCore.statusReport())
    }

    @objc private func saveSettingsTapped() {
        do {
            let installed = FileManager.default.fileExists(atPath: NDockCore.installedDylib.path)
            setStatus(try NDockCore.saveSettings(currentSettings(), restartDockAfterSave: installed))
        } catch {
            setStatus("Lưu thất bại:\n\(error.localizedDescription)")
        }
    }

    @objc private func installTapped() {
        do {
            try currentSettings().save()
            setStatus(try NDockCore.install())
            loadSettingsIntoUI()
        } catch {
            setStatus("Install thất bại:\n\(error.localizedDescription)")
        }
    }

    @objc private func autoInstallTapped() {
        let enable = autoInstallButton.state == .on
        do {
            setStatus(try NDockCore.setAutoInstallAtLogin(enable, settings: currentSettings()))
            loadSettingsIntoUI()
        } catch {
            autoInstallButton.state = NDockCore.isAutoInstallEnabled() ? .on : .off
            setStatus("Tự Install thất bại:\n\(error.localizedDescription)")
        }
    }

    @objc private func uninstallTapped() {
        let alert = NSAlert()
        alert.messageText = "Gỡ N-Dock?"
        alert.informativeText = "Xóa LaunchAgent và dylib đã cài."
        alert.addButton(withTitle: "Gỡ")
        alert.addButton(withTitle: "Huỷ")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            setStatus(try NDockCore.uninstall())
        } catch {
            setStatus("Uninstall thất bại:\n\(error.localizedDescription)")
        }
    }

    @objc private func openTapped() {
        guard FileManager.default.fileExists(atPath: NDockCore.installedDylib.path) else {
            setStatus("Chưa cài — bấm Install trước.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Mở app kèm N-Dock"
        alert.informativeText = "Nhập tên app (vd. Safari, TextEdit):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Safari"
        alert.accessoryView = field
        alert.addButton(withTitle: "Mở")
        alert.addButton(withTitle: "Huỷ")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try NDockCore.openApp(named: name)
            setStatus("Đã mở \(name).\n\n\(NDockCore.statusReport())")
        } catch {
            setStatus("Mở app thất bại:\n\(error.localizedDescription)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

private func runCLI() -> Never {
    NDockCore.ensureInjectPathSafe()
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else {
        fputs("""
        N-Dock
          NDock install
          NDock uninstall
          NDock status
          NDock open -a AppName

        """, stderr)
        exit(1)
    }

    do {
        switch cmd {
        case "install":
            print(try NDockCore.install())
        case "uninstall":
            print(try NDockCore.uninstall())
        case "status":
            print(NDockCore.statusReport())
        case "open":
            guard args.count >= 3, args[1] == "-a" else {
                fputs("Dùng: NDock open -a AppName\n", stderr)
                exit(1)
            }
            try NDockCore.openApp(named: args[2])
        default:
            fputs("Lệnh không hợp lệ: \(cmd)\n", stderr)
            exit(1)
        }
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.count > 1 {
    runCLI()
} else {
    NDockCore.ensureInjectPathSafe()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
