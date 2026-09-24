import SwiftUI

/// The first-run walkthrough shown from `AppRootView`: pick a wallpaper, choose pause rules and
/// Launch at Login, then a reassurance note about the desktop picture. Skippable at every step;
/// finishing or skipping both set `AppSettings.hasCompletedOnboarding`.
struct OnboardingView: View {
    @Binding var isPresented: Bool

    @Environment(AppSettings.self) private var settings
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperManager.self) private var manager
    @SceneStorage("sidebarSelection") private var sidebarSelection: SidebarItem = .gallery

    @State private var step = 0
    @State private var chosenURL: URL?
    @State private var launchAtLogin = LaunchAtLogin()

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .onAppear { launchAtLogin.refresh() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .padding(.top, 20)
            Text("Welcome to StarTorch")
                .font(.title2.bold())
            Text(stepTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(step + 1), total: Double(totalSteps))
                .frame(width: 200)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(step + 1) of \(totalSteps): \(stepTitle)"))
    }

    private var stepTitle: String {
        switch step {
        case 0: String(localized: "Choose your first wallpaper")
        case 1: String(localized: "Choose when it should pause")
        default: String(localized: "You're all set")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: pickWallpaperStep
        case 1: pauseRulesStep
        default: reassuranceStep
        }
    }

    // MARK: - Step 1: pick a wallpaper

    private var pickWallpaperStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick a wallpaper from the gallery to start with, or import your own video.")
                .fixedSize(horizontal: false, vertical: true)

            if library.catalog.isEmpty {
                ContentUnavailableView(
                    "No Wallpapers Yet",
                    systemImage: "sparkles.tv",
                    description: Text("Import your own video, or continue and pick one later.")
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    ForEach(library.catalog.prefix(6)) { item in
                        wallpaperChoiceButton(item)
                    }
                }
            }

            Button("Import a Video from My Mac…") {
                sidebarSelection = .myFiles
                finish(startWallpaper: false)
            }
            .buttonStyle(.link)
        }
    }

    private func wallpaperChoiceButton(_ item: WallpaperItem) -> some View {
        let isChosen = chosenURL == item.url
        return Button {
            chosenURL = item.url
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.fill.quaternary)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isChosen ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: isChosen ? 2 : 0.5)
                    )
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Step 2: pause rules + launch at login

    private var pauseRulesStep: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 16) {
            Text("StarTorch pauses automatically so it never gets in your way. It always pauses while the display is asleep or the screen is locked.")
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Pause when the desktop is covered", isOn: $settings.pauseWhenDesktopCovered)
            Toggle("Pause when an app is full screen", isOn: $settings.pauseForFullScreenApps)
            Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPowerMode)
            Toggle("Pause on battery", isOn: $settings.pauseOnBattery)

            Divider()

            Toggle(isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            )) {
                Text("Launch StarTorch at Login")
            }
        }
    }

    // MARK: - Step 3: reassurance

    private var reassuranceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your original desktop picture is safe.", systemImage: "checkmark.shield.fill")
                .font(.headline)
            Text("StarTorch remembers the picture each display had before it started, and puts it back the moment you stop the wallpaper, quit the app, or restart your Mac.")
                .fixedSize(horizontal: false, vertical: true)
            Text("StarTorch lives in the menu bar. Click its icon any time for Play, Pause, Stop and your favorites.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip") { finish(startWallpaper: false) }
                .buttonStyle(.link)
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Button(step == totalSteps - 1 ? "Get Started" : "Continue") {
                if step == totalSteps - 1 {
                    finish(startWallpaper: true)
                } else {
                    step += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func finish(startWallpaper: Bool) {
        settings.hasCompletedOnboarding = true
        if startWallpaper, let chosenURL {
            manager.start(with: chosenURL)
        }
        isPresented = false
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .environment(AppSettings())
        .environment(WallpaperLibrary())
        .environment(WallpaperManager())
}
