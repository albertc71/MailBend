#![allow(clippy::expect_used)]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};

use nix::sys::prctl::get_dumpable;
use nix::sys::resource::{Resource, getrlimit};

#[test]
fn protection_is_local_and_blocks_sigquit_dumps() {
    let before = (
        get_dumpable().expect("dumpability"),
        getrlimit(Resource::RLIMIT_CORE),
    );
    let mut child = Command::new(std::env::current_exe().expect("test executable"))
        .args(["--exact", "protected_child", "--ignored", "--nocapture"])
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run protected child");
    let mut output = BufReader::new(child.stdout.take().expect("stdout"));
    let mut line = String::new();
    while !line.contains("protected child ready") {
        line.clear();
        assert_ne!(output.read_line(&mut line).expect("child ready"), 0);
    }
    let error = std::fs::read(format!("/proc/{}/environ", child.id()))
        .expect_err("another process must not read the environment");
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    let result = Command::new("kill")
        .args(["-QUIT", &child.id().to_string()])
        .status()
        .expect("send SIGQUIT");
    assert!(result.success());
    let status = child.wait().expect("wait for SIGQUIT");
    assert_eq!(status.signal(), Some(3));
    assert!(!status.core_dumped());
    assert_eq!(
        before,
        (
            get_dumpable().expect("dumpability"),
            getrlimit(Resource::RLIMIT_CORE)
        )
    );
}

#[test]
#[ignore = "runs only in the isolated protection child"]
fn protected_child() {
    mailbend_io::process::no_dumps().expect("disable dumps");
    mailbend_io::process::no_dumps().expect("repeat protection");
    assert!(!get_dumpable().expect("dumpability"));
    assert_eq!(
        getrlimit(Resource::RLIMIT_CORE).expect("core limit"),
        (0, 0)
    );
    println!("protected child ready");
    std::io::stdout().flush().expect("ready");
    let _ = std::io::stdin().read(&mut [0]);
}
