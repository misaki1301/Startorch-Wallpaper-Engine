import AVFoundation
import Observation

/// Drives the import studio's preview. Normally it plays the source clip, looping inside the
/// trim range, and the timeline seeks it. "Preview Seam" swaps in the rendered loop
/// composition and repeats the couple of seconds around the wrap, so the crossfade can be
/// judged exactly as it will be exported.
@MainActor
@Observable
final class ImportPreviewPlayer {
    enum Mode: Equatable {
        /// The source file; times are source seconds.
        case clip
        /// The rendered loop; plays `[seamStart, end]` then `[0, seamEnd]` over and over.
        case seam(seamStart: Double, seamEnd: Double)
    }

    /// How much of each side of the seam `previewSeam` shows, in seconds.
    static let seamWindow: Double = 1

    @ObservationIgnored let player = AVPlayer()
    /// The playhead in source seconds while in `.clip` mode.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var mode: Mode = .clip

    @ObservationIgnored private let sourceItem: AVPlayerItem
    @ObservationIgnored private var range: ClosedRange<Double> = 0...0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    init(url: URL) {
        sourceItem = AVPlayerItem(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: sourceItem)
        observeEnd(of: sourceItem)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.mode == .clip, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }
    }

    /// Stops playback and removes the observers. Call when the preview goes away.
    func invalidate() {
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeSeamObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    /// The trimmed range playback loops within.
    func setRange(_ newRange: ClosedRange<Double>) {
        range = newRange
        sourceItem.forwardPlaybackEndTime = CMTime(seconds: newRange.upperBound, preferredTimescale: 600)
        if mode == .clip, !newRange.contains(currentTime) {
            seek(to: newRange.lowerBound)
        }
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Shows the source frame at `seconds` exactly, leaving seam preview if it was on.
    func seek(to seconds: Double) {
        leaveSeamPreview()
        currentTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Plays `composition` around its loop point: from `seamWindow` before the end, through
    /// the wrap, to `seamWindow` after the start, then again.
    func previewSeam(of composition: StudioComposition) {
        removeSeamObservers()
        let item = AVPlayerItem(asset: composition.asset)
        item.videoComposition = composition.videoComposition

        let duration = composition.plan.outputDuration.seconds
        let window = min(Self.seamWindow, duration / 2)
        let seamStart = max(0, duration - window)
        mode = .seam(seamStart: seamStart, seamEnd: window)

        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: window, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.restartSeamWindow() }
        }
        player.seek(to: CMTime(seconds: seamStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        play()
    }

    /// Back to the source clip at the current playhead.
    func leaveSeamPreview() {
        guard mode != .clip else { return }
        removeSeamObservers()
        mode = .clip
        player.replaceCurrentItem(with: sourceItem)
        observeEnd(of: sourceItem)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Looping

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        }
    }

    private func didPlayToEnd() {
        switch mode {
        case .clip:
            seek(to: range.lowerBound)
        case .seam:
            // The wrap itself: straight on to the start of the loop, like the desktop does.
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying { player.play() }
    }

    private func restartSeamWindow() {
        guard case .seam(let seamStart, _) = mode else { return }
        player.seek(to: CMTime(seconds: seamStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func removeSeamObservers() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }
}
