import SwiftUI
import AppKit
import UserNotifications

@main
struct ClawdbotControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = ClawdbotManager()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(manager)
                .frame(minWidth: 680, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra("Clawdbot", systemImage: manager.isRunning ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right.circle") {
            MenuBarView()
                .environmentObject(manager)
        }
        .menuBarExtraStyle(.menu)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Settings Store
class SettingsStore: ObservableObject {
    @AppStorage("autoStart") var autoStart = false
    @AppStorage("showMenuBar") var showMenuBar = true
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("refreshInterval") var refreshInterval = 4.0
    @AppStorage("showResourcesInFooter") var showResourcesInFooter = true
    @AppStorage("compactLogs") var compactLogs = true
    @AppStorage("logLines") var logLines = 30
}

// MARK: - Manager
class ClawdbotManager: ObservableObject {
    @Published var isRunning = false
    @Published var version = ""
    @Published var logs: [String] = []
    @Published var channels: [(name: String, enabled: Bool)] = []
    @Published var startedAt: Date?
    @Published var autoStartEnabled = false
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    @Published var isRestarting = false
    @Published var lastChecked = Date()
    @Published var healthStatus: String = "Unknown"
    @Published var healthDetails: [String] = []
    @Published var isCheckingHealth = false
    @Published var showSettings = false

    let settings = SettingsStore()
    private var timer: Timer?
    private let path = "/opt/homebrew/bin/clawdbot"
    private var pid: Int32?
    private var wasRunning = false

    init() {
        checkAutoStart()
        refresh()
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkStatus()
            self?.loadVersion()
            self?.loadChannels()
            self?.loadLogs()
            self?.loadResources()
            DispatchQueue.main.async { self?.lastChecked = Date() }
        }
    }

    private func checkStatus() {
        let result = shell("pgrep -f 'clawdbot-gateway' 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        let running = !result.isEmpty
        if let p = Int32(result.components(separatedBy: "\n").first ?? "") { pid = p }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if running && !self.isRunning { self.startedAt = Date() }
            if !running { self.startedAt = nil; self.pid = nil }
            if self.wasRunning != running && self.settings.notificationsEnabled { self.notify(running: running) }
            self.wasRunning = running
            self.isRunning = running
        }
    }

    private func loadVersion() {
        let v = shell("\(path) --version 2>&1 | head -1").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in self?.version = v }
    }

    private func loadChannels() {
        let configPath = NSHomeDirectory() + "/.clawdbot/clawdbot.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any],
              let entries = plugins["entries"] as? [String: Any] else { return }

        var ch: [(String, Bool)] = []
        if let w = entries["whatsapp"] as? [String: Any] { ch.append(("WhatsApp", w["enabled"] as? Bool ?? false)) }
        if let s = entries["signal"] as? [String: Any] { ch.append(("Signal", s["enabled"] as? Bool ?? false)) }
        DispatchQueue.main.async { [weak self] in self?.channels = ch }
    }

    private func loadLogs() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let logPath = "/tmp/clawdbot/clawdbot-\(df.string(from: Date())).log"
        let lines = Int(settings.logLines)
        let result = shell("tail -\(lines) '\(logPath)' 2>/dev/null")
        let logLines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        DispatchQueue.main.async { [weak self] in self?.logs = Array(logLines.suffix(lines)) }
    }

    private func loadResources() {
        guard let p = pid else {
            DispatchQueue.main.async { [weak self] in self?.cpuUsage = 0; self?.memoryUsage = 0 }
            return
        }
        let result = shell("ps -p \(p) -o %cpu,%mem 2>/dev/null | tail -1")
        let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        DispatchQueue.main.async { [weak self] in
            self?.cpuUsage = Double(parts.first ?? "0") ?? 0
            self?.memoryUsage = Double(parts.dropFirst().first ?? "0") ?? 0
        }
    }

    func start() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            _ = self.shell("\(self.path) gateway start >/dev/null 2>&1 &")
            sleep(2)
            self.refresh()
        }
    }

    func stop() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            _ = self.shell("\(self.path) gateway stop >/dev/null 2>&1")
            sleep(1)
            self.refresh()
        }
    }

    func restart() {
        DispatchQueue.main.async { self.isRestarting = true }
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            _ = self.shell("\(self.path) gateway stop >/dev/null 2>&1")
            sleep(2)
            _ = self.shell("\(self.path) gateway start >/dev/null 2>&1 &")
            sleep(2)
            DispatchQueue.main.async { self.isRestarting = false }
            self.refresh()
        }
    }

    func runHealthCheck() {
        DispatchQueue.main.async { self.isCheckingHealth = true }
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.shell("\(self.path) doctor 2>&1")
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            DispatchQueue.main.async {
                self.healthDetails = Array(lines.prefix(10))
                if result.lowercased().contains("error") || result.lowercased().contains("fail") {
                    self.healthStatus = "Issues Found"
                } else if result.lowercased().contains("warn") {
                    self.healthStatus = "Warnings"
                } else {
                    self.healthStatus = "Healthy"
                }
                self.isCheckingHealth = false
            }
        }
    }

    func openDashboard() { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:18789/")!) }
    func openConfig() { NSWorkspace.shared.selectFile(NSHomeDirectory() + "/.clawdbot/clawdbot.json", inFileViewerRootedAtPath: "") }
    func openLogs() {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let logPath = "/tmp/clawdbot/clawdbot-\(df.string(from: Date())).log"
        NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
    }

    func checkAutoStart() {
        let exists = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.clawdbot.autostart.plist")
        DispatchQueue.main.async { [weak self] in
            self?.autoStartEnabled = exists
            self?.settings.autoStart = exists
        }
    }

    func setAutoStart(_ on: Bool) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            let plist = dir + "/com.clawdbot.autostart.plist"
            if on {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let content = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.clawdbot.autostart</string>
<key>ProgramArguments</key><array><string>\(self.path)</string><string>gateway</string><string>start</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
"""
                try? content.write(toFile: plist, atomically: true, encoding: .utf8)
                _ = self.shell("launchctl load '\(plist)' 2>/dev/null")
            } else {
                _ = self.shell("launchctl unload '\(plist)' 2>/dev/null")
                try? FileManager.default.removeItem(atPath: plist)
            }
            self.checkAutoStart()
        }
    }

    private func notify(running: Bool) {
        let c = UNMutableNotificationContent()
        c.title = running ? "Clawdbot Started" : "Clawdbot Stopped"
        c.sound = running ? .default : .defaultCritical
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func shell(_ cmd: String) -> String {
        let task = Process(); let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        task.launchPath = "/bin/zsh"; task.arguments = ["-c", cmd]
        try? task.run(); task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - Menu Bar
struct MenuBarView: View {
    @EnvironmentObject var m: ClawdbotManager
    var body: some View {
        Group {
            Label(m.isRunning ? "Running" : "Stopped", systemImage: m.isRunning ? "circle.fill" : "circle")
            Divider()
            if m.isRunning {
                Button("Stop") { m.stop() }
                Button("Restart") { m.restart() }.disabled(m.isRestarting)
            } else {
                Button("Start") { m.start() }
            }
            Button("Dashboard") { m.openDashboard() }.disabled(!m.isRunning)
            Divider()
            Button("Run Health Check") { m.runHealthCheck() }
            Button(m.autoStartEnabled ? "Disable Auto-start" : "Enable Auto-start") { m.setAutoStart(!m.autoStartEnabled) }
            Divider()
            Button("Show Window") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

// MARK: - Dashboard View
struct DashboardView: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        HStack(spacing: 0) {
            // Main Content
            ScrollView {
                VStack(spacing: 16) {
                    HeaderCard().environmentObject(m)

                    HStack(spacing: 12) {
                        StatusCard(title: "Status", value: m.isRunning ? "Running" : "Stopped", icon: "power", color: m.isRunning ? .green : .red)
                        StatusCard(title: "Port", value: "18789", icon: "network", color: .blue)
                        StatusCard(title: "Channels", value: "\(m.channels.filter { $0.enabled }.count) active", icon: "message.fill", color: .purple)
                        StatusCard(title: "Health", value: m.healthStatus, icon: healthIcon, color: healthColor)
                    }

                    InfoCard().environmentObject(m)
                    QuickActionsCard().environmentObject(m)
                    ResourceCard().environmentObject(m)
                    HealthCard().environmentObject(m)
                    ChannelsCard().environmentObject(m)
                    LogsCard().environmentObject(m)
                    FooterView().environmentObject(m)
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            // Settings Sidebar
            if m.showSettings {
                Divider()
                SettingsSidebar()
                    .environmentObject(m)
                    .frame(width: 220)
                    .transition(.move(edge: .trailing))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { m.showSettings.toggle() } }) {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }
        }
    }

    var healthIcon: String {
        switch m.healthStatus {
        case "Healthy": return "checkmark.circle.fill"
        case "Warnings": return "exclamationmark.triangle.fill"
        case "Issues Found": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var healthColor: Color {
        switch m.healthStatus {
        case "Healthy": return .green
        case "Warnings": return .orange
        case "Issues Found": return .red
        default: return .gray
        }
    }
}

// MARK: - Settings Sidebar
struct SettingsSidebar: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.headline)
                    .padding(.bottom, 4)

                // Startup
                VStack(alignment: .leading, spacing: 10) {
                    Label("Startup", systemImage: "power")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Toggle("Auto-start on login", isOn: Binding(
                        get: { m.autoStartEnabled },
                        set: { m.setAutoStart($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                // Notifications
                VStack(alignment: .leading, spacing: 10) {
                    Label("Notifications", systemImage: "bell")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Toggle("Enable notifications", isOn: m.settings.$notificationsEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                // Display
                VStack(alignment: .leading, spacing: 10) {
                    Label("Display", systemImage: "rectangle.3.group")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Toggle("Show resources in footer", isOn: m.settings.$showResourcesInFooter)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Toggle("Compact log view", isOn: m.settings.$compactLogs)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                Divider()

                // Refresh
                VStack(alignment: .leading, spacing: 10) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Interval")
                            .font(.caption)
                        Spacer()
                        Picker("", selection: m.settings.$refreshInterval) {
                            Text("2s").tag(2.0)
                            Text("4s").tag(4.0)
                            Text("10s").tag(10.0)
                            Text("30s").tag(30.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        .onChange(of: m.settings.refreshInterval) { _ in
                            m.startTimer()
                        }
                    }

                    HStack {
                        Text("Log lines")
                            .font(.caption)
                        Spacer()
                        Picker("", selection: m.settings.$logLines) {
                            Text("10").tag(10)
                            Text("30").tag(30)
                            Text("50").tag(50)
                            Text("100").tag(100)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 70)
                    }
                }

                Divider()

                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    Label("Actions", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Button(action: { m.openConfig() }) {
                        Label("Open Config File", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { m.openLogs() }) {
                        Label("Open Log File", systemImage: "doc.plaintext")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: { openTerminal() }) {
                        Label("Open Terminal", systemImage: "terminal")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // About
                VStack(alignment: .leading, spacing: 6) {
                    Label("About", systemImage: "info.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(m.version.isEmpty ? "Clawdbot" : m.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Control App v1.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }

    func openTerminal() {
        NSAppleScript(source: "tell application \"Terminal\" to do script \"cd ~/.clawdbot && clawdbot\"")?.executeAndReturnError(nil)
    }
}

// MARK: - Header Card
struct HeaderCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(m.isRunning ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .frame(width: 60, height: 60)
                Circle()
                    .fill(m.isRunning ? Color.green : Color.red)
                    .frame(width: 20, height: 20)
                    .shadow(color: m.isRunning ? .green.opacity(0.5) : .red.opacity(0.5), radius: 8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Clawdbot")
                    .font(.title.weight(.bold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(m.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(m.isRunning ? "Running" : "Stopped")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let started = m.startedAt {
                        Text("•").foregroundStyle(.tertiary)
                        Text("Uptime: \(formatUptime(started))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: { m.isRunning ? m.stop() : m.start() }) {
                    Label(m.isRunning ? "Stop" : "Start", systemImage: m.isRunning ? "stop.fill" : "play.fill")
                        .frame(width: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(m.isRunning ? .red : .green)

                Button(action: { m.restart() }) {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!m.isRunning || m.isRestarting)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func formatUptime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s >= 3600 { return "\(s/3600)h \((s%3600)/60)m" }
        if s >= 60 { return "\(s/60)m" }
        return "\(s)s"
    }
}

// MARK: - Status Card
struct StatusCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Info Card
struct InfoCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Information", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Version").foregroundStyle(.secondary)
                    Text(m.version.isEmpty ? "Unknown" : m.version)
                }
                GridRow {
                    Text("Config Path").foregroundStyle(.secondary)
                    Text("~/.clawdbot/clawdbot.json").textSelection(.enabled)
                }
                GridRow {
                    Text("Dashboard").foregroundStyle(.secondary)
                    Link("http://127.0.0.1:18789/", destination: URL(string: "http://127.0.0.1:18789/")!)
                }
                GridRow {
                    Text("Auto-start").foregroundStyle(.secondary)
                    Text(m.autoStartEnabled ? "Enabled" : "Disabled")
                        .foregroundStyle(m.autoStartEnabled ? .green : .secondary)
                }
                GridRow {
                    Text("Last Checked").foregroundStyle(.secondary)
                    Text(formatTime(m.lastChecked))
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Quick Actions Card
struct QuickActionsCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Actions", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ActionButton(title: "Dashboard", icon: "globe", color: .blue) { m.openDashboard() }
                    .opacity(m.isRunning ? 1 : 0.5)
                ActionButton(title: "Config", icon: "folder", color: .orange) { m.openConfig() }
                ActionButton(title: "Health", icon: "stethoscope", color: .pink) { m.runHealthCheck() }
                ActionButton(title: "Refresh", icon: "arrow.clockwise", color: .teal) { m.refresh() }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resource Card
struct ResourceCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Resource Usage", systemImage: "cpu")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CPU")
                        Spacer()
                        Text(String(format: "%.1f%%", m.cpuUsage))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(m.cpuUsage / 100, 1.0))
                        .tint(m.cpuUsage > 80 ? .red : (m.cpuUsage > 50 ? .orange : .green))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Memory")
                        Spacer()
                        Text(String(format: "%.1f%%", m.memoryUsage))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(m.memoryUsage / 100, 1.0))
                        .tint(m.memoryUsage > 80 ? .red : (m.memoryUsage > 50 ? .orange : .blue))
                }
            }

            if let started = m.startedAt {
                HStack {
                    Text("Uptime")
                    Spacer()
                    Text(formatUptime(started))
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(.green)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func formatUptime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %dh %dm", d, h, m) }
        if h > 0 { return String(format: "%dh %dm %ds", h, m, sec) }
        return String(format: "%dm %ds", m, sec)
    }
}

// MARK: - Health Card
struct HealthCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Health Check", systemImage: "stethoscope")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { m.runHealthCheck() }) {
                    if m.isCheckingHealth {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(m.isCheckingHealth)
            }

            HStack(spacing: 8) {
                Image(systemName: healthIcon)
                    .foregroundStyle(healthColor)
                Text(m.healthStatus)
                    .font(.subheadline.weight(.medium))
            }

            if !m.healthDetails.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(m.healthDetails.prefix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    var healthIcon: String {
        switch m.healthStatus {
        case "Healthy": return "checkmark.circle.fill"
        case "Warnings": return "exclamationmark.triangle.fill"
        case "Issues Found": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var healthColor: Color {
        switch m.healthStatus {
        case "Healthy": return .green
        case "Warnings": return .orange
        case "Issues Found": return .red
        default: return .gray
        }
    }
}

// MARK: - Channels Card
struct ChannelsCard: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Channels", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.secondary)

            if m.channels.isEmpty {
                Text("No channels configured")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    ForEach(m.channels, id: \.name) { ch in
                        HStack(spacing: 10) {
                            Image(systemName: ch.name == "WhatsApp" ? "message.fill" : "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(ch.enabled ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.name)
                                    .font(.subheadline.weight(.medium))
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(ch.enabled && m.isRunning ? Color.green : Color.gray.opacity(0.4))
                                        .frame(width: 6, height: 6)
                                    Text(ch.enabled ? (m.isRunning ? "Connected" : "Enabled") : "Disabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if ch.enabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Logs Card
struct LogsCard: View {
    @EnvironmentObject var m: ClawdbotManager
    @State private var expanded = false
    @State private var searchText = ""

    var filteredLogs: [String] {
        let logs = expanded ? m.logs : Array(m.logs.suffix(5))
        if searchText.isEmpty { return logs }
        return logs.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Logs", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { withAnimation { expanded.toggle() } }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if expanded {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if filteredLogs.isEmpty {
                Text("No logs available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: m.settings.compactLogs ? 2 : 4) {
                    ForEach(Array(filteredLogs.enumerated()), id: \.offset) { _, log in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(logColor(log))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(log)
                                .font(.system(m.settings.compactLogs ? .caption2 : .caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(expanded ? nil : 1)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func logColor(_ log: String) -> Color {
        let l = log.lowercased()
        if l.contains("error") || l.contains("fail") { return .red }
        if l.contains("warn") { return .orange }
        if l.contains("success") || l.contains("started") || l.contains("connected") { return .green }
        return .gray
    }
}

// MARK: - Footer
struct FooterView: View {
    @EnvironmentObject var m: ClawdbotManager

    var body: some View {
        HStack {
            if m.isRunning && m.settings.showResourcesInFooter {
                HStack(spacing: 12) {
                    Label(String(format: "%.1f%%", m.cpuUsage), systemImage: "cpu")
                    Label(String(format: "%.1f%%", m.memoryUsage), systemImage: "memorychip")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Last updated: \(formatTime(m.lastChecked))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(action: { m.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium
        return f.string(from: date)
    }
}
