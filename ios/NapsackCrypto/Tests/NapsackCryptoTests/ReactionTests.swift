import Testing
@testable import NapsackCrypto

/// A reaction is one emoji and nothing else: the server's own cases for
/// `text::is_one_emoji` (server/src/text.rs), which `E2E.isReaction` ports.
@Suite struct ReactionTests {
    @Test func oneEmojiIsAReaction() {
        for ok in [
            "❤️",
            "😂",
            "👍",
            "👍🏽",
            "🇳🇿",
            "1️⃣",
            "#⃣",
            "©️",
            "☀",
            "🫠",
            "👨\u{200D}👩\u{200D}👧\u{200D}👦",
            "🧑🏿\u{200D}🚀",
            "🏳️\u{200D}🌈",
            "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        ] {
            #expect(E2E.isReaction(ok), "\(ok.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // The quick row, of course.
        #expect(E2E.reactions.allSatisfy(E2E.isReaction))
    }

    @Test func anythingElseIsNotAReaction() {
        for bad in [
            "",
            "a",
            "1",
            "ok",
            "😂😂",
            "😂 ",
            " 😂",
            "😂a",
            "🇳",
            "🇳🇿🇳🇿",
            "1⃣2",
            "\u{FE0F}",
            "\u{200D}😂",
            "😂\u{200D}",
            "😂\u{200D}\u{200D}😂",
            "🏽",
            "\u{202E}😂",
            "😂\u{202E}",
            "\u{200B}",
            "\0",
            "🏴\u{E0067}\u{E0062}",
            "<b>",
            "👍🏽🏽",
            "👨\u{200D}👩\u{200D}👧\u{200D}👦\u{200D}👨\u{200D}👩\u{200D}👧\u{200D}👦",
        ] {
            #expect(!E2E.isReaction(bad), "\(bad.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}
