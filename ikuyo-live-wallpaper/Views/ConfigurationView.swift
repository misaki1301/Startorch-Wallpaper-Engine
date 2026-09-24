import SwiftUI

struct ConfigurationView: View {
    @State private var cacheSize: UInt64 = 0
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @Environment(AppSettings.self) private var settings

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                Divider().padding(.horizontal)
                dockSection
                Divider().padding(.horizontal)
                storageSection
                Divider().padding(.horizontal)
                aboutSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }

            Text("StarTorch")
                .font(.system(size: 28, weight: .bold))

            Text("Wallpaper Engine")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var dockSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.showDockIcon) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in Dock")
                        .font(.body)
                    Text("Display the app icon in the Dock and application switcher")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: settings.showDockIcon) { _, newValue in
                applyDockSetting(newValue)
            }
        }
        .padding()
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cached Wallpapers")
                        .font(.body)
                    Text(formatBytes(cacheSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Cache") {
                    cacheManager.clearCache()
                    cacheSize = cacheManager.cacheSize()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(cacheSize == 0)
            }
        }
        .padding()
        .onAppear {
            cacheSize = cacheManager.cacheSize()
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                aboutRow(label: "Version", value: appVersion)
                aboutRow(label: "Creator", value: "shibuyaxpress")
                aboutRow(label: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
            }
        }
        .padding()
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
            Spacer()
        }
        .font(.subheadline)
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

#Preview {
    ConfigurationView()
        .environment(WallpaperCacheManager())
        .environment(AppSettings())
        .frame(width: 400, height: 400)
}
