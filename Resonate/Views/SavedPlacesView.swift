import SwiftUI

struct SavedPlacesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: SavedPlacesViewModel
    @State private var isAddingFolder = false

    init(model: SavedPlacesViewModel) {
        _model = State(initialValue: model)
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Saved places", subtitle: model.subtitle)
                    IconCircleButton(systemImage: "plus", accessibilityLabel: "Add a folder") {
                        isAddingFolder = true
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .appFont(.body)
                        .foregroundStyle(Accent.rose.color)
                }

                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(model.folders) { folder in
                        FolderCard(folder: folder) {
                            app.router.push(.folder(folder))
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(GridBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .sheet(isPresented: $isAddingFolder) {
            AddFolderView(model: AddFolderViewModel(service: app.services.savedPlaces)) { folder in
                await model.load()
                await app.feedback.announce("Made the \(folder.name) folder.", priority: .info)
            }
        }
    }
}

#Preview {
    let app = AppModel.preview()
    NavigationStack {
        SavedPlacesView(model: SavedPlacesViewModel(service: app.services.savedPlaces))
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
