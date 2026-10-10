import SwiftUI

/// 60pt round delete button shown in Edit mode. Rose fill with a dark icon (never white on an accent).
struct DeleteButton: View {
    /// What VoiceOver says, for example "Delete Classes folder".
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        IconCircleButton(systemImage: "trash", accessibilityLabel: accessibilityLabel, style: .accent(.rose), action: action)
    }
}
