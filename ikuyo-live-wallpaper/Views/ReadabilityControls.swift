import SwiftUI

/// Dim, blur, vignette and ambient speed for one wallpaper, plus a warning when menu bar text
/// would be hard to read over it. Changes apply live to the desktop and persist per wallpaper.
struct ReadabilityControls: View {
    @Binding var readability: ReadabilitySettings
    /// Nil until the poster has been analyzed.
    let contrast: MenuBarContrast.Analysis?

    private static let speeds: [Double] = [0.5, 0.75, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Readability")
                    .font(.headline)
                Spacer()
                if !readability.isDefault {
                    Button("Reset") { readability = ReadabilitySettings() }
                        .controlSize(.small)
                }
            }

            if contrast?.isHardToRead == true {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu bar text may be hard to read")
                        Text("The top of this wallpaper mixes light and dark areas. Try dimming it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }

            sliderRow(
                "Dim",
                value: $readability.dim,
                in: ReadabilitySettings.dimRange,
                step: 0.05,
                valueText: readability.dim.formatted(.percent.precision(.fractionLength(0)))
            )
            sliderRow(
                "Blur",
                value: $readability.blur,
                in: ReadabilitySettings.blurRange,
                step: 1,
                valueText: String(localized: "\(Int(readability.blur)) pt")
            )
            if readability.blur > 0 {
                Label("Blurring video uses more energy.", systemImage: "bolt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Vignette", isOn: $readability.vignette)

            Picker("Speed", selection: speedSelection) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(speed)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func sliderRow(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(Text(valueText))
        }
    }

    /// The closest offered speed, so a stored value between steps still selects something.
    private var speedSelection: Binding<Double> {
        Binding(
            get: { Self.speeds.min { abs($0 - readability.speed) < abs($1 - readability.speed) } ?? 1 },
            set: { readability.speed = $0 }
        )
    }
}
