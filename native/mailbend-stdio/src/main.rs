//! Adapts inherited socket stdin to a pipe for Bend's pathname-based File.open.
//! The only target is the sibling core in MCP mode (or the existing Bend fallback).

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, ExitStatus};

use mailbend_io::report::report;
use nix::sys::prctl::set_pdeathsig;
use nix::sys::signal::{SigSet, Signal, raise};
use nix::sys::stat::{SFlag, fstat};
use nix::unistd::{Pid, getppid};

mod relay;

type Error = &'static str;

fn managed_signals() -> SigSet {
    let mut signals = SigSet::empty();
    for signal in [
        Signal::SIGINT,
        Signal::SIGTERM,
        Signal::SIGHUP,
        Signal::SIGQUIT,
        Signal::SIGCHLD,
    ] {
        signals.add(signal);
    }
    signals
}

fn executable(path: &Path) -> bool {
    path.metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

fn exec_core() -> Result<ExitStatus, Error> {
    let exe = std::env::current_exe().map_err(|_| "cannot locate installed helper")?;
    let bin = exe.parent().ok_or("cannot locate installed helper")?;
    let core = bin.join("mailbend-core");
    if executable(&core) {
        let _error = Command::new(core).arg("mcp").exec();
        return Err("cannot execute core");
    }
    let root = bin.parent().ok_or("cannot locate installed core")?;
    let main = root.join("main.bend");
    if !main.is_file() {
        return Err("core is missing; run scripts/install.sh");
    }
    let error = Command::new("bend").arg(&main).arg("mcp").exec();
    if error.kind() != std::io::ErrorKind::NotFound {
        return Err("cannot execute Bend");
    }
    if let Some(home) = std::env::var_os("HOME") {
        let bend = Path::new(&home).join(".bend/bin/bend");
        if executable(&bend) {
            let _error = Command::new(bend).arg(main).arg("mcp").exec();
            return Err("cannot execute Bend");
        }
    }
    Err("core or Bend is missing; run scripts/install.sh")
}

fn child(parent: &str) -> Result<ExitStatus, Error> {
    let expected = parent
        .parse::<i32>()
        .ok()
        .filter(|p| *p > 0)
        .ok_or("invalid parent")?;
    // Setting the signal before checking the parent closes the spawn-to-exec death race.
    set_pdeathsig(Signal::SIGKILL).map_err(|_| "cannot protect child lifetime")?;
    if getppid() != Pid::from_raw(expected) {
        return Err("parent exited before core startup");
    }
    managed_signals()
        .thread_unblock()
        .map_err(|_| "cannot restore core signals")?;
    exec_core()
}

fn run() -> Result<ExitStatus, Error> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.as_slice() {
        [arg] if arg == "--check" => Ok(ExitStatus::from_raw(0)),
        [arg, parent] if arg == "--child" => child(parent.to_str().ok_or("invalid parent")?),
        [arg] if arg == "mcp" => {
            let stat = fstat(std::io::stdin()).map_err(|_| "cannot inspect stdin")?;
            if SFlag::from_bits_truncate(stat.st_mode).contains(SFlag::S_IFSOCK) {
                relay::run()
            } else {
                exec_core()
            }
        }
        _ => Err("usage: mailbend-stdio mcp | --check"),
    }
}

fn main() {
    let status = match run() {
        Ok(status) => status,
        Err(message) => {
            report("mailbend-stdio", message);
            std::process::exit(2);
        }
    };
    if let Some(code) = status.code() {
        std::process::exit(code);
    }
    if let Some(number) = status.signal() {
        if let Ok(signal) = Signal::try_from(number) {
            let mut mask = SigSet::empty();
            mask.add(signal);
            let _unblocked = mask.thread_unblock();
            let _raised = raise(signal);
        }
        std::process::exit(128 + number);
    }
    std::process::exit(2);
}
