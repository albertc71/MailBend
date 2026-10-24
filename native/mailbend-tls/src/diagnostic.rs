//! Redacted transport facts. Bend chooses whether to connect and interprets
//! these fixed tokens. There is no envelope, mail command or send counter.

use mailbend_io::secret::refuse_typesafe_api_key;
use mailbend_net::connect::{Deadline, connect_any, set_timeouts};
use mailbend_net::tls;

use crate::connection::Connection;
use crate::settings::Settings;
use crate::{Exit, Outcome, Protocol, creds, imap, route, smtp};

/// Always completes with fixed facts, never an error message or transcript.
/// The Bend caller additionally enforces a 30-second process deadline.
pub fn run(protocol: Protocol, network: bool) -> Result<Outcome, Exit> {
    if let Err((stage, reason)) = check(protocol, network) {
        println!("{stage} {reason}");
    }
    Ok(Outcome::Completed)
}

type Problem = (&'static str, &'static str);

fn check(protocol: Protocol, network: bool) -> Result<(), Problem> {
    refuse_typesafe_api_key().map_err(|_| ("configuration", "invalid"))?;
    let settings = Settings::from_env(protocol).map_err(|_| ("configuration", "invalid"))?;
    println!("configuration ok");
    let credentials = creds::load().map_err(|_| ("credentials", "invalid"))?;
    println!("credentials ok");
    let tls =
        tls::client_config(settings.ca_file.as_deref()).map_err(|_| ("trust_store", "invalid"))?;
    println!("trust_store ok");
    if !network {
        return Ok(());
    }
    let deadline = Deadline::after(settings.timeout);
    let (_, addresses) = route::addresses(&settings, &tls, &deadline);
    let addresses = addresses.map_err(|_| ("dns", "failed"))?;
    println!(
        "dns {}",
        if settings.connect_ip.is_some() {
            "skipped"
        } else {
            "ok"
        }
    );
    let sock = connect_any(&addresses, &deadline).map_err(|_| ("connect", "failed"))?;
    set_timeouts(&sock, settings.timeout).map_err(|_| ("connect", "failed"))?;
    let mut conn = Connection::diagnostic(sock);
    // Empty plans mean authentication and orderly disconnect only.
    // Diagnostics bypass envelope parsing and never accept message input.
    let result = match protocol {
        Protocol::Imap => imap::session::run(&mut conn, &tls, &settings.host, &credentials, &[]),
        Protocol::Smtp => smtp::session::run(&mut conn, &tls, &settings.host, &credentials, &[]),
    };
    result.map_err(|e| (conn.stage, reason(&e)))?;
    Ok(())
}

fn reason(error: &Exit) -> &'static str {
    match error.message.as_str() {
        "server does not offer STARTTLS" => "unsupported_tls",
        "server offers neither AUTH PLAIN nor AUTH LOGIN" => "unsupported_auth",
        _ => "failed",
    }
}
