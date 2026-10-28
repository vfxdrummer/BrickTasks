import Features
import SwiftUI

struct BannerView: View {
    let banner: Banner

    var body: some View {
        Label(banner.message, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(color)
            .accessibilityIdentifier("banner")
    }

    private var icon: String {
        switch banner.style {
        case .offline: "wifi.slash"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    private var color: Color {
        switch banner.style {
        case .offline: .orange
        case .warning: .yellow
        case .error: .red
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Runs `tick` every 30 seconds while the view is on screen, so overdue state stays current.
struct TickModifier: ViewModifier {
    let tick: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick()
            }
        }
    }
}
