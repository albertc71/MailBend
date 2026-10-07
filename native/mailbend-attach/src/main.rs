//! mailbend-attach: MailBend's local file access, safely.
//!
//!   mailbend-attach <dir> <path> <max-bytes>                 > file bytes
//!   mailbend-attach count <state-dir> <limit> <utc-day>      > ok <n> | full <n>
//!   mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> <path-list>
//!                                                            < file bytes
//!
//! The first form reads one attachment (`read.rs`); the second reserves one
//! send in the daily send counter (`count.rs`); the third saves one
//! downloaded attachment (`save.rs`). What they share is in `dirs.rs`.
//! Kept apart from mailbend-tls so the credential-bearing helper never
//! touches files: this program opens no connection, and before anything else
//! it re-executes itself with an empty environment. How files are opened,
//! and which are refused, is specified in native/README.md ("Attachments",
//! "Send counter", "Downloads"); each step is documented where it is done.
//!
//! Exit status: 0 ok (for `count`, also when the limit is reached), 2 refused
//! or unreadable (the reason is on stderr).

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::process::ExitCode;

use mailbend_io::env::reexec_with;
use mailbend_io::report::report;

mod count;
mod dirs;
mod read;
mod save;

const PROGRAM: &str = "mailbend-attach";
const EX_REFUSED: u8 = 2;
const USAGE: &str = "usage: mailbend-attach <dir> <path> <max-bytes> | \
                     mailbend-attach count <state-dir> <limit> <utc-day> | \
                     mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> \
                     <path-list>";

type Refusal = String;

fn main() -> ExitCode {
    // A panic must not print its payload, which could hold file names.
    std::panic::set_hook(Box::new(|_| {
        report(PROGRAM, "internal error");
        std::process::exit(i32::from(EX_REFUSED))
    }));
    let args: Vec<OsString> = std::env::args_os().collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            report(PROGRAM, reason);
            ExitCode::from(EX_REFUSED)
        }
    }
}

fn run(args: &[OsString]) -> Result<(), Refusal> {
    // No variable is kept: everything the forms need is in their arguments.
    reexec_with(args, &[])?;
    match args {
        [_, mode, dir, limit, day] if mode == "count" => {
            count::count_send(dir.as_bytes(), limit.as_bytes(), day.as_bytes())
        }
        [_, mode, attach, download, name, max, paths] if mode == "save" => save::save_download(
            attach.as_bytes(),
            download.as_bytes(),
            name.as_bytes(),
            max.as_bytes(),
            paths.as_bytes(),
        ),
        [_, dir, path, max] if dir != "count" && dir != "save" => {
            read::read_attachment(dir.as_bytes(), path.as_bytes(), max.as_bytes())
        }
        _ => Err(USAGE.to_string()),
    }
}
