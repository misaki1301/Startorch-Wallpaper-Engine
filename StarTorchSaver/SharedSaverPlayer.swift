import AVFoundation
import os

/// One looping, muted player per process for every full-screen saver instance, so two displays
/// share one decoder instead of each running its own. Instances take a lease while they show the
/// clip and give it back when they tear down; the player is paused and dropped when the last
/// lease is returned.
///
/// The `com.apple.screensaver.willstop` notification also drops the player outright, because the
/// host can keep instances alive (and never tear them down) after the saver has ended.
final class SharedSaverPlayer {
    static let shared = SharedSaverPlayer()

    struct Lease: Equatable {
        fileprivate let id: UUID
        fileprivate let generation: Int
        let player: AVQueuePlayer
        static func == (lhs: Lease, rhs: Lease) -> Bool { lhs.id == rhs.id }
    }

    private static let log = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.saver", category: "player")

    private var url: URL?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var holders = Set<UUID>()
    /// Bumped whenever the player is dropped, so a stale lease can't release a newer player.
    private var generation = 0
    private var willStopObserver: (any NSObjectProtocol)?

    private init() {
        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SharedSaverPlayer.shared.dropPlayer() }
        }
    }

    /// A lease on the player for `url`, starting playback if it isn't running. A different URL
    /// replaces the player for everyone (the handoff only ever holds one clip).
    func acquire(url: URL) -> Lease {
        let current: AVQueuePlayer
        if let player, self.url == url {
            current = player
        } else {
            dropPlayer()
            let item = AVPlayerItem(url: url)
            current = AVQueuePlayer()
            current.isMuted = true
            // The display should still sleep on its own schedule while the saver runs.
            current.preventsDisplaySleepDuringVideoPlayback = false
            current.allowsExternalPlayback = false
            looper = AVPlayerLooper(player: current, templateItem: item)
            player = current
            self.url = url
            Self.log.info("player created for \(url.lastPathComponent, privacy: .public)")
        }
        let lease = Lease(id: UUID(), generation: generation, player: current)
        holders.insert(lease.id)
        current.play()
        return lease
    }

    func release(_ lease: Lease) {
        guard lease.generation == generation, holders.remove(lease.id) != nil else { return }
        if holders.isEmpty { dropPlayer() }
    }

    /// Pauses and forgets the player and looper, whatever leases are still out.
    func dropPlayer() {
        guard player != nil || looper != nil else { return }
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
        url = nil
        holders.removeAll()
        generation += 1
        Self.log.info("player dropped")
    }
}
