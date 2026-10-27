// FFI wrapper around the Apple SpeechAnalyzer/SpeechTranscriber Swift bridge
// (src-tauri/swift/speech_analyzer*.swift). Mirrors the apple_intelligence.rs
// pattern: a `#[cfg]`-gated real implementation for macOS/aarch64 and a
// cross-platform stub so the rest of the crate can call this module
// unconditionally.

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod imp {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_float, c_int};

    #[repr(C)]
    pub struct AppleSpeechResult {
        pub text: *mut c_char,
        pub success: c_int,
        pub error_message: *mut c_char,
    }

    extern "C" {
        fn apple_speech_available() -> c_int;
        fn apple_speech_locale_installed(lang: *const c_char) -> c_int;
        fn apple_speech_install_locale(lang: *const c_char) -> *mut AppleSpeechResult;
        fn apple_speech_transcribe(
            samples: *const c_float,
            len: usize,
            lang: *const c_char,
        ) -> *mut AppleSpeechResult;
        fn apple_speech_supported_locales_json() -> *mut c_char;
        fn apple_speech_free(result: *mut AppleSpeechResult);
        fn apple_speech_free_str(s: *mut c_char);
    }

    pub fn available() -> bool {
        unsafe { apple_speech_available() == 1 }
    }

    pub fn supported_locales() -> Vec<String> {
        unsafe {
            let ptr = apple_speech_supported_locales_json();
            if ptr.is_null() {
                return Vec::new();
            }
            let json = CStr::from_ptr(ptr).to_string_lossy().into_owned();
            apple_speech_free_str(ptr);
            serde_json::from_str(&json).unwrap_or_default()
        }
    }

    fn take_result(ptr: *mut AppleSpeechResult) -> Result<String, String> {
        if ptr.is_null() {
            return Err("null result from Apple Speech bridge".into());
        }
        unsafe {
            let r = &*ptr;
            let out = if r.success == 1 {
                Ok(if r.text.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(r.text).to_string_lossy().into_owned()
                })
            } else {
                Err(if r.error_message.is_null() {
                    "unknown Apple Speech error".into()
                } else {
                    CStr::from_ptr(r.error_message)
                        .to_string_lossy()
                        .into_owned()
                })
            };
            apple_speech_free(ptr);
            out
        }
    }

    pub fn locale_installed(lang: &str) -> bool {
        let c = match CString::new(lang) {
            Ok(c) => c,
            Err(_) => return false,
        };
        unsafe { apple_speech_locale_installed(c.as_ptr()) == 1 }
    }

    pub fn install_locale(lang: &str) -> Result<(), String> {
        let c = CString::new(lang).map_err(|e| e.to_string())?;
        take_result(unsafe { apple_speech_install_locale(c.as_ptr()) }).map(|_| ())
    }

    pub fn transcribe(samples: &[f32], lang: &str) -> Result<String, String> {
        let c = CString::new(lang).map_err(|e| e.to_string())?;
        take_result(unsafe { apple_speech_transcribe(samples.as_ptr(), samples.len(), c.as_ptr()) })
    }
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
mod imp {
    pub fn available() -> bool {
        false
    }
    pub fn supported_locales() -> Vec<String> {
        Vec::new()
    }
    pub fn locale_installed(_lang: &str) -> bool {
        false
    }
    pub fn install_locale(_lang: &str) -> Result<(), String> {
        Err("Apple Speech unavailable on this platform".into())
    }
    pub fn transcribe(_samples: &[f32], _lang: &str) -> Result<String, String> {
        Err("Apple Speech unavailable on this platform".into())
    }
}

pub use imp::{available, install_locale, locale_installed, supported_locales};

/// Transcribe audio via the Apple Speech engine. Wraps `imp::transcribe` and
/// capitalizes sentence starts on the success path: `SpeechTranscriber`
/// punctuates well but leaves sentence starts lowercase (its
/// `TranscriptionOption` set has no casing knob), so every Apple transcript
/// gets this cleanup. Other engines' output is untouched.
pub fn transcribe(samples: &[f32], lang: &str) -> Result<String, String> {
    imp::transcribe(samples, lang).map(|text| capitalize_sentence_starts(&text))
}

/// SpeechTranscriber punctuates well but leaves sentence starts lowercase
/// (its `TranscriptionOption` set has no casing knob), so uppercase the first
/// letter of the text and of each sentence after `.`, `!`, `?`, or `…`.
/// A no-op for uncased scripts and for already-capitalized letters.
fn capitalize_sentence_starts(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut at_sentence_start = true;
    let mut chars = text.chars().peekable();

    while let Some(c) = chars.next() {
        if at_sentence_start && c.is_alphabetic() {
            result.extend(c.to_uppercase());
            at_sentence_start = false;
            continue;
        }
        // Punctuation counts as a sentence end only when followed by
        // whitespace (or end of text) so decimals like "3.5" stay intact.
        // Quotes and brackets pass through without consuming the sentence
        // start; anything else (digits, mid-sentence letters) consumes it.
        if matches!(c, '.' | '!' | '?' | '…')
            && chars.peek().is_none_or(|next| next.is_whitespace())
        {
            at_sentence_start = true;
        } else if !c.is_whitespace() && !matches!(c, '"' | '\'' | '“' | '”' | '(' | '[') {
            at_sentence_start = false;
        }
        result.push(c);
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn available_matches_platform_gate() {
        // On non-macos-aarch64 the stub must be false; on macOS it reflects the OS.
        // This asserts the call is total and never panics, and that the stub is false.
        let a = available();
        #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
        assert!(!a);
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        let _ = a; // OS-dependent; just must not panic
    }

    #[test]
    fn supported_locales_is_total() {
        let _ = supported_locales(); // must not panic; empty is valid
    }

    #[test]
    fn capitalizes_first_letter_and_after_sentence_punctuation() {
        assert_eq!(
            capitalize_sentence_starts("hello there. how are you? great! okay"),
            "Hello there. How are you? Great! Okay"
        );
    }

    #[test]
    fn ignores_decimals_and_leaves_numbers_alone() {
        assert_eq!(
            capitalize_sentence_starts("it costs 3.5 dollars. 6 people paid"),
            "It costs 3.5 dollars. 6 people paid"
        );
    }

    #[test]
    fn capitalizes_through_opening_quotes() {
        assert_eq!(
            capitalize_sentence_starts("she said. \"hello world\""),
            "She said. \"Hello world\""
        );
    }

    #[test]
    fn treats_ellipsis_as_sentence_end() {
        // `…` is in the sentence-end matcher alongside `.!?` — SpeechTranscriber
        // emits it for trailing-off speech. Pinned separately because it's the
        // one member of that set a rewrite of the matcher would most plausibly
        // drop (it's easy to forget it's a single char, not three dots).
        assert_eq!(
            capitalize_sentence_starts("well… maybe tomorrow"),
            "Well… Maybe tomorrow"
        );
    }

    #[test]
    fn capitalizes_the_smoke_test_transcript() {
        assert_eq!(
            capitalize_sentence_starts("the quick brown fox. hello world"),
            "The quick brown fox. Hello world"
        );
    }
}
