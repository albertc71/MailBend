//! Runs the built helper for the checks that happen before any network
//! access. The connected paths are covered by tests/test-transport.sh and
//! tests/test-cloud-network.py against local TLS servers.

// Test helpers outside #[test] functions fail loudly too.
#![allow(clippy::expect_used)]

use std::io::Write;
use std::process::{Command, Output, Stdio};

/// A port nothing listens on: reaching the network would fail with exit 3,
/// so exit 2 proves the helper stopped first.
const CLOSED_PORT: &str = "9";

fn helper(args: &[&str], stdin: &[u8], env: &[(&str, &str)]) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_mailbend-tls"));
    command
        .args(args)
        .env_clear()
        .env("MAILBEND_EMAIL", "user@example.com")
        .env("MAILBEND_APP_PASSWORD", "fixture-password")
        .env("MAILBEND_IMAP_HOST", "127.0.0.1")
        .env("MAILBEND_IMAP_PORT", CLOSED_PORT)
        .env("MAILBEND_SMTP_HOST", "127.0.0.1")
        .env("MAILBEND_SMTP_PORT", CLOSED_PORT)
        .env("MAILBEND_TIMEOUT_MS", "500")
        .envs(env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().expect("run mailbend-tls");
    // The helper may stop before reading its input; that is not a failure.
    let _ignored = child.stdin.take().expect("stdin").write_all(stdin);
    child.wait_with_output().expect("wait")
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

fn assert_refused(out: &Output, reason: &str) {
    assert_eq!(out.status.code(), Some(2), "{}", stderr(out));
    assert!(stderr(out).contains(reason), "{reason}: {}", stderr(out));
    assert!(!stderr(out).contains("fixture-password"));
    assert!(out.stdout.is_empty());
}

#[test]
fn check_needs_no_credentials() {
    let out = Command::new(env!("CARGO_BIN_EXE_mailbend-tls"))
        .arg("--check")
        .env_clear()
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn unknown_modes_are_usage_errors() {
    for args in [&[][..], &["pop3"][..], &["imap", "smtp"][..]] {
        assert_refused(&helper(args, b"", &[]), "usage");
    }
}

#[test]
fn a_typesafe_key_never_shares_the_process_with_the_password() {
    let out = helper(
        &["imap"],
        b"a1 NOOP\r\n",
        &[("MAILBEND_TYPESAFE_API_KEY", "x")],
    );
    assert_refused(&out, "MAILBEND_TYPESAFE_API_KEY");
}

#[test]
fn invalid_scripts_are_refused_before_connecting() {
    assert_refused(&helper(&["imap"], b"L NOOP\r\n", &[]), "reserved");
    assert_refused(&helper(&["imap"], b"a1 LOGOUT\r\n", &[]), "log out");
    assert_refused(&helper(&["smtp"], b"QUIT\r\n", &[]), "may not greet");
}

#[test]
fn credentials_are_checked_before_connecting() {
    let out = helper(&["imap"], b"", &[("MAILBEND_EMAIL", "")]);
    assert_refused(&out, "MAILBEND_EMAIL is not set");
    let out = helper(&["imap"], b"", &[("MAILBEND_PASSWORD_FILE", "/tmp/x")]);
    assert_refused(&out, "not both");
    let out = helper(
        &["imap"],
        b"",
        &[
            ("MAILBEND_APP_PASSWORD", ""),
            ("MAILBEND_PASSWORD_FILE", "relative"),
        ],
    );
    assert_refused(&out, "absolute path");
}

#[test]
fn routing_settings_are_validated_before_connecting() {
    let out = helper(
        &["imap"],
        b"",
        &[("MAILBEND_DOH_URL", "http://resolver/dns-query")],
    );
    assert_refused(&out, "HTTPS URL");
    let out = helper(
        &["imap"],
        b"",
        &[("MAILBEND_IMAP_CONNECT_IP", "127.0.0.1:993")],
    );
    assert_refused(&out, "numeric IPv4 or IPv6");
    let out = helper(&["imap"], b"", &[("MAILBEND_IMAP_HOST", "bad host")]);
    assert_refused(&out, "MAILBEND_IMAP_HOST is not a valid host name");
    let out = helper(
        &["imap"],
        b"",
        &[
            ("MAILBEND_DOH_URL", "https://dns.test"),
            ("https_proxy", "socks5://p"),
        ],
    );
    assert_refused(&out, "not a supported http:// proxy URL");
    let out = helper(&["smtp"], b"", &[("MAILBEND_SMTP_PORT", "0")]);
    assert_refused(&out, "MAILBEND_SMTP_PORT must be a port number");
}

#[test]
fn an_unreachable_server_is_a_connect_failure() {
    let out = helper(&["imap"], b"a1 NOOP\r\n", &[]);
    assert_eq!(out.status.code(), Some(3), "{}", stderr(&out));
    assert!(
        stderr(&out).contains("cannot connect to 127.0.0.1:9"),
        "{}",
        stderr(&out)
    );
}
