import SwiftUI
import Testing
import UIKit
@testable import Napsack

/// What the screen-size audit fixed, measured (ios-onboarding.md, "Screen
/// sizes and shapes"); FitLookTests has pictures of the same.
@MainActor @Suite struct FitTests {
    /// How tall a view is at a width, at a text size.
    func height(_ view: some View, width: CGFloat, text: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, text))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// A chat list row's time stays on one line at every text size, however
    /// narrow the row ("10:44 AM", never "10:44 A" over "M"): the row is as
    /// tall in the narrowest phone's row as in one wide enough for anything.
    @Test(arguments: [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5])
    func aRowsTimeIsOneLine(text: DynamicTypeSize) {
        let today = Calendar.current.date(bySettingHour: 10, minute: 44, second: 0, of: .now)!
        for time in [today, today.addingTimeInterval(-3 * 86_400), today.addingTimeInterval(-40 * 86_400)] {
            let row = ChatRowView(row: ChatRow(kind: .friend(9), name: "ben", preview: "Ok!", waiting: nil, time: time,
                                               favorite: false, muted: false, hidden: false))
            // 320 points, less the list's margins, the picture, and the arrow.
            let narrow = height(row, width: 200, text: text), wide = height(row, width: 2000, text: text)
            #expect(narrow == wide, "\(text) at \(ChatRowView.when(time)): \(narrow) tall in a narrow row, \(wide) in a wide one")
        }
    }
}
