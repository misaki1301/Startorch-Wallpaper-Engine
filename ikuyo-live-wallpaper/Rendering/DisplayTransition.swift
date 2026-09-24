import Foundation

/// What happens on one display when a new layout is presented.
nonisolated enum DisplayTransition: Equatable, Sendable {
    /// Same player: only readability changes apply, playback is untouched.
    case update
    /// A different player (another wallpaper, or the same one restarted): the new video fades in
    /// over the old one, which is removed afterwards.
    case crossfade
    /// A display that had no wallpaper window: the window fades in over the desktop picture.
    case fadeIn
    /// The display lost its wallpaper or was disconnected.
    case remove

    /// How long fades take; instant when Reduce Motion is on.
    static func duration(reduceMotion: Bool) -> Duration {
        reduceMotion ? .zero : .milliseconds(600)
    }

    /// Compares the player each display shows now with the one it should show.
    static func plan<Player: Hashable>(current: [String: Player], target: [String: Player]) -> [String: DisplayTransition] {
        var plan: [String: DisplayTransition] = [:]
        for id in current.keys where target[id] == nil {
            plan[id] = .remove
        }
        for (id, player) in target {
            switch current[id] {
            case nil: plan[id] = .fadeIn
            case player: plan[id] = .update
            default: plan[id] = .crossfade
            }
        }
        return plan
    }
}

extension Duration {
    /// For Core Animation and AppKit animation APIs.
    nonisolated var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
