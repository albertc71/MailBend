//! `mailbend-tls`, the verified TLS transport behind MailBend, as a library:
//! the binary only reads its arguments and reports the result of [`run`].
//!
//! The parsers (`imap::script`, `imap::response`, `smtp::envelope`,
//! `smtp::reply`) touch no network and are unit-tested and fuzzed.
//! The sessions drive them over one server connection.

pub mod exit;
pub mod imap;
pub(crate) mod limits;
pub mod smtp;
pub(crate) mod text;

mod connection;
mod creds;
mod route;
mod settings;

use std::io::Read;

use mailbend_io::secret::refuse_typesafe_api_key;
use mailbend_net::tls;
use zeroize::Zeroizing;

use crate::connection::Connection;
use crate::limits::MAX_SCRIPT;
use crate::settings::Settings;

pub use exit::{Exit, Failure, Outcome};
pub use settings::Protocol;

/// Runs the script (IMAP) or envelope (SMTP) on stdin against the mail
/// server, writing the server's transcript to stdout. Everything that can
/// be checked locally is checked before connecting.
pub fn run(protocol: Protocol) -> Result<Outcome, Exit> {
    refuse_typesafe_api_key().map_err(Exit::usage)?;
    let settings = Settings::from_env(protocol)?;
    let credentials = creds::load()?;
    let input = read_input()?;
    let plan = Plan::parse(protocol, &input)?;
    let tls = tls::client_config(settings.ca_file.as_deref())?;
    let mut conn = Connection::new(route::connect(&settings, &tls)?);
    let host = &settings.host;
    let outcome = match &plan {
        Plan::Imap(commands) => imap::session::run(&mut conn, &tls, host, &credentials, commands),
        Plan::Smtp(steps) => smtp::session::run(&mut conn, &tls, host, &credentials, steps),
    };
    conn.flush_transcript();
    outcome
}

/// The parsed input: the whole of it is checked before connecting, so a
/// malformed later command is never found only after earlier ones ran.
enum Plan<'a> {
    Imap(Vec<imap::script::Command<'a>>),
    Smtp(Vec<smtp::envelope::Step<'a>>),
}

impl<'a> Plan<'a> {
    fn parse(protocol: Protocol, input: &'a [u8]) -> Result<Self, Exit> {
        Ok(match protocol {
            Protocol::Imap => Plan::Imap(imap::script::parse(input)?),
            Protocol::Smtp => Plan::Smtp(smtp::envelope::parse(input)?),
        })
    }
}

/// The whole of stdin, up to the script limit.
fn read_input() -> Result<Zeroizing<Vec<u8>>, Exit> {
    let mut input = Zeroizing::new(Vec::new());
    std::io::stdin()
        .take(MAX_SCRIPT as u64)
        .read_to_end(&mut input)
        .map_err(|_| Exit::usage("cannot read the command script"))?;
    if input.len() >= MAX_SCRIPT {
        return Err(Exit::usage("command script exceeds the input limit"));
    }
    Ok(input)
}
