//! Reading text settings from the environment, and dropping the rest of
//! it.

use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::Command;
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

/// Whether a raw `NAME=value` environment entry names one of `keep`. An
/// entry without `=` is never kept.
pub fn is_kept_entry(entry: &[u8], keep: &[&str]) -> bool {
    entry
        .iter()
        .position(|&b| b == b'=')
        .is_some_and(|eq| keep.iter().any(|name| name.as_bytes() == &entry[..eq]))
}

/// Re-executes this program (`args`, as it was started) with only the
/// variables named in `keep`, unless the kernel's copy of its environment
/// already holds nothing else (std skips entries without "=", which
/// /proc/self/environ would still show). Returns only when no re-execution
/// is needed; a failed one is an error.
pub fn reexec_with(args: &[OsString], keep: &[&str]) -> Result<(), String> {
    let environ = std::fs::read("/proc/self/environ")
        .map_err(|_| "cannot read /proc/self/environ".to_string())?;
    if environ
        .split(|&b| b == 0)
        .filter(|entry| !entry.is_empty())
        .all(|entry| is_kept_entry(entry, keep))
    {
        return Ok(());
    }
    let kept: Vec<(&str, OsString)> = keep
        .iter()
        .filter_map(|&name| std::env::var_os(name).map(|value| (name, value)))
        .collect();
    let mut command = Command::new("/proc/self/exe");
    if let Some((program, rest)) = args.split_first() {
        command.arg0(program).args(rest);
    }
    let _error = command.env_clear().envs(kept).exec();
    Err("cannot drop the inherited environment".to_string())
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
    fn only_named_entries_are_kept() {
        let keep = ["A", "B_C"];
        assert!(is_kept_entry(b"A=1", &keep));
        assert!(is_kept_entry(b"B_C=", &keep));
        for refused in [&b"AB=1"[..], b"A", b"=A", b"C=1", b""] {
            assert!(!is_kept_entry(refused, &keep));
        }
        assert!(!is_kept_entry(b"A=1", &[]));
    }

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
