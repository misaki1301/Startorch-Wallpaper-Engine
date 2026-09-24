import SwiftUI

/// The app's single `Settings` scene (⌘,). A grouped form is the standard Mac layout for
/// preferences, so this is the one place StarTorch's settings live — there's no longer a
/// sidebar page duplicating it.
struct SettingsView: View {
    @State private var cacheSize: UInt64 = 0
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @Environment(AppSettings.self) private var settings
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperLibrary.self) private var library
    @Environment(ImportedWallpaperStore.self) private var importedStore
    @Environment(ScheduleService.self) private var scheduleService
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var isShowingEnergySummary = false

    var body: some View {
        Form {
            generalSection
            whenToPauseSection
            scheduleSection
            energySection
            storageSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onAppear {
            cacheSize = cacheManager.cacheSize()
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have changed Login Items in System Settings meanwhile.
            launchAtLogin.refresh()
        }
        .sheet(isPresented: $isShowingEnergySummary) {
            EnergyWeeklySummaryView(days: manager.stats.recentDays())
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

            Button("Show Welcome Again") {
                settings.hasCompletedOnboarding = false
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

    // MARK: Schedule

    private var scheduleSection: some View {
        @Bindable var scheduleService = scheduleService
        return Section {
            Toggle("Rotate wallpapers on a schedule", isOn: Binding(
                get: { scheduleService.schedule.isEnabled },
                set: { scheduleService.schedule.isEnabled = $0 }
            ))

            if scheduleService.schedule.isEnabled {
                ForEach(scheduleService.schedule.sortedSlots) { slot in
                    scheduleSlotRow(slot)
                }
                Button("Add Time Slot") { addSlot() }
                    .disabled(library.catalog.isEmpty && importedStore.items.isEmpty)

                Divider()

                LabeledContent("Light Appearance") {
                    ScheduleTargetPicker(
                        target: Binding(
                            get: { scheduleService.schedule.appearance.light },
                            set: { scheduleService.schedule.appearance.light = $0 }
                        ),
                        catalog: library.catalog,
                        imported: importedStore.items,
                        collections: library.collections
                    )
                }
                LabeledContent("Dark Appearance") {
                    ScheduleTargetPicker(
                        target: Binding(
                            get: { scheduleService.schedule.appearance.dark },
                            set: { scheduleService.schedule.appearance.dark = $0 }
                        ),
                        catalog: library.catalog,
                        imported: importedStore.items,
                        collections: library.collections
                    )
                }

                if scheduleService.isSuspendedByManualPick {
                    Label(
                        "You picked a wallpaper yourself, so the schedule is paused until its next change.",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Picking a wallpaper yourself pauses the schedule until the next time slot or appearance change. It never fights a wallpaper you paused.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func scheduleSlotRow(_ slot: ScheduleSlot) -> some View {
        @Bindable var scheduleService = scheduleService
        let index = scheduleService.schedule.slots.firstIndex { $0.id == slot.id }
        return HStack {
            TextField("Name", text: Binding(
                get: { slot.name },
                set: { newValue in
                    guard let index else { return }
                    scheduleService.schedule.slots[index].name = newValue
                }
            ))
            .frame(width: 90)

            DatePicker(
                "",
                selection: Binding(
                    get: { timeOfDayDate(hour: slot.startHour, minute: slot.startMinute) },
                    set: { newValue in
                        guard let index else { return }
                        let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        scheduleService.schedule.slots[index].startHour = components.hour ?? 0
                        scheduleService.schedule.slots[index].startMinute = components.minute ?? 0
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .frame(width: 90)

            ScheduleTargetPicker(
                target: Binding(
                    get: { slot.target },
                    set: { newValue in
                        guard let index, let newValue else { return }
                        scheduleService.schedule.slots[index].target = newValue
                    }
                ),
                catalog: library.catalog,
                imported: importedStore.items,
                collections: library.collections
            )

            Button {
                scheduleService.schedule.slots.removeAll { $0.id == slot.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove Time Slot")
        }
    }

    private func addSlot() {
        let fallbackItem = library.catalog.first ?? importedStore.items.first
        guard let target = fallbackItem.map({ ScheduleTarget.wallpaper($0.url) }) else { return }
        let slot = ScheduleSlot(name: "New Slot", startHour: 12, startMinute: 0, target: target)
        scheduleService.schedule.slots.append(slot)
    }

    private func timeOfDayDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private var energySection: some View {
        Section("Energy") {
            Button("View Weekly Summary…") {
                isShowingEnergySummary = true
            }
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

/// A menu that picks a schedule slot or appearance variant's target: a catalog or imported
/// wallpaper, or a collection. `target` is `nil` only before the first pick (an appearance
/// variant starts unset); once set, it stays a valid `ScheduleTarget`.
private struct ScheduleTargetPicker: View {
    @Binding var target: ScheduleTarget?
    let catalog: [WallpaperItem]
    let imported: [WallpaperItem]
    let collections: [WallpaperCollection]

    var body: some View {
        Menu(label) {
            if target != nil {
                Button("None") { target = nil }
                Divider()
            }
            if !catalog.isEmpty {
                Section("Gallery") {
                    ForEach(catalog) { item in
                        Button(item.name) { target = .wallpaper(item.url) }
                    }
                }
            }
            if !imported.isEmpty {
                Section("My Files") {
                    ForEach(imported) { item in
                        Button(item.name) { target = .wallpaper(item.url) }
                    }
                }
            }
            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { collection in
                        Button(collection.name) { target = .collection(collection.id) }
                    }
                }
            }
        }
        .fixedSize()
    }

    private var label: String {
        guard let target else { return String(localized: "None") }
        switch target {
        case .wallpaper(let url):
            return (catalog + imported).first { $0.url == url }?.name
                ?? url.deletingPathExtension().lastPathComponent
        case .collection(let id):
            return collections.first { $0.id == id }?.name
                ?? String(localized: "Deleted Collection")
        }
    }
}

#Preview {
    let settings = AppSettings()
    let library = WallpaperLibrary()
    let manager = WallpaperManager()
    SettingsView()
        .environment(WallpaperCacheManager())
        .environment(settings)
        .environment(manager)
        .environment(library)
        .environment(ImportedWallpaperStore())
        .environment(ScheduleService(manager: manager, library: library, settings: settings, observeSystemEvents: false))
}
