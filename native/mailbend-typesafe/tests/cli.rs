//! Runs the built helper: the checks before any network access, and the
//! route through an HTTPS proxy, where a local proxy records the tunnel
//! request and the helper's environment. The TLS exchange itself is covered
//! by tests/test-e2e.py against a local fake TypeSafe service.

// Test helpers outside #[test] functions fail loudly too.
#![allow(clippy::expect_used)]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};

const KEY: &str = "ts-fixture-key-0123456789";
const PASSWORD: &str = "fixture-password";

type Env<'a> = &'a [(&'a str, &'a str)];

/// A private directory holding a key file with `content`.
fn key_file(tag: &str, content: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mailbend-typesafe-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let dir = std::fs::canonicalize(&dir).expect("canonical");
    let path = dir.join("key");
    std::fs::write(&path, content).expect("write");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).expect("chmod");
    path
}

fn spawn(args: &[&str], env: &[(&str, &str)], stdin: &[u8]) -> Child {
    let mut child = Command::new(env!("CARGO_BIN_EXE_mailbend-typesafe"))
        .args(args)
        .env_clear()
        .env("MAILBEND_APP_PASSWORD", PASSWORD)
        .env("MAILBEND_TIMEOUT_MS", "5000")
        .envs(env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run mailbend-typesafe");
    // The helper may stop before reading its input; that is not a failure.
    let _ignored = child.stdin.take().expect("stdin").write_all(stdin);
    child
}

fn run(args: &[&str], env: &[(&str, &str)], stdin: &[u8]) -> Output {
    spawn(args, env, stdin).wait_with_output().expect("wait")
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

fn assert_exit(out: &Output, code: i32, reason: &str) {
    assert_eq!(out.status.code(), Some(code), "{}", stderr(out));
    assert!(stderr(out).contains(reason), "{reason}: {}", stderr(out));
    for secret in [KEY, PASSWORD] {
        assert!(!stderr(out).contains(secret));
        assert!(!String::from_utf8_lossy(&out.stdout).contains(secret));
    }
}

#[test]
fn check_needs_no_key() {
    let out = Command::new(env!("CARGO_BIN_EXE_mailbend-typesafe"))
        .arg("--check")
        .env_clear()
        .output()
        .expect("run");
    assert_eq!(out.status.code(), Some(0));
}

#[test]
fn unknown_modes_are_input_errors() {
    for args in [
        &[][..],
        &["ask", "more"][..],
        &["ask", "--once", "more"][..],
        &["--once", "ask"][..],
        &["classify"][..],
    ] {
        assert_exit(&run(args, &[], b"{}"), 2, "usage: mailbend-typesafe");
    }
}

#[test]
fn a_single_attempt_is_a_mode_of_ask() {
    // Accepted as ask, so it stops at the first missing input, not at usage.
    assert_exit(
        &run(&["ask", "--once"], &[], b"{}"),
        2,
        "MAILBEND_TYPESAFE_KEY_FILE is not set",
    );
}

#[test]
fn a_key_in_the_environment_is_refused() {
    let path = key_file("env", KEY);
    let file = path.to_str().expect("utf-8");
    let env = [
        ("MAILBEND_TYPESAFE_API_KEY", KEY),
        ("MAILBEND_TYPESAFE_KEY_FILE", file),
    ];
    assert_exit(
        &run(&["ask"], &env, b"{}"),
        2,
        "MAILBEND_TYPESAFE_API_KEY must not be set",
    );
}

#[test]
fn unusable_keys_and_requests_stop_before_connecting() {
    let good = key_file("good", &format!("{KEY}\n"));
    let short = key_file("short", "abc");
    let quoted = key_file("quoted", "ts_te\"st_key_0123");
    let good = good.to_str().expect("utf-8");
    let quoted = quoted.to_str().expect("utf-8");
    let cases: [(Env, &[u8], &str); 6] = [
        (&[], b"{}", "MAILBEND_TYPESAFE_KEY_FILE is not set"),
        (
            &[("MAILBEND_TYPESAFE_KEY_FILE", "relative/key")],
            b"{}",
            "MAILBEND_TYPESAFE_KEY_FILE must be an absolute path",
        ),
        (
            &[("MAILBEND_TYPESAFE_KEY_FILE", short.to_str().expect("utf-8"))],
            b"{}",
            "at least 8 characters: letters, digits",
        ),
        (
            &[("MAILBEND_TYPESAFE_KEY_FILE", quoted)],
            b"{}",
            "at least 8 characters: letters, digits",
        ),
        (
            &[("MAILBEND_TYPESAFE_KEY_FILE", good)],
            b"",
            "nonempty UTF-8 JSON",
        ),
        (
            &[("MAILBEND_TYPESAFE_KEY_FILE", good)],
            b"\xff",
            "nonempty UTF-8 JSON",
        ),
    ];
    for (env, stdin, reason) in cases {
        assert_exit(&run(&["ask"], env, stdin), 2, reason);
    }
}

#[test]
fn a_proxy_gets_a_tunnel_request_for_the_fixed_host_from_a_confined_process() {
    let path = key_file("proxy", KEY);
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let proxy = format!("http://{}", listener.local_addr().expect("addr"));
    let env = [
        ("MAILBEND_TYPESAFE_KEY_FILE", path.to_str().expect("utf-8")),
        ("https_proxy", proxy.as_str()),
        ("MAILBEND_EMAIL", "user@example.com"),
        ("UNRELATED_SETTING", "x"),
    ];
    let child = spawn(&["ask"], &env, b"{\"questions\":{}}");
    let pid = child.id();
    let (mut peer, _) = listener.accept().expect("accept");
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        assert_eq!(peer.read(&mut byte).expect("read"), 1);
        head.push(byte[0]);
    }
    // Still connected, so the helper (same pid after re-executing) is alive.
    let environ = std::fs::read(format!("/proc/{pid}/environ")).expect("environ");
    peer.write_all(b"HTTP/1.1 403 Forbidden\r\n\r\n")
        .expect("reply");
    let out = child.wait_with_output().expect("wait");

    let head = String::from_utf8(head).expect("utf-8");
    assert!(
        head.starts_with("CONNECT api.typesafe.ai:443 HTTP/1.1\r\n"),
        "{head}"
    );
    assert!(!head.contains(KEY));
    let names: Vec<&[u8]> = environ
        .split(|&b| b == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| entry.split(|&b| b == b'=').next().unwrap_or(entry))
        .collect();
    assert!(names.contains(&&b"MAILBEND_TYPESAFE_KEY_FILE"[..]));
    for dropped in [
        "MAILBEND_APP_PASSWORD",
        "MAILBEND_EMAIL",
        "UNRELATED_SETTING",
    ] {
        assert!(!names.contains(&dropped.as_bytes()), "{dropped} was kept");
    }
    assert!(!String::from_utf8_lossy(&environ).contains(PASSWORD));
    assert_exit(&out, 3, "proxy refused the tunnel to api.typesafe.ai:443");
}
