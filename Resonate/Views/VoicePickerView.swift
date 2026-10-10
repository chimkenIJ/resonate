import SwiftUI

/// Its own screen for choosing the app's voice, so Settings stays short.
/// Tapping a voice selects it and plays a sample right away.
struct VoicePickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: PersonalizeViewModel
    /// The voice being tried. Tapping only plays a sample; the ✓ button saves it.
    @State private var chosen: String?

    init(model: PersonalizeViewModel) {
        self.model = model
        _chosen = State(initialValue: model.voiceID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Voice", subtitle: "Tap a voice to hear it, then tap ✓ to use it.", style: .appTitle)
                    IconCircleButton(systemImage: "checkmark", accessibilityLabel: "Use this voice",
                                     accessibilityHint: "Saves the voice you picked and closes") {
                        if model.voiceID != chosen { model.voiceID = chosen }
                        dismiss()
                    }
                }
                voiceButton(id: nil, name: "Matilda", detail: "Default voice")
                ForEach(model.voices.filter { $0.id != PersonalizeViewModel.defaultVoiceID }) { voice in
                    let parts = voice.name.components(separatedBy: " - ")
                    voiceButton(id: voice.id, name: parts[0], detail: parts.count > 1 ? parts[1] : "")
                }
                if model.voices.isEmpty {
                    Text("More voices appear when you're connected.")
                        .appFont(.footnote)
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .padding(Metrics.screenPadding)
            .padding(.top, 8)
        }
        .background(Palette.background.ignoresSafeArea())
        .presentationBackground(Palette.background)
        .backOnEscape()
    }

    private func voiceButton(id: String?, name: String, detail: String) -> some View {
        let isSelected = (chosen ?? PersonalizeViewModel.defaultVoiceID) == (id ?? PersonalizeViewModel.defaultVoiceID)
        return SelectableCard(title: name, subtitle: detail, systemImage: "waveform", accent: .sand, isSelected: isSelected) {
            chosen = id
            Task { await model.preview(name: name, voiceID: id, using: app.services.speech) }
        }
        .accessibilityHint("Plays a sample. Tap the check mark to use this voice.")
    }
}
