import SwiftUI

struct TabViewItem: View {
    let image: AnyView
    let name: String
    let isSelected: Bool
    let onItemSelected: () -> Void

    // Selection is carried by colour alone: no pill, no glow, no outline.
    // Everything that used to be painted behind the icon and the label has
    // gone -- a tinted slab under one tab was the loudest thing in the bar, and
    // a coloured glyph beside four grey ones already says which tab you are on.
    // The caller tints this item with foregroundColor, which is also how the
    // device tab turns red on a fault.
    //
    // The small lift on selection stays: it reads as movement rather than as
    // another painted shape.

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                image

                Text(name)
                    .lineLimit(1)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 69, minHeight: 46)
            .scaleEffect(isSelected ? 1.06 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                onItemSelected()
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.7), value: isSelected)
        }
        .frame(maxWidth: .infinity)
    }
}
