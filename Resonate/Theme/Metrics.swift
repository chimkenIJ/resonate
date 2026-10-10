import SwiftUI

/// Shape and spacing tokens from DESIGN_SPEC.md.
enum Metrics {
    static let screenPadding: CGFloat = 20
    static let screenTopPadding: CGFloat = 60
    static let sectionGap: CGFloat = 24
    static let largeGap: CGFloat = 28
    static let itemGap: CGFloat = 20

    /// Every interactive element is at least this tall and wide.
    static let minTouchTarget: CGFloat = 60
    static let primaryButtonHeight: CGFloat = 64
    static let iconButtonSize: CGFloat = 60
    /// Upper bound for icon buttons at the largest accessibility text sizes.
    static let iconButtonMaxSize: CGFloat = 88

    static let tileHeight: CGFloat = 128
    static let searchCardHeight: CGFloat = 156
    static let placeRowHeight: CGFloat = 92
    static let folderCardHeight: CGFloat = 160
    static let optionCardHeight: CGFloat = 80

    static let tileRadius: CGFloat = 30
    static let searchCardRadius: CGFloat = 32
    static let sheetRadius: CGFloat = 34
    static let rowRadius: CGFloat = 26
    static let optionRadius: CGFloat = 24
    static let innerRadius: CGFloat = 22
    static let tagRadius: CGFloat = 12
    static let borderWidth: CGFloat = 2
}

/// Dims a control while pressed. No scaling, so Reduce Motion needs no special case.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
