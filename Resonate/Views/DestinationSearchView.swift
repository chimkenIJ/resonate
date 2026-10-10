import SwiftUI

/// No mockup; built in the app's style. Voice or text in, 3–5 closest places out. No map here.
struct DestinationSearchView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: DestinationSearchViewModel
    @State private var placeToSave: Place?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                ScreenHeader(title: "Where to?", subtitle: "Say or type a place in Georgia")

                HStack(spacing: 12) {
                    TextField("", text: $model.query, prompt: Text("Type a place").foregroundStyle(Palette.textMuted))
                        .appFont(.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .tint(Palette.textPrimary)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .focused($isFieldFocused)
                        .onSubmit { Task { await model.search() } }
                        .padding(.horizontal, 20)
                        .frame(minHeight: Metrics.primaryButtonHeight)
                        .background(RoundedRectangle(cornerRadius: Metrics.innerRadius).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.innerRadius).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
                        .accessibilityLabel("Place name")

                    IconCircleButton(
                        systemImage: model.isListening ? "mic.slash.fill" : "mic.fill",
                        accessibilityLabel: model.isListening ? "Turn off microphone" : "Turn on microphone and say a place",
                        style: model.isListening ? .accent(.clay) : .accent(.sand)
                    ) {
                        isFieldFocused = false
                        model.toggleListening()
                    }
                }

                if !model.isListening, !model.query.trimmingCharacters(in: .whitespaces).isEmpty, model.phase != .searching {
                    PillButton(title: "Search", systemImage: "magnifyingglass", accessibilityHint: "Finds places matching what you typed or said") {
                        isFieldFocused = false
                        Task { await model.search() }
                    }
                }

                status

                ForEach(model.results) { place in
                    DestinationResultRow(place: place) {
                        app.router.push(.route(place))
                    } onSave: {
                        placeToSave = place
                    }
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        // Never leave the microphone on behind another screen.
        .onDisappear { model.cancelListening() }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.router.listenRequest) {
            model.handleListenRequest(app.router.listenRequest)
        }
        .sheet(item: $placeToSave) { place in
            SaveToFolderView(model: SaveToFolderViewModel(place: place, service: app.services.savedPlaces, feedback: app.feedback))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text("Try \u{201C}Kroger\u{201D} or \u{201C}Piedmont Park\u{201D}.")
                .appFont(.body)
                .foregroundStyle(Palette.textMuted)
        case .listening:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(Accent.sand.color)
                        .accessibilityHidden(true)
                    Text(model.query.isEmpty ? "Microphone on. Say a place." : model.query)
                        .appFont(.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                }
                .accessibilityElement(children: .combine)
                PillButton(title: "Turn off microphone", systemImage: "mic.slash.fill", kind: .accent(.clay),
                           accessibilityHint: "Stops listening and searches for what you said") {
                    model.stopListening()
                }
            }
        case .searching:
            HStack(spacing: 12) {
                ProgressView().tint(Palette.textPrimary)
                Text("Searching near you…")
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .results:
            Text(model.results.count == 1 ? "1 place" : "\(model.results.count) places, closest first")
                .appFont(.caption)
                .foregroundStyle(Palette.textMuted)
                .accessibilityAddTraits(.isHeader)
        case .failed(let message):
            Text(message)
                .appFont(.body)
                .foregroundStyle(Accent.rose.color)
        }
    }
}

#Preview {
    let app = AppModel.preview()
    NavigationStack {
        DestinationSearchView(model: DestinationSearchViewModel(services: app.services, feedback: app.feedback))
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
