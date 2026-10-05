//! Runs the built helper the way the Bend core does: positionally, from a
//! working directory, with an inherited environment.

// Test helpers outside #[test] functions fail loudly too.
#![allow(clippy::expect_used)]

use std::fs;
use std::ops::Deref;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// A fresh scratch directory under the system temporary directory,
/// removed when the test ends.
struct Scratch(PathBuf);

impl Deref for Scratch {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn scratch() -> Scratch {
    let n = NEXT.fetch_add(1, Ordering::SeqCst);
    let dir = std::env::temp_dir().join(format!("mailbend-attach-test-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create scratch directory");
    Scratch(fs::canonicalize(&dir).expect("canonical scratch directory"))
}

fn attach(cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_mailbend-attach"))
        .args(args)
        .current_dir(cwd)
        .env("MAILBEND_APP_PASSWORD", "must-not-leak")
        .output()
        .expect("run mailbend-attach")
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

#[test]
fn a_relative_directory_is_resolved_from_the_working_directory() {
    let work = scratch();
    fs::create_dir(work.join("attachments")).expect("mkdir");
    fs::write(work.join("attachments").join("a.txt"), b"hello\n").expect("write");
    let out = attach(&work, &["attachments", "a.txt", "1000"]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(out.stdout, b"hello\n");
}

#[test]
fn high_bytes_are_written_as_utf8_code_points() {
    let work = scratch();
    fs::write(work.join("bin"), [0x00, 0x41, 0x80, 0xFF]).expect("write");
    let out = attach(&work, &[work.to_str().expect("utf-8"), "bin", "10"]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(out.stdout, [0x00, 0x41, 0xC2, 0x80, 0xC3, 0xBF]);
}

#[test]
fn proc_environ_is_unreachable() {
    let work = scratch();
    let dir = work.to_str().expect("utf-8");
    let out = attach(&work, &[dir, "/proc/self/environ", "1000"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("outside"), "{}", stderr(&out));
    assert!(!String::from_utf8_lossy(&out.stdout).contains("must-not-leak"));
    // Reading this process's environment through a magic link is refused too.
    let proc_dir = attach(&work, &["/proc/self", "environ", "100000"]);
    assert_eq!(proc_dir.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&proc_dir.stdout).contains("must-not-leak"));
}

#[test]
fn a_directory_reached_through_a_symlink_is_resolved_once() {
    let work = scratch();
    let real = work.join("real");
    fs::create_dir(&real).expect("mkdir");
    fs::write(real.join("a.txt"), b"x").expect("write");
    symlink(&real, work.join("alias")).expect("symlink");
    let alias = work.join("alias");
    let alias = alias.to_str().expect("utf-8");
    let out = attach(&work, &[alias, "a.txt", "10"]);
    assert_eq!(out.stdout, b"x", "{}", stderr(&out));
    let absolute = format!("{alias}/a.txt");
    let out = attach(&work, &[alias, &absolute, "10"]);
    assert_eq!(out.stdout, b"x", "{}", stderr(&out));
    let out = attach(&work, &["alias", "a.txt", "10"]);
    assert_eq!(out.stdout, b"x", "{}", stderr(&out));
}

#[test]
fn escapes_links_and_special_files_are_refused() {
    let work = scratch();
    let dir = work.to_str().expect("utf-8");
    fs::write(work.join("a.txt"), b"data").expect("write");
    symlink("/etc/hostname", work.join("link")).expect("symlink");
    fs::hard_link(work.join("a.txt"), work.join("hard.txt")).expect("hard link");
    fs::create_dir(work.join("sub")).expect("mkdir");
    let cases: [(&str, &str); 5] = [
        ("../../../etc/hostname", "outside"),
        ("link", "symlink"),
        ("hard.txt", "hard link"),
        ("sub", "not a regular file"),
        ("missing", "not found"),
    ];
    for (path, reason) in cases {
        let out = attach(&work, &[dir, path, "1000"]);
        assert_eq!(out.status.code(), Some(2), "{path}");
        assert!(out.stdout.is_empty(), "{path}");
        assert!(stderr(&out).contains(reason), "{path}: {}", stderr(&out));
    }
}

#[test]
fn files_over_the_budget_are_refused() {
    let work = scratch();
    fs::write(work.join("big"), [b'x'; 10]).expect("write");
    let dir = work.to_str().expect("utf-8");
    let out = attach(&work, &[dir, "big", "5"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        stderr(&out).contains("would exceed 5 bytes"),
        "{}",
        stderr(&out)
    );
    let out = attach(&work, &[dir, "big", "0"]);
    assert!(stderr(&out).contains("bad byte limit"), "{}", stderr(&out));
}

#[test]
fn broad_directories_are_refused() {
    let out = attach(Path::new("/"), &["/", "etc/hostname", "1000"]);
    assert!(stderr(&out).contains("must not be /"), "{}", stderr(&out));
    let work = scratch();
    for name in [".ssh", ".git"] {
        let dir = work.join(name.trim_start_matches('.'));
        fs::create_dir_all(dir.join(name)).expect("mkdir");
        fs::write(dir.join("a.txt"), b"x").expect("write");
        let out = attach(&work, &[dir.to_str().expect("utf-8"), "a.txt", "10"]);
        assert_eq!(out.status.code(), Some(2));
        assert!(stderr(&out).contains(name), "{}", stderr(&out));
    }
}

#[test]
fn other_argument_counts_are_usage_errors() {
    let work = scratch();
    for args in [
        &[][..],
        &["a"][..],
        &["a", "b"][..],
        &["a", "b", "c", "d"][..],
    ] {
        let out = attach(&work, args);
        assert_eq!(out.status.code(), Some(2));
        assert!(stderr(&out).contains("usage"), "{}", stderr(&out));
    }
}
