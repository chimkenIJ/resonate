import SwiftUI

/// Bottom navigation: Home, Search, a raised camera button, Saved, Settings.
struct ResonateTabBar: View {
    @Binding var selection: AppTab
    let onCamera: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            item(.home)
            item(.search)
            cameraButton
            item(.saved)
            item(.settings)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(Palette.surface)
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                        .stroke(Palette.border, lineWidth: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        // Labels stop growing at very large sizes; long-press shows the Large Content Viewer instead.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func item(_ tab: AppTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(height: 28)
                Text(tab.title)
                    .appFont(.chip)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textMuted)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(tab.title) \(isSelected ? "on" : "off")")
        .accessibilityRemoveTraits([.isButton, .isSelected])
        .accessibilityShowsLargeContentViewer {
            Image(systemName: tab.selectedIcon)
            Text(tab.title)
        }
    }

    private var cameraButton: some View {
        Button(action: onCamera) {
            Image(systemName: "camera.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Accent.sand.color))
                .overlay(Circle().stroke(Palette.background, lineWidth: 5))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .frame(maxWidth: .infinity)
        .offset(y: -20)
        .accessibilityLabel("Camera")
        .accessibilityRemoveTraits(.isButton)
        .accessibilityHint("Starts watching for obstacles ahead")
        .accessibilityShowsLargeContentViewer {
            Image(systemName: "camera.fill")
            Text("Camera")
        }
    }
}

#Preview {
    @Previewable @State var tab = AppTab.home
    VStack {
        Spacer()
        ResonateTabBar(selection: $tab) {}
    }
    .background(Palette.background)
}
