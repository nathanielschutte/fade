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
}
