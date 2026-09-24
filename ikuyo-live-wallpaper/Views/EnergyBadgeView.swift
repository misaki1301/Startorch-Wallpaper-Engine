import SwiftUI

/// A small icon + word badge for a wallpaper's `EnergyScore`, shown on gallery cards. Never
/// color alone: the glyph and the word both change between tiers.
struct EnergyBadgeView: View {
    let score: EnergyScore

    var body: some View {
        Label(score.label, systemImage: score.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .help(score.label)
    }
}

#Preview {
    VStack(spacing: 8) {
        ForEach(EnergyScore.allCases, id: \.self) { EnergyBadgeView(score: $0) }
    }
    .padding()
    .background(.gray)
}
