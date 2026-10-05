//! mailbend-tls: the verified TLS transport behind MailBend.
//!
//!   mailbend-tls imap   < commands    > server transcript
//!   mailbend-tls smtp   < envelope    > server transcript
//!   mailbend-tls --check              (credential-free readiness check)
//!
//! The whole network boundary of the mail core: sockets, TLS and
//! authentication. Which commands to send, and what the answers mean, is
//! decided by the Bend core. The input formats, settings, output encoding
//! and exit statuses are specified in native/README.md ("Contract").

use std::process::ExitCode;

use mailbend_io::report::report;
use mailbend_tls::{Exit, Failure, Outcome, Protocol};

const PROGRAM: &str = "mailbend-tls";

fn main() -> ExitCode {
    // A panic must not print its payload, which could hold server data.
    std::panic::set_hook(Box::new(|_| {
        report(PROGRAM, "internal error");
        std::process::exit(i32::from(Failure::Protocol as u8))
    }));
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let args: Vec<&str> = args.iter().map(|a| a.to_str().unwrap_or("")).collect();
    let result = match args.as_slice() {
        ["--check"] => Ok(Outcome::Completed),
        ["imap"] => mailbend_tls::run(Protocol::Imap),
        ["smtp"] => mailbend_tls::run(Protocol::Smtp),
        _ => Err(Exit::usage("usage: mailbend-tls imap|smtp|--check")),
    };
    match result {
        Ok(outcome) => {
            if let Outcome::Rejected(reason) = &outcome {
                report(PROGRAM, reason);
            }
            ExitCode::from(outcome.code())
        }
        Err(exit) => {
            report(PROGRAM, &exit.message);
            ExitCode::from(exit.code())
        }
    }
}
