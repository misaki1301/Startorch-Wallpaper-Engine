import SwiftUI

struct SplashAnimationView: View {
    @State private var opacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var time: Double = 0

    var body: some View {
        ZStack {
            animatingBackground

            VStack(spacing: 12) {
                Spacer()

                Text("ikuyo")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.orange, Color.accentColor]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(titleOpacity)

                Text("Live Wallpaper")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .opacity(titleOpacity)

                Spacer().frame(height: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear(perform: startAnimation)
    }

    private var animatingBackground: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08)

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [.orange.opacity(0.3), .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
                .offset(
                    x: -120 + 60 * sin(time * 0.7),
                    y: -200 + 60 * cos(time * 0.8)
                )

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [.accentColor.opacity(0.25), .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .offset(
                    x: 130 + 70 * sin(time * 0.5 + 1),
                    y: 150 + 50 * cos(time * 0.6 + 2)
                )

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [.purple.opacity(0.2), .clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 250
                    )
                )
                .offset(
                    x: 50 * sin(time * 0.4 + 3),
                    y: -50 + 80 * cos(time * 0.3 + 1)
                )
        }
        .ignoresSafeArea()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                time += 0.016
            }
        }
    }

    private func startAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            opacity = 1
        }

        withAnimation(.easeOut(duration: 0.6).delay(0.8)) {
            titleOpacity = 1
        }
    }
}

#Preview {
    SplashAnimationView()
}
