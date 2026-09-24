import Foundation

enum AppEnvironment {
    /// True when the app was launched as the host for unit tests. Launch-time side effects
    /// (touching the desktop picture, resuming a wallpaper) are skipped in that case.
    nonisolated static let isHostingTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()
}
