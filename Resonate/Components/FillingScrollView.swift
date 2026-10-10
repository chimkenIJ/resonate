import SwiftUI

/// A scroll view whose content is at least as tall as the screen, so `Spacer`s can push
/// buttons to the bottom while large Dynamic Type sizes can still scroll.
struct FillingScrollView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
