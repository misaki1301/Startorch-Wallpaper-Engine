import SwiftUI

/// Wraps `ContentView` with the first-run onboarding sheet, so the sheet's presentation logic
/// stays out of `ContentView` itself. Shown once, gated by `AppSettings.hasCompletedOnboarding`;
/// "Show Welcome Again" in Settings resets it, and it never appears under the test host.
struct AppRootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isShowingOnboarding = false

    var body: some View {
        ContentView()
            .sheet(isPresented: $isShowingOnboarding) {
                OnboardingView(isPresented: $isShowingOnboarding)
            }
            .onAppear {
                if !AppEnvironment.isHostingTests && !settings.hasCompletedOnboarding {
                    isShowingOnboarding = true
                }
            }
            .onChange(of: settings.hasCompletedOnboarding) { _, hasCompleted in
                // "Show Welcome Again" in Settings sets this back to false.
                if !hasCompleted { isShowingOnboarding = true }
            }
    }
}

#Preview {
    AppRootView()
        .environment(WallpaperManager())
        .environment(AppSettings())
        .environment(WallpaperLibrary())
        .environment(WallpaperCacheManager())
        .environment(ImportedWallpaperStore())
}
