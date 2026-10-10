import SwiftUI

/// One folder's places ("Classes"). Tapping a row opens its route.
struct FolderView: View {
    @Environment(AppModel.self) private var app
    @State private var model: FolderViewModel

    init(model: FolderViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                BackButton(accessibilityLabel: "Back to saved places")

                HStack(spacing: 16) {
                    Image(systemName: model.folder.icon.systemImage)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 20).fill(model.folder.accent.color))
                        .accessibilityHidden(true)
                    ScreenHeader(title: model.folder.name, subtitle: model.countText, style: AppTextStyle(size: 40, weight: .heavy, textStyle: .largeTitle, tracking: -0.03))
                }

                if model.isLoaded && model.places.isEmpty {
                    Text("No places here yet. Search for a place, then tap Save.")
                        .appFont(.body)
                        .foregroundStyle(Palette.textSecondary)
                }

                VStack(spacing: 14) {
                    ForEach(model.places) { saved in
                        PlaceRow(title: saved.place.name, subtitle: saved.routeSummary) {
                            app.router.push(.route(saved.place))
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(saved) }
                            }
                        }
                        .accessibilityAction(named: "Remove") {
                            Task { await model.delete(saved) }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .backOnEscape()
        .task { await model.load() }
    }
}

#Preview {
    let app = AppModel.preview()
    NavigationStack {
        FolderView(model: FolderViewModel(folder: SampleData.folders[0], service: app.services.savedPlaces, feedback: app.feedback))
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
