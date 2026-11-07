use std::os::fd::AsFd;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, ChildStdout, Command, ExitStatus, Stdio};

use nix::errno::Errno;
use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::signal::{Signal, kill, killpg};
use nix::sys::signalfd::{SfdFlags, SignalFd};
use nix::unistd::{Pid, getpid, read, write};

use crate::{Error, managed_signals};

const CAPACITY: usize = 65536;

fn child_pid(child: &Child) -> Result<Pid, Error> {
    Ok(Pid::from_raw(
        i32::try_from(child.id()).map_err(|_| "invalid child id")?,
    ))
}

pub fn run() -> Result<ExitStatus, Error> {
    let stdout_flags =
        fcntl(std::io::stdout(), FcntlArg::F_GETFL).map_err(|_| "cannot inspect stdout")?;
    let relay_output = OFlag::from_bits_truncate(stdout_flags).contains(OFlag::O_NONBLOCK);
    let mask = managed_signals();
    mask.thread_block()
        .map_err(|_| "cannot supervise signals")?;
    let signals = SignalFd::with_flags(&mask, SfdFlags::SFD_NONBLOCK | SfdFlags::SFD_CLOEXEC)
        .map_err(|_| "cannot supervise signals")?;
    // Keep the executing inode usable when an install replaces its pathname.
    let mut child = Command::new("/proc/self/exe")
        .args(["--child", &getpid().as_raw().to_string()])
        .stdin(Stdio::piped())
        .stdout(if relay_output {
            Stdio::piped()
        } else {
            Stdio::inherit()
        })
        .process_group(0)
        .spawn()
        .map_err(|_| "cannot start core")?;
    let mut status = None;
    let result = transfer(&mut child, &signals, &mut status);
    if result.is_err() {
        if status.is_none()
            && let Ok(pid) = child_pid(&child)
        {
            let _killed = killpg(pid, Signal::SIGKILL);
        }
        let _reaped = child.wait();
    }
    result
}

fn nonblocking(pipe: &impl AsFd) -> Result<(), Error> {
    let flags = fcntl(pipe, FcntlArg::F_GETFL).map_err(|_| "cannot inspect core pipe")?;
    fcntl(
        pipe,
        FcntlArg::F_SETFL(OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK),
    )
    .map_err(|_| "cannot configure core pipe")?;
    Ok(())
}

fn forward(signals: &SignalFd, pid: Option<Pid>) -> Result<Option<Signal>, Error> {
    let mut forwarded = None;
    while let Some(info) = signals.read_signal().map_err(|_| "cannot read signal")? {
        let number = i32::try_from(info.ssi_signo).map_err(|_| "invalid signal")?;
        let signal = Signal::try_from(number).map_err(|_| "invalid signal")?;
        if signal != Signal::SIGCHLD {
            if let Some(pid) = pid {
                match kill(pid, signal) {
                    Ok(()) | Err(Errno::ESRCH) => {}
                    Err(_) => return Err("cannot forward signal"),
                }
            }
            forwarded = Some(signal);
        }
    }
    Ok(forwarded)
}

struct Output {
    pipe: Option<ChildStdout>,
    buffer: [u8; CAPACITY],
    start: usize,
    end: usize,
    disconnected: bool,
}

impl Output {
    fn new(pipe: ChildStdout) -> Result<Self, Error> {
        nonblocking(&pipe)?;
        Ok(Self {
            pipe: Some(pipe),
            buffer: [0; CAPACITY],
            start: 0,
            end: 0,
            disconnected: false,
        })
    }

    fn pending(&self) -> bool {
        self.start < self.end
    }

    fn done(&self) -> bool {
        self.pipe.is_none() && !self.pending()
    }

    fn poll_fd<'a>(&'a self, stdout: &'a std::io::Stdout) -> Option<PollFd<'a>> {
        if self.pending() {
            Some(PollFd::new(stdout.as_fd(), PollFlags::POLLOUT))
        } else {
            self.pipe
                .as_ref()
                .map(|pipe| PollFd::new(pipe.as_fd(), PollFlags::POLLIN))
        }
    }

    fn transfer(&mut self, stdout: &std::io::Stdout, ready: PollFlags) -> Result<(), Error> {
        if ready.is_empty() {
            return Ok(());
        }
        if ready.contains(PollFlags::POLLNVAL) {
            return Err("stdout descriptor closed");
        }
        if self.pending() {
            match write(stdout, &self.buffer[self.start..self.end]) {
                Ok(0) => return Err("cannot write stdout"),
                Ok(n) => self.start += n,
                Err(Errno::EINTR | Errno::EAGAIN) => {}
                Err(Errno::EPIPE | Errno::ECONNRESET) => {
                    self.pipe.take();
                    self.start = self.end;
                    self.disconnected = true;
                }
                Err(_) => return Err("cannot write stdout"),
            }
        } else if let Some(pipe) = &self.pipe {
            match read(pipe, &mut self.buffer) {
                Ok(0) => {
                    self.pipe.take();
                }
                Ok(n) => {
                    self.start = 0;
                    self.end = n;
                }
                Err(Errno::EINTR | Errno::EAGAIN) => {}
                Err(_) => return Err("cannot read core output"),
            }
        }
        Ok(())
    }
}

fn transfer(
    child: &mut Child,
    signals: &SignalFd,
    status: &mut Option<ExitStatus>,
) -> Result<ExitStatus, Error> {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut input = child.stdin.take();
    nonblocking(input.as_ref().ok_or("core pipe is missing")?)?;
    let mut output = child.stdout.take().map(Output::new).transpose()?;
    let pid = child_pid(child)?;
    let mut buffer = [0_u8; CAPACITY];
    let (mut start, mut end) = (0, 0);
    let mut stopping = false;
    loop {
        let forwarded = forward(signals, status.is_none().then_some(pid))?;
        if status.is_some() {
            if let Some(signal) = forwarded {
                return Ok(ExitStatus::from_raw(signal as i32));
            }
        } else {
            stopping |= forwarded.is_some();
            *status = child.try_wait().map_err(|_| "cannot reap core")?;
            if status.is_some() {
                input.take();
            }
        }
        if let Some(status) = *status
            && ((stopping && !status.success())
                || status.signal().is_some()
                || output.as_ref().is_none_or(Output::done))
        {
            if status.success() && output.as_ref().is_some_and(|out| out.disconnected) {
                return Err("stdout closed before output was delivered");
            }
            return Ok(status);
        }
        let pending = start < end;
        let mut fds = vec![PollFd::new(signals.as_fd(), PollFlags::POLLIN)];
        let input_index = input.as_ref().map(|pipe| {
            fds.push(if pending {
                PollFd::new(pipe.as_fd(), PollFlags::POLLOUT)
            } else {
                PollFd::new(stdin.as_fd(), PollFlags::POLLIN)
            });
            fds.len() - 1
        });
        let output_index = output
            .as_ref()
            .and_then(|out| out.poll_fd(&stdout))
            .map(|fd| {
                fds.push(fd);
                fds.len() - 1
            });
        match poll(&mut fds, PollTimeout::NONE) {
            Ok(_) => {}
            Err(Errno::EINTR) => continue,
            Err(_) => return Err("cannot wait for standard streams"),
        }
        let ready = |index: Option<usize>| {
            index
                .and_then(|i| fds[i].revents())
                .unwrap_or(PollFlags::empty())
        };
        let input_ready = ready(input_index);
        let output_ready = ready(output_index);
        drop(fds);
        if let Some(out) = &mut output {
            out.transfer(&stdout, output_ready)?;
            if out.disconnected {
                input.take();
            }
        }
        if input_ready.is_empty() || input.is_none() {
            continue;
        }
        if input_ready.contains(PollFlags::POLLNVAL) {
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
