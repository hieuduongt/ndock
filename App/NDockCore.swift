import Foundation
import AppKit

enum NDockError: LocalizedError {
    case missingBundledDylib
    case missingInstalledDylib
    case appNotFound(String)
    case commandFailed(String, Int32)
    case dockNotRunning

    var errorDescription: String? {
        switch self {
        case .missingBundledDylib:
            return "Không tìm thấy NDock.dylib trong app bundle."
        case .missingInstalledDylib:
            return "Chưa cài N-Dock — bấm Install trước."
        case .appNotFound(let name):
            return "Không tìm thấy app: \(name)"
        case .commandFailed(let cmd, let code):
            return "Lệnh thất bại (\(code)): \(cmd)"
        case .dockNotRunning:
            return "Không tìm thấy Dock sau khi restart."
        }
    }
}

struct NDockSettings {
    var windowMarginPerSide: Double
    var dockMarginPerSide: Double
    var autoInstallAtLogin: Bool
    var autoInstallAppPath: String

    static let windowMarginKey = "windowMarginPerSide"
    static let dockMarginKey = "dockMarginPerSide"
    static let autoInstallKey = "autoInstallAtLogin"
    static let autoInstallAppKey = "autoInstallAppPath"
    static let defaults = NDockSettings(
        windowMarginPerSide: 5,
        dockMarginPerSide: 5,
        autoInstallAtLogin: false,
        autoInstallAppPath: ""
    )

    static var settingsURL: URL {
        NDockCore.ndockHome.appendingPathComponent("settings.plist")
    }

    static func load() -> NDockSettings {
        guard let dict = NSDictionary(contentsOf: settingsURL) else {
            return defaults
        }
        return NDockSettings(
            windowMarginPerSide: clamp(dict[windowMarginKey]),
            dockMarginPerSide: clamp(dict[dockMarginKey]),
            autoInstallAtLogin: (dict[autoInstallKey] as? NSNumber)?.boolValue ?? false,
            autoInstallAppPath: dict[autoInstallAppKey] as? String ?? ""
        )
    }

    private static func clamp(_ value: Any?) -> Double {
        let n = (value as? NSNumber)?.doubleValue ?? 5
        return min(max(n, 0), 100)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: NDockCore.ndockHome, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            Self.windowMarginKey: windowMarginPerSide,
            Self.dockMarginKey: dockMarginPerSide,
            Self.autoInstallKey: autoInstallAtLogin,
            Self.autoInstallAppKey: autoInstallAppPath,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: Self.settingsURL, options: .atomic)
    }
}

enum NDockCore {
    static let dockBinary = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    static let bootScriptBody = """
    #!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
    DIR="$(cd "$(dirname "$0")" && pwd)"
    DYLIB="$DIR/NDock.dylib"
    [ -f "$DYLIB" ] || exit 0
    launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB"
    sleep 2
    /usr/bin/killall Dock 2>/dev/null || true
    """

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var ndockHome: URL { home.appendingPathComponent("Library/Application Support/N-Dock", isDirectory: true) }
    static var installedDylib: URL { ndockHome.appendingPathComponent("NDock.dylib") }
    static var bootScript: URL { ndockHome.appendingPathComponent("boot.sh") }
    static var launchAgentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/com.ndock.inject.plist", isDirectory: false) }
    static var autoInstallLaunchAgentPlist: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.ndock.autoinstall.plist", isDirectory: false)
    }

    static var bundledDylib: URL? {
        Bundle.main.url(forResource: "NDock", withExtension: "dylib")
    }

    static var guiDomain: String { "gui/\(getuid())" }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], env: [String: String]? = nil) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let env {
            var merged = ProcessInfo.processInfo.environment
            env.forEach { merged[$0.key] = $0.value }
            proc.environment = merged
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw NDockError.commandFailed("\(launchPath) \(args.joined(separator: " "))", proc.terminationStatus)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runSilent(_ launchPath: String, _ args: [String], env: [String: String]? = nil) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let env {
            var merged = ProcessInfo.processInfo.environment
            env.forEach { merged[$0.key] = $0.value }
            proc.environment = merged
        }
        let null = FileHandle.nullDevice
        proc.standardOutput = null
        proc.standardError = null
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NDockError.commandFailed("\(launchPath) \(args.joined(separator: " "))", proc.terminationStatus)
        }
    }

    static func codesign(_ path: URL) {
        try? runSilent("/usr/bin/codesign", ["-f", "-s", "-", path.path])
    }

    static func prereqReport() -> String {
        var lines: [String] = ["=== Kiểm tra ==="]
        if let sip = try? run("/usr/bin/csrutil", ["status"]) {
            lines.append(sip.components(separatedBy: "\n").first ?? sip)
        }
        let lvPath = "/Library/Preferences/com.apple.security.libraryvalidation.plist"
        let lv = (try? run("/usr/bin/defaults", ["read", lvPath, "DisableLibraryValidation"])) ?? "0"
        lines.append("DisableLibraryValidation = \(lv)")
        if lv.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            lines.append("Cần: sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true && sudo reboot")
        }
        return lines.joined(separator: "\n")
    }

    static func stageDylib() throws {
        guard let source = bundledDylib else { throw NDockError.missingBundledDylib }
        try FileManager.default.createDirectory(at: ndockHome, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: NDockSettings.settingsURL.path) {
            try NDockSettings.defaults.save()
        }
        if FileManager.default.fileExists(atPath: installedDylib.path) {
            try FileManager.default.removeItem(at: installedDylib)
        }
        try FileManager.default.copyItem(at: source, to: installedDylib)
        codesign(installedDylib)
    }

    static func writeBootScript() throws {
        try bootScriptBody.write(to: bootScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bootScript.path)
    }

    static func installLaunchAgent() throws {
        let plistDir = launchAgentPlist.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.ndock.inject</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>\(bootScript.path)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>
        """
        try plist.write(to: launchAgentPlist, atomically: true, encoding: .utf8)
        try? runSilent("/bin/launchctl", ["bootout", guiDomain + "/com.ndock.inject"])
        try runSilent("/bin/launchctl", ["bootstrap", guiDomain, launchAgentPlist.path])
        try? runSilent("/bin/launchctl", ["enable", guiDomain + "/com.ndock.inject"])
        try? runSilent("/bin/launchctl", ["kickstart", "-k", guiDomain + "/com.ndock.inject"])
        try runSilent("/bin/launchctl", ["setenv", "DYLD_INSERT_LIBRARIES", installedDylib.path])
    }

    static func restartDock() throws {
        try? runSilent("/usr/bin/killall", ["Dock"])
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.2)
            if dockIsRunning { break }
        }
        Thread.sleep(forTimeInterval: 2)
        if !dockIsRunning {
            try runSilent(dockBinary, [], env: ["DYLD_INSERT_LIBRARIES": installedDylib.path])
            Thread.sleep(forTimeInterval: 2)
        }
        guard dockIsRunning else { throw NDockError.dockNotRunning }
    }

    static var dockIsRunning: Bool {
        (try? run("/usr/bin/pgrep", ["-x", "Dock"]))?.isEmpty == false
    }

    static func install() throws -> String {
        let checks = prereqReport()
        try stageDylib()
        try writeBootScript()
        try installLaunchAgent()
        try restartDock()
        return """
        \(checks)

        Cài tại: \(ndockHome.path)
        DYLD_INSERT_LIBRARIES=\(installedDylib.path)

        Đã cài N-Dock (Dock tweak + window margin).
        Tự chạy mỗi lần login. Có thể xóa/di chuyển NDock.app — không ảnh hưởng.
        """
    }

    static var appExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NDock")
    }

    static func isAutoInstallEnabled() -> Bool {
        FileManager.default.fileExists(atPath: autoInstallLaunchAgentPlist.path)
    }

    static func writeAutoInstallLaunchAgent(appPath: String) throws {
        let binary = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/NDock").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw NDockError.commandFailed("Không tìm thấy binary app tại \(binary)", 1)
        }
        let plistDir = autoInstallLaunchAgentPlist.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.ndock.autoinstall</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(binary)</string>
            <string>install</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
        </dict>
        </plist>
        """
        try plist.write(to: autoInstallLaunchAgentPlist, atomically: true, encoding: .utf8)
        try? runSilent("/bin/launchctl", ["bootout", guiDomain + "/com.ndock.autoinstall"])
        try runSilent("/bin/launchctl", ["bootstrap", guiDomain, autoInstallLaunchAgentPlist.path])
        try? runSilent("/bin/launchctl", ["enable", guiDomain + "/com.ndock.autoinstall"])
    }

    static func removeAutoInstallLaunchAgent() throws {
        try? runSilent("/bin/launchctl", ["bootout", guiDomain + "/com.ndock.autoinstall"])
        try? FileManager.default.removeItem(at: autoInstallLaunchAgentPlist)
    }

    static func setAutoInstallAtLogin(_ enabled: Bool, settings: NDockSettings) throws -> String {
        var s = settings
        if enabled {
            let appPath = Bundle.main.bundleURL.path
            try writeAutoInstallLaunchAgent(appPath: appPath)
            s.autoInstallAtLogin = true
            s.autoInstallAppPath = appPath
            try s.save()
            let msg = try install()
            return """
            Đã bật tự Install khi đăng nhập.
            Mỗi lần login sẽ chạy: NDock install (không mở UI).

            \(msg)
            """
        }
        try removeAutoInstallLaunchAgent()
        s.autoInstallAtLogin = false
        s.autoInstallAppPath = ""
        try s.save()
        return "Đã tắt tự Install khi đăng nhập."
    }

    static func saveSettings(_ settings: NDockSettings, restartDockAfterSave: Bool) throws -> String {
        try settings.save()
        var msg = """
        Đã lưu settings.
        App margin: \(Int(settings.windowMarginPerSide)) pt mỗi cạnh
        Dock margin: \(Int(settings.dockMarginPerSide)) pt mỗi cạnh (tổng \(Int(settings.dockMarginPerSide * 2)) pt)
        """
        if restartDockAfterSave && FileManager.default.fileExists(atPath: installedDylib.path) {
            try restartDock()
            msg += "\n\nDock đã restart — margin Dock áp dụng ngay."
        }
        msg += "\nApp window margin áp dụng khi zoom/Fill (mở lại app nếu đang chạy)."
        return msg
    }

    static func uninstall() throws -> String {
        try? removeAutoInstallLaunchAgent()
        try? runSilent("/bin/launchctl", ["bootout", guiDomain + "/com.ndock.inject"])
        try? FileManager.default.removeItem(at: launchAgentPlist)
        try? runSilent("/bin/launchctl", ["unsetenv", "DYLD_INSERT_LIBRARIES"])
        try? FileManager.default.removeItem(at: ndockHome)
        try? runSilent("/usr/bin/killall", ["Dock"])
        return "Đã gỡ N-Dock."
    }

    static func statusReport() -> String {
        let dylibOK = FileManager.default.fileExists(atPath: installedDylib.path) ? "OK" : "missing"
        let agentOK = FileManager.default.fileExists(atPath: launchAgentPlist.path) ? "OK" : "missing"
        let autoOK = isAutoInstallEnabled() ? "ON" : "OFF"
        let env = (try? run("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"])) ?? "(unset)"
        let s = NDockSettings.load()
        return """
        NDOCK_HOME=\(ndockHome.path)
        DYLIB=\(installedDylib.path) (\(dylibOK))
        LaunchAgent=\(agentOK)
        AutoInstallLogin=\(autoOK)
        DYLD_INSERT_LIBRARIES=\(env.isEmpty ? "(unset)" : env)
        App margin=\(Int(s.windowMarginPerSide)) pt/cạnh
        Dock margin=\(Int(s.dockMarginPerSide)) pt/cạnh
        """
    }

    static func resolveApp(named name: String) -> URL? {
        if let found = try? run("/usr/bin/mdfind", ["kMDItemKind == 'Application' && kMDItemDisplayName == '\(name)'"]),
           let first = found.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
           FileManager.default.fileExists(atPath: first) {
            return URL(fileURLWithPath: first)
        }
        for path in [
            "/System/Applications/\(name).app",
            "/Applications/\(name).app"
        ] where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func executable(in bundle: URL, appName: String) -> URL? {
        let direct = bundle.appendingPathComponent("Contents/MacOS/\(appName)")
        if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        guard let items = try? FileManager.default.contentsOfDirectory(at: macOS, includingPropertiesForKeys: [.isExecutableKey]) else {
            return nil
        }
        return items.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func openApp(named name: String) throws {
        guard FileManager.default.fileExists(atPath: installedDylib.path) else {
            throw NDockError.missingInstalledDylib
        }
        guard let bundle = resolveApp(named: name), let exec = executable(in: bundle, appName: name) else {
            throw NDockError.appNotFound(name)
        }
        let proc = Process()
        proc.executableURL = exec
        proc.arguments = []
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = installedDylib.path
        proc.environment = env
        try proc.run()
    }
}
