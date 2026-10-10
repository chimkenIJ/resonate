import SwiftUI

/// Atkinson Hyperlegible Next weights bundled in Resources/Fonts (registered via UIAppFonts).
enum AppFontWeight {
    case regular, semibold, bold, heavy

    var postScriptName: String {
        switch self {
        case .regular: "AtkinsonHyperlegibleNext-Regular"
        case .semibold: "AtkinsonHyperlegibleNext-SemiBold"
        case .bold: "AtkinsonHyperlegibleNext-Bold"
        case .heavy: "AtkinsonHyperlegibleNext-ExtraBold"
        }
    }

    /// One step heavier, used when the system Bold Text setting is on.
    var bolder: AppFontWeight {
        switch self {
        case .regular: .semibold
        case .semibold: .bold
        case .bold, .heavy: .heavy
        }
    }
}

/// A named text style. Sizes come from the mockups and scale with Dynamic Type
/// relative to `textStyle`. Nothing is smaller than 15pt.
struct AppTextStyle {
    let size: CGFloat
    let weight: AppFontWeight
    let textStyle: Font.TextStyle
    /// Letter spacing in em, matching the CSS `letter-spacing` values.
    var tracking: CGFloat = 0

    static let screenTitle = AppTextStyle(size: 42, weight: .heavy, textStyle: .largeTitle, tracking: -0.03)
    static let onboardingTitle = AppTextStyle(size: 36, weight: .heavy, textStyle: .largeTitle, tracking: -0.02)
    static let routeSummary = AppTextStyle(size: 34, weight: .heavy, textStyle: .largeTitle, tracking: -0.02)
    static let appTitle = AppTextStyle(size: 30, weight: .heavy, textStyle: .title, tracking: -0.02)
    static let searchPrompt = AppTextStyle(size: 30, weight: .heavy, textStyle: .title, tracking: -0.01)
    static let alertHeadline = AppTextStyle(size: 30, weight: .heavy, textStyle: .title, tracking: -0.02)
    static let tileTitle = AppTextStyle(size: 26, weight: .heavy, textStyle: .title2)
    static let indoorHeadline = AppTextStyle(size: 26, weight: .heavy, textStyle: .title2, tracking: -0.01)
    static let rowTitle = AppTextStyle(size: 22, weight: .heavy, textStyle: .title3)
    static let sectionTitle = AppTextStyle(size: 20, weight: .heavy, textStyle: .title3)
    static let optionTitle = AppTextStyle(size: 19, weight: .heavy, textStyle: .headline)
    static let primaryButton = AppTextStyle(size: 19, weight: .heavy, textStyle: .headline)
    static let bodyLarge = AppTextStyle(size: 18, weight: .semibold, textStyle: .body)
    static let body = AppTextStyle(size: 17, weight: .semibold, textStyle: .body)
    static let bodyBold = AppTextStyle(size: 17, weight: .bold, textStyle: .body)
    static let secondaryButton = AppTextStyle(size: 17, weight: .bold, textStyle: .body)
    static let rowSubtitle = AppTextStyle(size: 16, weight: .semibold, textStyle: .callout)
    static let caption = AppTextStyle(size: 16, weight: .bold, textStyle: .callout)
    static let label = AppTextStyle(size: 15, weight: .heavy, textStyle: .footnote)
    static let chip = AppTextStyle(size: 15, weight: .bold, textStyle: .footnote)
    static let footnote = AppTextStyle(size: 15, weight: .semibold, textStyle: .footnote)
}

private struct AppFontModifier: ViewModifier {
    let style: AppTextStyle
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        let weight = legibilityWeight == .bold ? style.weight.bolder : style.weight
        content
            .font(.custom(weight.postScriptName, size: style.size, relativeTo: style.textStyle))
            .tracking(style.size * style.tracking)
    }
}

extension View {
    /// Applies an app text style with Dynamic Type scaling and Bold Text support.
    func appFont(_ style: AppTextStyle) -> some View {
        modifier(AppFontModifier(style: style))
    }
}
