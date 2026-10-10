import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    private var needs: Set<AssistNeed> { app.preferences.needs }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.largeGap) {
                Text("Resonate")
                    .appFont(.appTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)

                VoiceSearchCard {
                    app.router.openSearch(listen: true)
                }

                VStack(spacing: Metrics.itemGap) {
                    if needs.contains(.gettingAround) {
                        FeatureTile(title: "Walk outside", subtitle: "Warns you about obstacles", systemImage: "location", accent: .sand) {
                            app.router.cover = .walk(nil)
                        }
                        FeatureTile(title: "Scan indoors", subtitle: "Finds walls, doors, and things", systemImage: "viewfinder", accent: .sage) {
                            app.router.cover = .indoor
                        }
                    }
                    if needs.contains(.colors) {
                        FeatureTile(title: "Name colors", subtitle: "Point at something to hear its color", systemImage: "paintpalette", accent: .mauve) {
                            app.router.cover = .colors
                        }
                    }
                    FeatureTile(title: "Saved places", subtitle: "Classes, home, and more", systemImage: "folder", accent: .slate) {
                        app.router.tab = .saved
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}
