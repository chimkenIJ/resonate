import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    private var needs: Set<AssistNeed> { app.preferences.needs }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tileCount: Int {
        (needs.contains(.gettingAround) ? 2 : 0) + (needs.contains(.colors) ? 1 : 0) + 1
    }

    var body: some View {
        // One screen, no scrolling: the tiles split the height that's left above the tab bar.
        // At the largest accessibility text sizes the text can't fit, so it scrolls instead.
        GeometryReader { geometry in
            let spacing: CGFloat = 16
            let chrome: CGFloat = 4 + 40 + 12 + 28 // top padding, title, gap, room for the raised camera button
            let tileHeight = (geometry.size.height - chrome - spacing * CGFloat(tileCount - 1)) / CGFloat(tileCount)
            if dynamicTypeSize.isAccessibilitySize || tileHeight < 96 {
                ScrollView { content(tileHeight: nil) }
            } else {
                content(tileHeight: tileHeight)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    /// `tileHeight` nil means natural height (scrolling layout).
    private func content(tileHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resonate")
                .appFont(.appTitle)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(height: tileHeight == nil ? nil : 40, alignment: .leading)

            // Yellow, green, blue, purple from top to bottom.
            VStack(spacing: 16) {
                if needs.contains(.gettingAround) {
                    tile("Walk outside", "Warns you about obstacles", "location", .sand, tileHeight) {
                        app.router.cover = .walk(nil)
                    }
                }
                tile("Search", "Find a place and get a route there", "magnifyingglass", .sage, tileHeight) {
                    app.router.openSearch(listen: false)
                }
                if needs.contains(.gettingAround) {
                    tile("Scan indoors", "Finds walls, doors, and things", "viewfinder", .slate, tileHeight) {
                        app.router.cover = .indoor
                    }
                }
                if needs.contains(.colors) {
                    tile("Name colors", "Point at something to hear its color", "paintpalette", .mauve, tileHeight) {
                        app.router.cover = .colors
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 28)
    }

    private func tile(_ title: String, _ subtitle: String, _ icon: String, _ accent: Accent,
                      _ height: CGFloat?, action: @escaping () -> Void) -> some View {
        FeatureTile(title: title, subtitle: subtitle, systemImage: icon, accent: accent,
                    minHeight: height ?? Metrics.tileHeight, action: action)
            .frame(height: height)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
