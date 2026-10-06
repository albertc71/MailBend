//! The environment this helper runs in. The Bend core gives every child its
//! whole environment, which may hold the mail password, so before anything
//! else the helper re-executes itself keeping only the settings it needs:
//! the password never shares this process, not even in /proc/self/environ.

use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::Command;

/// The only variables kept: the key file, the time budget, and the routing
/// and trust settings shared with `mailbend-tls`.
pub const ALLOWED: [&str; 10] = [
    "MAILBEND_TYPESAFE_KEY_FILE",
    "MAILBEND_TIMEOUT_MS",
    "MAILBEND_DOH_URL",
    "MAILBEND_CA_FILE",
    "https_proxy",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
    "no_proxy",
    "NO_PROXY",
];

/// Whether a raw `NAME=value` environment entry is one of the allowed
/// settings. An entry without `=` is never allowed.
fn is_allowed_entry(entry: &[u8]) -> bool {
    entry
        .iter()
        .position(|&b| b == b'=')
        .is_some_and(|eq| ALLOWED.iter().any(|name| name.as_bytes() == &entry[..eq]))
}

/// Re-executes this program with only the allowed settings, unless the
/// kernel's copy of its environment already holds nothing else (std skips
/// entries without "=", which /proc/self/environ would still show). Returns
/// only when no re-execution is needed; a failed one is an error.
pub fn confine(args: &[OsString]) -> Result<(), String> {
    let environ = std::fs::read("/proc/self/environ")
        .map_err(|_| "cannot read /proc/self/environ".to_string())?;
    if environ
        .split(|&b| b == 0)
        .filter(|entry| !entry.is_empty())
        .all(is_allowed_entry)
    {
        return Ok(());
    }
    let kept: Vec<(&str, OsString)> = ALLOWED
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listed_settings_are_kept() {
        assert!(is_allowed_entry(b"MAILBEND_TYPESAFE_KEY_FILE=/k"));
        assert!(is_allowed_entry(b"https_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"NO_PROXY="));
        assert!(is_allowed_entry(b"all_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"ALL_PROXY=http://p:3128"));
        for refused in [
            &b"MAILBEND_APP_PASSWORD=secret"[..],
            b"MAILBEND_EMAIL=a@b",
            b"MAILBEND_TYPESAFE_API_KEY=k",
            b"http_proxy=http://p",
            b"MAILBEND_TIMEOUT_MS",
            b"MAILBEND_CA_FILEX=/x",
            b"=MAILBEND_CA_FILE",
        ] {
            assert!(
                !is_allowed_entry(refused),
                "{}",
                String::from_utf8_lossy(refused)
            );
        }
    }
}
