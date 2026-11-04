//! Checks for text people type that the server stores and shows to others
//! (group names, group messages). Rendering is already safe: clients only
//! ever set text, never HTML. These checks stop the other tricks: invisible
//! control characters, and direction overrides that make text read
//! differently than it is (spoofed names like "evil\u{202E}gpj.exe").

/// Characters that change how text displays without being visible. Zero-width
/// joiners (U+200C/U+200D) stay allowed: emoji sequences need them.
fn is_deceptive(c: char) -> bool {
    matches!(
        c,
        '\u{202A}'..='\u{202E}' // bidi embeddings and overrides
            | '\u{2066}'..='\u{2069}' // bidi isolates
            | '\u{200E}' | '\u{200F}' | '\u{061C}' // direction marks
            | '\u{200B}' | '\u{FEFF}' // zero-width space, BOM
            | '\u{2028}' | '\u{2029}' // line/paragraph separators
    )
}

/// One line: no control characters at all.
pub fn check_name(s: &str) -> Result<(), &'static str> {
    if s.chars().any(|c| c.is_control() || is_deceptive(c)) {
        return Err("Names can't contain invisible or direction-changing characters.");
    }
    Ok(())
}

/// Messages: newlines and tabs are fine; other control characters aren't.
pub fn check_message(s: &str) -> Result<(), &'static str> {
    if s.chars()
        .any(|c| (c.is_control() && c != '\n' && c != '\t') || is_deceptive(c))
    {
        return Err("Messages can't contain invisible or direction-changing characters.");
    }
    Ok(())
}

/// A reaction: exactly one emoji, nothing else. One emoji can be several
/// code points (a skin tone, a flag's pair, a keycap, people joined by
/// U+200D), so this follows the shape of an emoji sequence rather than
/// counting characters. Clients hold decrypted reactions to the same rule
/// (`isReaction` in shared/crypto/crypto.js, `E2E.isReaction` in Swift).
pub fn is_one_emoji(s: &str) -> bool {
    // The longest real ones (a family, a subdivision flag) are under 30 bytes.
    if s.is_empty() || s.len() > 40 {
        return false;
    }
    let mut cs = s.chars().peekable();
    loop {
        let Some(c) = cs.next() else { return false };
        match c {
            '\u{1F1E6}'..='\u{1F1FF}' => {
                // A flag is two regional indicators, and nothing joins to it.
                return matches!(cs.next(), Some('\u{1F1E6}'..='\u{1F1FF}')) && cs.next().is_none();
            }
            '0'..='9' | '#' | '*' => {
                cs.next_if_eq(&'\u{FE0F}');
                return cs.next() == Some('\u{20E3}') && cs.next().is_none();
            }
            c if is_pictographic(c) => {
                cs.next_if_eq(&'\u{FE0F}');
                cs.next_if(|c| ('\u{1F3FB}'..='\u{1F3FF}').contains(c));
                if c == '\u{1F3F4}'
                    && cs
                        .peek()
                        .is_some_and(|c| ('\u{E0020}'..='\u{E007E}').contains(c))
                {
                    while cs
                        .next_if(|c| ('\u{E0020}'..='\u{E007E}').contains(c))
                        .is_some()
                    {}
                    if cs.next() != Some('\u{E007F}') {
                        return false;
                    }
                }
            }
            _ => return false,
        }
        match cs.next() {
            None => return true,
            Some('\u{200D}') => continue,
            Some(_) => return false,
        }
    }
}

/// Code points that are emoji on their own: Unicode's Extended_Pictographic,
/// by block, minus the regional indicators and skin tones (handled above).
fn is_pictographic(c: char) -> bool {
    matches!(c,
        '\u{A9}' | '\u{AE}' | '\u{203C}' | '\u{2049}' | '\u{2122}' | '\u{2139}'
        | '\u{2194}'..='\u{2199}' | '\u{21A9}'..='\u{21AA}' | '\u{231A}'..='\u{231B}'
        | '\u{2328}' | '\u{23CF}' | '\u{23E9}'..='\u{23F3}' | '\u{23F8}'..='\u{23FA}'
        | '\u{24C2}' | '\u{25AA}'..='\u{25AB}' | '\u{25B6}' | '\u{25C0}' | '\u{25FB}'..='\u{25FE}'
        | '\u{2600}'..='\u{27BF}' | '\u{2934}'..='\u{2935}' | '\u{2B05}'..='\u{2B07}'
        | '\u{2B1B}'..='\u{2B1C}' | '\u{2B50}' | '\u{2B55}' | '\u{3030}' | '\u{303D}'
        | '\u{3297}' | '\u{3299}'
        | '\u{1F000}'..='\u{1F1E5}' | '\u{1F200}'..='\u{1F3FA}' | '\u{1F400}'..='\u{1FAFF}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_emoji_and_other_scripts_pass() {
        for ok in [
            "road trip",
            "Ägäis 🚗",
            "東京",
            "مرحبا",
            "👨\u{200D}👩\u{200D}👧",
            "it's <b>fine</b>",
            "'; DROP TABLE x; --",
        ] {
            assert!(check_name(ok).is_ok(), "{ok:?}");
            assert!(check_message(ok).is_ok(), "{ok:?}");
        }
        assert!(check_message("line one\nline two\ttabbed").is_ok());
    }

    #[test]
    fn invisible_and_direction_tricks_fail() {
        for bad in [
            "evil\u{202E}gpj.exe",
            "a\u{2066}b",
            "zero\u{200B}width",
            "\u{FEFF}bom",
            "nul\0",
            "bell\x07",
            "esc\x1b[31m",
        ] {
            assert!(check_name(bad).is_err(), "{bad:?}");
            assert!(check_message(bad).is_err(), "{bad:?}");
        }
        assert!(check_name("two\nlines").is_err());
        assert!(check_message("cr\r").is_err());
    }

    #[test]
    fn one_emoji_is_a_reaction() {
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
            assert!(is_one_emoji(ok), "{ok:?}");
        }
    }

    #[test]
    fn anything_else_is_not_a_reaction() {
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
            assert!(!is_one_emoji(bad), "{bad:?}");
        }
    }
}
