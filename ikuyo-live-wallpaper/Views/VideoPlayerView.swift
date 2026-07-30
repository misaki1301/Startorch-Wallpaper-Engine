import SwiftUI
import AVKit

@MainActor
struct VideoPlayerView: View {
    let player: AVPlayer
    let videoURL: URL
    @State private var isPlaying = false
    @State private var isReady = false
    @Environment(WallpaperManager.self) private var wallpaperManager

    init(url: URL) {
        self.videoURL = url
        self.player = AVPlayer(url: url)
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !isReady {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }

            HStack(spacing: 32) {
                Button(action: seekBackward) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }

                Button(action: seekForward) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
            }

            WallpaperToggleButton(videoURL: videoURL)
                .controlSize(.large)
        }
        .padding()
        .onAppear {
            player.play()
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = status == .playing
            isReady = status != .waitingToPlayAtSpecifiedRate
        }
        .onReceive(player.publisher(for: \.status)) { status in
            if status == .readyToPlay {
                isReady = true
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func seekBackward() {
        let time = CMTimeSubtract(player.currentTime(), CMTime(seconds: 10, preferredTimescale: 600))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func seekForward() {
        let time = CMTimeAdd(player.currentTime(), CMTime(seconds: 10, preferredTimescale: 600))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
