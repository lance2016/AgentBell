import AppKit
import SwiftUI

struct BellAppIcon: View {
    let size: CGFloat

    // Load from the current bundle directly, so the panel and About page show
    // the artwork shipped with this build even if the system icon is cached.
    private static let artwork = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Image(nsImage: Self.artwork ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            // The bundle icon includes transparent margins around the artwork.
            .frame(width: size * 1.2, height: size * 1.2)
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
    }
}
