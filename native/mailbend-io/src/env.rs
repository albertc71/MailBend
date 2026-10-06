//! Reading text settings from the environment.

use std::ffi::OsString;
use std::time::Duration;

/// The value of `name` if it is set and nonempty. A value that is not UTF-8
/// is an error (with a message naming the variable), never treated as
/// unset.
pub fn text_var(name: &str) -> Result<Option<String>, String> {
    match std::env::var_os(name).map(OsString::into_string) {
        None => Ok(None),
        Some(Ok(value)) => Ok(Some(value).filter(|v| !v.is_empty())),
        Some(Err(_)) => Err(format!("{name} is not valid UTF-8")),
    }
}

/// MAILBEND_TIMEOUT_MS read like C's atoi: leading spaces, a sign and
/// digits, anything after ignored; a missing or nonpositive value means 30
/// seconds.
pub fn timeout() -> Result<Duration, String> {
    Ok(parse_timeout(text_var("MAILBEND_TIMEOUT_MS")?.as_deref()))
}

fn parse_timeout(value: Option<&str>) -> Duration {
    const DEFAULT_MS: u64 = 30_000;
    let Some(s) = value.map(str::trim_start) else {
        return Duration::from_millis(DEFAULT_MS);
    };
    let (negative, digits) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let end = digits
        .bytes()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(digits.len());
    let ms = match digits[..end].parse::<u64>() {
        Ok(ms) if ms > 0 && !negative => ms.min(i32::MAX as u64),
        _ => DEFAULT_MS,
    };
    Duration::from_millis(ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeouts_parse_like_atoi() {
        let ms = |value| parse_timeout(value).as_millis();
        assert_eq!(ms(None), 30_000);
        assert_eq!(ms(Some("1500")), 1500);
        assert_eq!(ms(Some("  250ms")), 250);
        assert_eq!(ms(Some("+7")), 7);
        assert_eq!(ms(Some("0")), 30_000);
        assert_eq!(ms(Some("-5")), 30_000);
        assert_eq!(ms(Some("x")), 30_000);
        assert_eq!(ms(Some("99999999999")), u128::from(i32::MAX.unsigned_abs()));
    }
}
