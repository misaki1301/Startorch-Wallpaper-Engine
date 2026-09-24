import Foundation

/// A rough, reassuring read of how much a wallpaper video costs to decode and display — not a
/// real power measurement, just Low/Medium/High so a card's badge means something at a glance.
nonisolated enum EnergyScore: String, CaseIterable, Sendable, Comparable {
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .low: String(localized: "energyScore.low", defaultValue: "Low Energy")
        case .medium: String(localized: "energyScore.medium", defaultValue: "Medium Energy")
        case .high: String(localized: "energyScore.high", defaultValue: "High Energy")
        }
    }

    /// Never relies on color alone: each tier gets its own glyph.
    var systemImage: String {
        switch self {
        case .low: "leaf.fill"
        case .medium: "bolt.fill"
        case .high: "bolt.fill.batteryblock.fill"
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (lhs: EnergyScore, rhs: EnergyScore) -> Bool { lhs.rank < rhs.rank }

    private func bumped() -> EnergyScore {
        switch self {
        case .low: .medium
        case .medium, .high: .high
        }
    }

    /// Scores from raw video metadata. The resolution sets a baseline tier (720p → Low, up to
    /// 1080p → Medium, larger → High); an above-baseline frame rate or bitrate can each bump that
    /// baseline up by one tier, capped at High. A missing value never bumps — the most generous
    /// reading — so a catalog entry or probe that's missing a field never scores higher than what
    /// it actually knows.
    static func score(width: Int?, height: Int?, fps: Double?, bitrate: Int?) -> EnergyScore {
        let pixels = (width ?? 0) * (height ?? 0)
        var tier = resolutionBaseline(pixels)
        if let fps, fps > 30 { tier = tier.bumped() }
        if let bitrate, bitrate > 6_000_000 { tier = tier.bumped() }
        return tier
    }

    /// 720p or smaller: Low. Up to 1080p: Medium. Larger (1440p, 4K, …): High.
    private static func resolutionBaseline(_ pixels: Int) -> EnergyScore {
        switch pixels {
        case ..<(1_280 * 720 + 1): .low
        case ..<(1_920 * 1_080 + 1): .medium
        default: .high
        }
    }
}
