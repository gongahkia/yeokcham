use std::fmt;

/// Wraps a sensitive value so formatting emits only a fixed redaction marker.
#[must_use]
pub struct Redacted<T> {
    _value: T,
}

/// Wraps a value for redacted diagnostic formatting.
pub const fn redact<T>(value: T) -> Redacted<T> {
    Redacted { _value: value }
}

impl<T> fmt::Debug for Redacted<T> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<redacted>")
    }
}

impl<T> fmt::Display for Redacted<T> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<redacted>")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_and_display_hide_wrapped_value() {
        let value = redact("secret source bytes");

        assert_eq!(format!("{value}"), "<redacted>");
        assert_eq!(format!("{value:?}"), "<redacted>");
    }
}
