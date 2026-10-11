import SwiftUI

/// One folder's places ("Classes"). Tapping a row opens its route.
struct FolderView: View {
    @Environment(AppModel.self) private var app
    @State private var model: FolderViewModel
    @State private var isEditing = false
    @State private var placeToDelete: SavedPlace?
    @State private var confirmingFolderDelete = false
    @Environment(\.dismiss) private var dismiss

    init(model: FolderViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                HStack {
                    BackButton(accessibilityLabel: "Back to saved places")
                    Spacer()
                    IconCircleButton(systemImage: isEditing ? "checkmark" : "pencil",
                                     accessibilityLabel: isEditing ? "Done editing" : "Edit this folder",
                                     accessibilityHint: isEditing ? nil : "Shows delete buttons") {
                        isEditing.toggle()
                    }
                    // Top right, where the route and camera screens have their microphone too.
                    if app.assistant.isEnabled {
                        AssistantTalkButton(assistant: app.assistant, diameter: 60)
                    }
                }

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
                        HStack(spacing: 10) {
                            PlaceRow(title: saved.place.name, subtitle: saved.routeSummary) {
                                app.router.push(.route(saved.place))
                            }
                            if isEditing {
                                DeleteButton(accessibilityLabel: "Delete \(saved.place.name)") { placeToDelete = saved }
                            }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) { placeToDelete = saved }
                        }
                        .accessibilityAction(named: "Delete") { placeToDelete = saved }
                    }
                }

                if isEditing {
                    PillButton(title: "Delete this folder", systemImage: "trash", kind: .accent(.rose),
                               accessibilityHint: "Deletes the folder and every place in it") {
                        confirmingFolderDelete = true
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
        .confirmationDialog(
            placeToDelete.map { "Delete \($0.place.name)?" } ?? "",
            isPresented: Binding(get: { placeToDelete != nil }, set: { if !$0 { placeToDelete = nil } }),
            titleVisibility: .visible,
            presenting: placeToDelete
        ) { saved in
            Button("Delete", role: .destructive) { Task { await model.delete(saved) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(model.folder.name) and its \(model.countText)?",
                            isPresented: $confirmingFolderDelete, titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                Task { if await model.deleteFolder() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        }
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
