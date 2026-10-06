//! Connecting the mail socket: a numeric override wins over DoH, which wins
//! over system DNS, all within one deadline. None of them changes the TLS
//! identity (the host name is still verified and sent as SNI), and the mail
//! socket is never routed through a proxy.

use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;

use mailbend_net::NetError;
use mailbend_net::connect::{Deadline, connect_any, resolve, set_timeouts};
use rustls::ClientConfig;

use crate::Exit;
use crate::settings::Settings;

pub fn connect(settings: &Settings, tls: &Arc<ClientConfig>) -> Result<TcpStream, Exit> {
    let deadline = Deadline::after(settings.timeout);
    let (route, addrs) = addresses(settings, tls, &deadline);
    let sock = addrs
        .and_then(|addrs| connect_any(&addrs, &deadline))
        .map_err(|e| {
            Exit::connect(format!(
                "cannot connect to {}:{} ({route}; {e})",
                settings.host, settings.port
            ))
        })?;
    // Mail I/O then uses per-operation timeouts of the same length.
    set_timeouts(&sock, settings.timeout)?;
    Ok(sock)
}

/// The addresses to try, with the name of the route that produced them for
/// error messages.
fn addresses(
    settings: &Settings,
    tls: &Arc<ClientConfig>,
    deadline: &Deadline,
) -> (&'static str, Result<Vec<SocketAddr>, NetError>) {
    let port = settings.port;
    if let Some(ip) = settings.connect_ip {
        return (
            "connection IP override",
            Ok(vec![SocketAddr::new(ip, port)]),
        );
    }
    let route = if settings.doh.is_some() {
        "DNS-over-HTTPS"
    } else {
        "system DNS"
    };
    let doh = settings.doh.as_ref();
    (route, resolve(doh, tls, &settings.host, port, deadline))
}
