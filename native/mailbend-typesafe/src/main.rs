//! mailbend-typesafe: MailBend's only connection to TypeSafe's Jev.
//!
//!   mailbend-typesafe ask     < request JSON   > TypeSafe's answer
//!   mailbend-typesafe --check                  (readiness check; no network)
//!
//! The Bend core builds the request and interprets the answer; this program
//! only carries it to the fixed endpoint `https://api.typesafe.ai/v1/systemone`
//! over verified TLS. The key comes only from MAILBEND_TYPESAFE_KEY_FILE,
//! and the program first re-executes itself with an allow-listed
//! environment, so the key never shares a process with the mail password.
//! A refused request's answer is written to stdout too, as it holds
//! TypeSafe's reason. Exit statuses are listed in `exit.rs`.

use std::ffi::OsString;
use std::io::Write;
use std::process::ExitCode;

use mailbend_io::report::report;
use mailbend_io::secret::refuse_typesafe_api_key;

mod api;
mod environment;
mod exit;
mod settings;

use crate::exit::{Exit, Failure};

const PROGRAM: &str = "mailbend-typesafe";

fn main() -> ExitCode {
    // A panic must not print its payload, which could hold an answer.
    std::panic::set_hook(Box::new(|_| {
        report(PROGRAM, "internal error");
        std::process::exit(i32::from(Failure::Unexpected as u8))
    }));
    let args: Vec<OsString> = std::env::args_os().collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(exit) => {
            report(PROGRAM, &exit.message);
            ExitCode::from(exit.code())
        }
    }
}

fn run(args: &[OsString]) -> Result<(), Exit> {
    let modes: Vec<&str> = args
        .iter()
        .skip(1)
        .map(|a| a.to_str().unwrap_or(""))
        .collect();
    match modes.as_slice() {
        ["--check"] => Ok(()),
        ["ask"] => {
            // Refused before the environment is dropped, which would hide it.
            refuse_typesafe_api_key().map_err(Exit::input)?;
            environment::confine(args).map_err(Exit::input)?;
            ask()
        }
        _ => Err(Exit::input("usage: mailbend-typesafe ask|--check")),
    }
}

fn ask() -> Result<(), Exit> {
    let settings = settings::Settings::from_env()?;
    let key = settings::read_key()?;
    let request = settings::read_request()?;
    let (body, result) = match api::ask(&settings, &key, &request) {
        Ok(body) => (body, Ok(())),
        Err((exit, body)) => (body, Err(exit)),
    };
    let mut out = std::io::stdout().lock();
    out.write_all(&body)
        .and_then(|()| out.flush())
        .map_err(|_| Exit::new(Failure::Unexpected, "cannot write the answer"))?;
    result
}
