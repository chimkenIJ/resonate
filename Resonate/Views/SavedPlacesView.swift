import SwiftUI

struct SavedPlacesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: SavedPlacesViewModel
    @State private var isAddingFolder = false
    @State private var isEditing = false
    @State private var folderToDelete: PlaceFolder?

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
                HStack(alignment: .top, spacing: 10) {
                    ScreenHeader(title: "Saved places", subtitle: model.subtitle)
                    IconCircleButton(systemImage: isEditing ? "checkmark" : "pencil",
                                     accessibilityLabel: isEditing ? "Done editing" : "Edit folders",
                                     accessibilityHint: isEditing ? nil : "Shows a delete button on each folder") {
                        isEditing.toggle()
                    }
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
                        .overlay(alignment: .topTrailing) {
                            if isEditing {
                                DeleteButton(accessibilityLabel: "Delete \(folder.name) folder") { folderToDelete = folder }
                                    .offset(x: 8, y: 20)
                            }
                        }
                        .contextMenu {
                            Button("Delete folder", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                        }
                        .accessibilityAction(named: "Delete folder") { folderToDelete = folder }
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
        .onChange(of: isAddingFolder) { _, _ in app.feedback.endScreenSpeech() }
        .confirmationDialog(
            folderToDelete.map { "Delete \($0.name) and its \($0.countText)?" } ?? "",
            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
            titleVisibility: .visible,
            presenting: folderToDelete
        ) { folder in
            Button("Delete folder", role: .destructive) {
                Task {
                    let generation = app.feedback.screenGeneration
                    let message = await model.delete(folder)
                    if generation == app.feedback.screenGeneration {
                        await app.feedback.announce(message, priority: .info)
                    }
                    if model.folders.isEmpty { isEditing = false }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isAddingFolder) {
            AddFolderView(model: AddFolderViewModel(service: app.services.savedPlaces)) { folder in
                let generation = app.feedback.screenGeneration
                await model.load()
                if generation == app.feedback.screenGeneration {
                    await app.feedback.announce("Made the \(folder.name) folder.", priority: .info)
                }
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
