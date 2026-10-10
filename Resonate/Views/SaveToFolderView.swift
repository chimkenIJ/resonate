import SwiftUI

/// "Save" on a search result: choose a folder, or make a new one.
struct SaveToFolderView: View {
    @State private var model: SaveToFolderViewModel
    @State private var isAddingFolder = false
    @Environment(\.dismiss) private var dismiss

    init(model: SaveToFolderViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Save \(model.place.name)", subtitle: "Pick a folder", style: .appTitle)
                    IconCircleButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
                }

                ForEach(model.folders) { folder in
                    FolderPickRow(folder: folder) {
                        Task { if await model.save(to: folder) { dismiss() } }
                    }
                }

                PillButton(title: "New folder", systemImage: "plus", kind: .secondary) {
                    isAddingFolder = true
                }
            }
            .padding(Metrics.screenPadding)
            .padding(.top, 8)
        }
        .background(Palette.background.ignoresSafeArea())
        .presentationBackground(Palette.background)
        .task { await model.load() }
        .sheet(isPresented: $isAddingFolder) {
            AddFolderView(model: AddFolderViewModel(service: model.service)) { folder in
                if await model.save(to: folder) { dismiss() }
            }
        }
    }
}

private struct FolderPickRow: View {
    let folder: PlaceFolder
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                IconBadge(systemImage: folder.icon.systemImage, accent: folder.accent, diameter: 52, iconSize: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .appFont(.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(folder.countText)
                        .appFont(.rowSubtitle)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.rowBorder, lineWidth: Metrics.borderWidth))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), \(folder.countText)")
        .accessibilityHint("Saves the place here")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    let app = AppModel.preview()
    SaveToFolderView(model: SaveToFolderViewModel(place: SampleData.places[5], service: app.services.savedPlaces, feedback: app.feedback))
        .preferredColorScheme(.dark)
}
