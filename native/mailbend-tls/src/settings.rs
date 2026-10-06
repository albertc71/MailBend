//! The mail settings, read once from the environment and checked before
//! anything connects. A set value that is not UTF-8 (other than a file
//! path) is a usage error, never treated as unset.

use std::net::IpAddr;
use std::path::PathBuf;
use std::time::Duration;

use mailbend_io::env::{text_var, timeout};
use mailbend_net::doh::Resolver;
use mailbend_net::tls::{ca_file_setting, server_name};
use mailbend_net::url::parse_port;

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
        let doh = Resolver::from_setting().map_err(Exit::usage)?;
        let timeout = timeout().map_err(Exit::usage)?;
        let ca_file = ca_file_setting();
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
