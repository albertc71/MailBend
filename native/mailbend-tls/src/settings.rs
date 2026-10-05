//! The mail settings, read once from the environment and checked before
//! anything connects. A set value that is not UTF-8 (other than a file
//! path) is a usage error, never treated as unset.

use std::net::IpAddr;
use std::path::PathBuf;
use std::time::Duration;

use mailbend_io::env::text_var;
use mailbend_net::doh::Resolver;
use mailbend_net::tls::server_name;
use mailbend_net::url::{DohUrl, parse_port};

use crate::Exit;

/// The mail protocol the helper speaks for this run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protocol {
    Imap,
    Smtp,
}

/// Where a protocol's settings live, and their defaults (iCloud Mail).
struct Service {
    host_var: &'static str,
    port_var: &'static str,
    connect_ip_var: &'static str,
    default_host: &'static str,
    default_port: u16,
}

impl Protocol {
    fn service(self) -> Service {
        match self {
            Protocol::Imap => Service {
                host_var: "MAILBEND_IMAP_HOST",
                port_var: "MAILBEND_IMAP_PORT",
                connect_ip_var: "MAILBEND_IMAP_CONNECT_IP",
                default_host: "imap.mail.me.com",
                default_port: 993,
            },
            Protocol::Smtp => Service {
                host_var: "MAILBEND_SMTP_HOST",
                port_var: "MAILBEND_SMTP_PORT",
                connect_ip_var: "MAILBEND_SMTP_CONNECT_IP",
                default_host: "smtp.mail.me.com",
                default_port: 587,
            },
        }
    }
}

#[derive(Debug)]
pub struct Settings {
    /// The mail server's name: verified in its certificate and sent as SNI.
    pub host: String,
    pub port: u16,
    /// MAILBEND_<IMAP|SMTP>_CONNECT_IP: connect here instead of resolving.
    pub connect_ip: Option<IpAddr>,
    /// MAILBEND_DOH_URL: resolve through this HTTPS resolver, reached
    /// through the proxy from https_proxy and the like.
    pub doh: Option<Resolver>,
    /// MAILBEND_TIMEOUT_MS: the budget for resolving and connecting, then
    /// for each read and write.
    pub timeout: Duration,
    /// MAILBEND_CA_FILE: trust only these certificates.
    pub ca_file: Option<PathBuf>,
}

impl Settings {
    pub fn from_env(protocol: Protocol) -> Result<Settings, Exit> {
        let service = protocol.service();
        let host =
            text_setting(service.host_var)?.unwrap_or_else(|| service.default_host.to_string());
        if server_name(&host).is_err() {
            return Err(Exit::usage(format!(
                "{} is not a valid host name or IP address",
                service.host_var
            )));
        }
        let port = match text_setting(service.port_var)? {
            Some(port) => parse_port(&port).ok_or_else(|| {
                Exit::usage(format!(
                    "{} must be a port number from 1 to 65535",
                    service.port_var
                ))
            })?,
            None => service.default_port,
        };
        let connect_ip = match text_setting(service.connect_ip_var)? {
            Some(ip) => Some(ip.parse::<IpAddr>().map_err(|_| {
                Exit::usage(format!(
                    "{} must be one numeric IPv4 or IPv6 address",
                    service.connect_ip_var
                ))
            })?),
            None => None,
        };
        let doh = match text_setting("MAILBEND_DOH_URL")? {
            Some(url) => {
                let url = DohUrl::parse(&url)
                    .ok_or_else(|| Exit::usage("MAILBEND_DOH_URL must be an HTTPS URL"))?;
                Some(Resolver::from_env(url).map_err(|e| Exit::usage(e.to_string()))?)
            }
            None => None,
        };
        let timeout = parse_timeout(text_setting("MAILBEND_TIMEOUT_MS")?.as_deref());
        let ca_file = std::env::var_os("MAILBEND_CA_FILE")
            .filter(|path| !path.is_empty())
            .map(PathBuf::from);
        Ok(Settings {
            host,
            port,
            connect_ip,
            doh,
            timeout,
            ca_file,
        })
    }
}

fn text_setting(name: &str) -> Result<Option<String>, Exit> {
    text_var(name).map_err(Exit::usage)
}

/// MAILBEND_TIMEOUT_MS read like C's atoi: leading spaces, a sign and
/// digits, anything after ignored; a missing or nonpositive value means 30
/// seconds.
fn parse_timeout(value: Option<&str>) -> Duration {
    const DEFAULT_MS: u64 = 30_000;
    let Some(s) = value.map(str::trim_start) else {
        return Duration::from_millis(DEFAULT_MS);
    };
    let (negative, digits) = match s.as_bytes().first() {
        Some(b'-') => (true, &s[1..]),
        Some(b'+') => (false, &s[1..]),
        _ => (false, s),
    };
    let end = digits
        .bytes()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(digits.len());
    let ms = match digits[..end].parse::<u64>() {
        Ok(ms) if ms > 0 && !negative => ms.min(i32::MAX as u64),
        _ => DEFAULT_MS,
    };
    Duration::from_millis(ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeouts_parse_like_atoi() {
        let ms = |value| parse_timeout(value).as_millis();
        assert_eq!(ms(None), 30_000);
        assert_eq!(ms(Some("1500")), 1500);
        assert_eq!(ms(Some("  250ms")), 250);
        assert_eq!(ms(Some("+7")), 7);
        assert_eq!(ms(Some("0")), 30_000);
        assert_eq!(ms(Some("-5")), 30_000);
        assert_eq!(ms(Some("x")), 30_000);
        assert_eq!(ms(Some("99999999999")), u128::from(i32::MAX.unsigned_abs()));
    }
}
