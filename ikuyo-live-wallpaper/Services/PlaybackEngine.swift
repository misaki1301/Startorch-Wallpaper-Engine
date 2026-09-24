import AVFoundation

/// Plays one wallpaper video on a loop. The manager talks to this protocol so its logic can be
/// tested without decoding video.
protocol WallpaperPlayback: AnyObject {
    /// Shared by every display's player layer.
    var player: AVPlayer { get }
    var isPlaying: Bool { get }
    func play()
    func pause()
    /// Stops for good and releases the looper. The engine can't be restarted afterwards.
    func tearDown()
}

/// An `AVQueuePlayer` + `AVPlayerLooper` for a single URL, muted and streamed from disk.
final class PlaybackEngine: WallpaperPlayback {
    private let queuePlayer: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private(set) var isPlaying = false

    var player: AVPlayer { queuePlayer }

    init(url: URL) {
        // AVFoundation only buffers what it needs; AVPlayerLooper clones the template item into
        // the queue for gapless looping.
        let templateItem = AVPlayerItem(url: url)
        templateItem.preferredForwardBufferDuration = 0
        queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        // A wallpaper must never keep the display awake.
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
    }

    func play() {
        guard !isPlaying, looper != nil else { return }
        queuePlayer.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        queuePlayer.pause()
        isPlaying = false
    }

    func tearDown() {
        pause()
        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()
    }
}
