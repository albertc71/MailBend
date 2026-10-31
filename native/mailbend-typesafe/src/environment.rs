//! The environment this helper runs in. The Bend core gives every child its
//! whole environment, which may hold the mail password, so before anything
//! else the helper re-executes itself keeping only the settings it needs:
//! the password never shares this process, not even in /proc/self/environ.

use std::ffi::OsString;

use mailbend_io::env::reexec_with;

use crate::settings::KEY_FILE;

/// The only variables kept: the key file, the time budget, and the routing
/// and trust settings shared with `mailbend-tls`.
pub const ALLOWED: [&str; 10] = [
    KEY_FILE,
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

/// Re-executes this program with only the allowed settings, unless it
/// already has no others. Returns only when no re-execution is needed; a
/// failed one is an error.
pub fn confine(args: &[OsString]) -> Result<(), String> {
    reexec_with(args, &ALLOWED)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mailbend_io::env::is_kept_entry;

    #[test]
    fn only_listed_settings_are_kept() {
        let is_allowed_entry = |entry: &[u8]| is_kept_entry(entry, &ALLOWED);
        assert!(is_allowed_entry(b"MAILBEND_TYPESAFE_KEY_FILE=/k"));
        assert!(is_allowed_entry(b"https_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"NO_PROXY="));
        assert!(is_allowed_entry(b"all_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"ALL_PROXY=http://p:3128"));
        for refused in [
            &b"MAILBEND_APP_PASSWORD=secret"[..],
            b"MAILBEND_EMAIL=a@b",
            b"MAILBEND_TYPESAFE_API_KEY=k",
            b"MAILBEND_TYPESAFE_IMAGES=1",
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

#[cfg(test)]
mod confinement_tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn ask_path_removes_mail_credentials_from_its_runtime_environment() {
        let result = Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "environment::confinement_tests::inspect_confined_environment",
                "--ignored",
                "--nocapture",
            ])
            .env_clear()
            .env(KEY_FILE, "/synthetic/key")
            .env("MAILBEND_TIMEOUT_MS", "100")
            .env("MAILBEND_APP_PASSWORD", "synthetic-password")
            .env("MAILBEND_EMAIL", "user@example.com")
            .env("UNRELATED_SETTING", "discard")
            .output()
            .expect("run confined child");
        assert!(result.status.success(), "{result:?}");
        assert!(String::from_utf8_lossy(&result.stdout).contains("confined environment checked"));
    }

    #[test]
    #[ignore = "runs only in the isolated confinement child"]
    fn inspect_confined_environment() {
        let args: Vec<_> = std::env::args_os().collect();
        let result = crate::ask_confined(&args, crate::api::Attempts::Once, false);
        assert!(result.is_err(), "the synthetic key path must not exist");
        let mut entries: Vec<_> = std::env::vars_os().collect();
        entries.sort();
        assert_eq!(
            entries,
            [
                (OsString::from("MAILBEND_TIMEOUT_MS"), OsString::from("100")),
                (OsString::from(KEY_FILE), OsString::from("/synthetic/key")),
            ]
        );
        println!("confined environment checked");
    }
}
