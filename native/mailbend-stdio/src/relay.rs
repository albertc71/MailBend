use std::os::fd::AsFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};

use nix::errno::Errno;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{Signal, killpg};
use nix::sys::signalfd::{SfdFlags, SignalFd};
use nix::unistd::{Pid, getpid, read, write};

use crate::{Error, managed_signals};

const CAPACITY: usize = 65536;

fn group(child: &Child) -> Result<Pid, Error> {
    Ok(Pid::from_raw(
        i32::try_from(child.id()).map_err(|_| "invalid child id")?,
    ))
}

pub fn run() -> Result<ExitStatus, Error> {
    let mask = managed_signals();
    mask.thread_block()
        .map_err(|_| "cannot supervise signals")?;
    let signals = SignalFd::with_flags(&mask, SfdFlags::SFD_NONBLOCK | SfdFlags::SFD_CLOEXEC)
        .map_err(|_| "cannot supervise signals")?;
    // Keep the executing inode usable when an install replaces its pathname.
    let mut child = Command::new("/proc/self/exe")
        .args(["--child", &getpid().as_raw().to_string()])
        .stdin(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|_| "cannot start core")?;
    let result = transfer(&mut child, &signals);
    if result.is_err() {
        if let Ok(pid) = group(&child) {
            let _killed = killpg(pid, Signal::SIGKILL);
        }
        let _reaped = child.wait();
    }
    result
}

fn nonblocking(input: &ChildStdin) -> Result<(), Error> {
    let flags = fcntl(input, FcntlArg::F_GETFL).map_err(|_| "cannot inspect core pipe")?;
    fcntl(
        input,
        FcntlArg::F_SETFL(OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK),
    )
    .map_err(|_| "cannot configure core pipe")?;
    Ok(())
}

fn forward(signals: &SignalFd, pid: Pid) -> Result<(), Error> {
    while let Some(info) = signals.read_signal().map_err(|_| "cannot read signal")? {
        let number = i32::try_from(info.ssi_signo).map_err(|_| "invalid signal")?;
        let signal = Signal::try_from(number).map_err(|_| "invalid signal")?;
        if signal != Signal::SIGCHLD {
            match killpg(pid, signal) {
                Ok(()) | Err(Errno::ESRCH) => {}
                Err(_) => return Err("cannot forward signal"),
            }
        }
    }
    Ok(())
}

fn transfer(child: &mut Child, signals: &SignalFd) -> Result<ExitStatus, Error> {
    let stdin = std::io::stdin();
    let mut input = child.stdin.take();
    nonblocking(input.as_ref().ok_or("core pipe is missing")?)?;
    let pid = group(child)?;
    let mut buffer = [0_u8; CAPACITY];
    let (mut start, mut end) = (0, 0);
    loop {
        forward(signals, pid)?;
        if let Some(status) = child.try_wait().map_err(|_| "cannot reap core")? {
            return Ok(status);
        }
        let pending = start < end;
        let mut fds = vec![PollFd::new(signals.as_fd(), PollFlags::POLLIN)];
        if let Some(pipe) = &input {
            fds.push(if pending {
                PollFd::new(pipe.as_fd(), PollFlags::POLLOUT)
            } else {
                PollFd::new(stdin.as_fd(), PollFlags::POLLIN)
            });
        }
        match poll(&mut fds, PollTimeout::NONE) {
            Ok(_) => {}
            Err(Errno::EINTR) => continue,
            Err(_) => return Err("cannot wait for stdin"),
        }
        let ready = fds
            .get(1)
            .and_then(PollFd::revents)
            .unwrap_or(PollFlags::empty());
        if ready.is_empty() {
            continue;
        }
        if ready.contains(PollFlags::POLLNVAL) {
            return Err("stdin descriptor closed");
        }
        if pending {
            let pipe = input.as_ref().ok_or("core pipe is missing")?;
            match write(pipe, &buffer[start..end]) {
                Ok(n) => start += n,
                Err(Errno::EINTR | Errno::EAGAIN) => {}
                Err(Errno::EPIPE) => {
                    input.take();
                }
                Err(_) => return Err("cannot write core input"),
            }
        } else {
            match read(&stdin, &mut buffer) {
                Ok(0) => {
                    input.take();
                }
                Ok(n) => {
                    start = 0;
                    end = n;
                }
                Err(Errno::EINTR | Errno::EAGAIN) => {}
                Err(Errno::ECONNRESET) => {
                    input.take();
                }
                Err(_) => return Err("cannot read stdin"),
            }
        }
    }
}
