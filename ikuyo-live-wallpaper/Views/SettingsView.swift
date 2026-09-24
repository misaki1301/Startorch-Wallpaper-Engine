import SwiftUI

/// The app's single `Settings` scene (⌘,). A grouped form is the standard Mac layout for
/// preferences, so this is the one place StarTorch's settings live — there's no longer a
/// sidebar page duplicating it.
struct SettingsView: View {
    @State private var cacheSize: UInt64 = 0
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Form {
            generalSection
            whenToPauseSection
            storageSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear {
            cacheSize = cacheManager.cacheSize()
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed Login Items in System Settings meanwhile.
            launchAtLogin.refresh()
        }
    }

    private var generalSection: some View {
        @Bindable var settings = settings
        return Section("General") {
            Toggle(isOn: $settings.showDockIcon) {
                Text("Show in Dock")
            }
            .onChange(of: settings.showDockIcon) { _, newValue in
                applyDockSetting(newValue)
            }

            Toggle(isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            )) {
                Text("Launch at Login")
            }

            if launchAtLogin.needsApproval {
                Label {
                    HStack(spacing: 6) {
                        Text("Allow StarTorch in Login Items to finish turning this on.")
                        Button("Open Login Items…") { launchAtLogin.openSystemSettings() }
                            .buttonStyle(.link)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .font(.caption)
            }
            if let error = launchAtLogin.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle(isOn: $settings.resumeWallpaperOnLaunch) {
                Text("Resume Wallpaper on Launch")
            }
        }
    }

    private var whenToPauseSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Desktop is covered", isOn: $settings.pauseWhenDesktopCovered)
            Toggle("An app is full screen", isOn: $settings.pauseForFullScreenApps)
            Toggle("Low Power Mode is on", isOn: $settings.pauseInLowPowerMode)
            Toggle("Running on battery", isOn: $settings.pauseOnBattery)
        } header: {
            Text("When to Pause")
        } footer: {
            Label("The wallpaper always pauses while the display is asleep or the screen is locked, since nobody can see it.", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Cached Wallpapers") {
                Text(formatBytes(cacheSize))
                    .foregroundStyle(.secondary)
            }
            Button("Clear Cache", role: .destructive) {
                cacheManager.clearCache()
                cacheSize = cacheManager.cacheSize()
            }
            .disabled(cacheSize == 0)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func applyDockSetting(_ show: Bool) {
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
        if show {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

/// Shown from the app menu's "About StarTorch" item via the standard AppKit panel, so it looks
/// and behaves like every other Mac app's About window.
enum AboutPanel {
    static func show() {
        let credits = NSAttributedString(
            string: String(localized: "Creator: shibuyaxpress"),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "StarTorch",
        ])
    }
}

#Preview {
    SettingsView()
        .environment(WallpaperCacheManager())
        .environment(AppSettings())
}
