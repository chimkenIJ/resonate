import SwiftUI

/// "Add a folder": name, color, and icon.
struct AddFolderView: View {
    @State private var model: AddFolderViewModel
    private let onCreated: (PlaceFolder) async -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    init(model: AddFolderViewModel, onCreated: @escaping (PlaceFolder) async -> Void) {
        _model = State(initialValue: model)
        self.onCreated = onCreated
    }

    private let swatchColumns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "New folder", style: .appTitle)
                    IconCircleButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
                }

                section("Name") {
                    TextField("", text: $model.name, prompt: Text("For example, Work").foregroundStyle(Palette.textMuted))
                        .appFont(.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .tint(Palette.textPrimary)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .padding(.horizontal, 20)
                        .frame(minHeight: Metrics.primaryButtonHeight)
                        .background(RoundedRectangle(cornerRadius: Metrics.innerRadius).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.innerRadius).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
                        .accessibilityLabel("Folder name")
                }

                section("Color") {
                    LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 12) {
                        ForEach(Accent.allCases, id: \.self) { accent in
                            let isSelected = model.accent == accent
                            Button { model.accent = accent } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: Metrics.iconButtonSize, height: Metrics.iconButtonSize)
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 22, weight: .heavy))
                                                .foregroundStyle(Palette.onAccent)
                                        }
                                    }
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(isSelected ? Palette.textPrimary : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("\(accent.spokenName) \(isSelected ? "on" : "off")")
                            .accessibilityRemoveTraits([.isButton, .isSelected])
                        }
                    }
                }

                section("Icon") {
                    LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 12) {
                        ForEach(FolderIcon.allCases, id: \.self) { icon in
                            let isSelected = model.icon == icon
                            Button { model.icon = icon } label: {
                                Image(systemName: icon.systemImage)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(isSelected ? Palette.onAccent : Palette.textPrimary)
                                    .frame(width: Metrics.iconButtonSize + 6, height: Metrics.iconButtonSize + 6)
                                    .background(Circle().fill(isSelected ? model.accent.color : Palette.surfaceRaised))
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("\(icon.spokenName) \(isSelected ? "on" : "off")")
                            .accessibilityRemoveTraits([.isButton, .isSelected])
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .appFont(.body)
                        .foregroundStyle(Accent.rose.color)
                }

                PillButton(title: "Make folder", systemImage: "folder.badge.plus") {
                    Task {
                        if let folder = await model.create() {
                            await onCreated(folder)
                            dismiss()
                        }
                    }
                }
                .disabled(!model.canCreate)
            }
            .padding(Metrics.screenPadding)
            .padding(.top, 8)
        }
        .background(Palette.background.ignoresSafeArea())
        .presentationBackground(Palette.background)
        .onAppear { isNameFocused = true }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .appFont(.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

#Preview {
    AddFolderView(model: AddFolderViewModel(service: MockSavedPlacesService())) { _ in }
        .preferredColorScheme(.dark)
}
