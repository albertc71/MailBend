//! A minimal RFC 8484 DNS-over-HTTPS client: one POST of an
//! application/dns-message per question, over the same verified TLS
//! configuration as mail, with every read and write bounded by the caller's
//! deadline. There is no fallback to system DNS for the name being looked
//! up.

use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;

use mailbend_io::env::text_var;
use rustls::ClientConfig;

use crate::NetError;
use crate::connect::{BoundedStream, Deadline, connect_any, resolve_system};
use crate::dns::{RecordType, build_query, parse_answer};
use crate::http::read_response;
use crate::proxy::{Proxy, proxy_for};
use crate::tls::{self, TlsStream};
use crate::url::{DohUrl, format_authority};

/// The default cloud resolver, reached without consulting system DNS. These
/// are the resolver's anycast addresses, never pinned mail addresses.
const BOOTSTRAP_HOST: &str = "cloudflare-dns.com";
const BOOTSTRAP_ADDRS: [Ipv4Addr; 2] = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(1, 0, 0, 1)];

/// No DNS answer MailBend asks for comes near this; larger bodies are
/// refused.
const MAX_BODY: usize = 65535;

/// A DoH resolver and the way to reach it.
#[derive(Debug)]
pub struct Resolver {
    url: DohUrl,
    proxy: Option<Proxy>,
}

impl Resolver {
    /// The resolver MAILBEND_DOH_URL names, if it is set and nonempty,
    /// reached through the proxy the environment configures for it, if
    /// any. The error is a message for the operator: a bad URL or proxy
    /// setting.
    pub fn from_setting() -> Result<Option<Resolver>, String> {
        let Some(url) = text_var("MAILBEND_DOH_URL")? else {
            return Ok(None);
        };
        let url = DohUrl::parse(&url).ok_or("MAILBEND_DOH_URL must be an HTTPS URL")?;
        let proxy = proxy_for(&url.host).map_err(|e| e.to_string())?;
        Ok(Some(Resolver { url, proxy }))
    }

    /// Looks up `name`'s IPv4 and IPv6 addresses (IPv4 first); an IP
    /// literal needs no lookup. The two questions are asked at the same
    /// time, and either may answer for both: the lookup fails only when
    /// neither returns an address, with the first error if any.
    pub fn resolve(
        &self,
        config: &Arc<ClientConfig>,
        name: &str,
        deadline: &Deadline,
    ) -> Result<Vec<IpAddr>, NetError> {
        if let Ok(ip) = name.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        let lookup = |record| self.lookup(config, name, record, deadline);
        let (a, aaaa) = std::thread::scope(|scope| {
            let aaaa = std::thread::Builder::new()
                .name("doh-aaaa".to_string())
                .spawn_scoped(scope, || lookup(RecordType::Aaaa));
            let a = lookup(RecordType::A);
            let aaaa = match aaaa {
                Ok(thread) => thread
                    .join()
                    .unwrap_or_else(|_| Err(NetError::Doh("the AAAA lookup failed".to_string()))),
                // No thread to spare: ask in turn instead.
                Err(_) => lookup(RecordType::Aaaa),
            };
            (a, aaaa)
        });
        let mut found = Vec::new();
        let mut first_error = None;
        for result in [a, aaaa] {
            match result {
                Ok(addresses) => found.extend(addresses),
                Err(e) => {
                    first_error.get_or_insert(e);
                }
            }
        }
        if !found.is_empty() {
            return Ok(found);
        }
        Err(first_error.unwrap_or_else(|| NetError::Dns(format!("{name} has no addresses"))))
    }

    fn lookup(
        &self,
        config: &Arc<ClientConfig>,
        name: &str,
        record: RecordType,
        deadline: &Deadline,
    ) -> Result<Vec<IpAddr>, NetError> {
        let answer = self.exchange(config, &build_query(name, record)?, deadline)?;
        parse_answer(&answer, record)
    }

    /// POSTs one DNS query and returns the response body.
    fn exchange(
        &self,
        config: &Arc<ClientConfig>,
        query: &[u8],
        deadline: &Deadline,
    ) -> Result<Vec<u8>, NetError> {
        let url = &self.url;
        let mut stream = tls::connect(config, &url.host, self.socket(deadline)?)?;
        let request = format!(
            "POST {path} HTTP/1.1\r\nHost: {host}\r\nAccept: application/dns-message\r\n\
             Content-Type: application/dns-message\r\nContent-Length: {length}\r\n\
             User-Agent: mailbend\r\nConnection: close\r\n\r\n",
            path = url.path,
            host = format_authority(&url.host, url.port, Some(443)),
            length = query.len(),
        );
        stream
            .write_all(request.as_bytes())
            .and_then(|()| stream.write_all(query))
            .and_then(|()| stream.flush())
            .map_err(|_| NetError::Doh("cannot send the DNS query".to_string()))?;
        read_answer(&mut stream)
    }

    /// A connection to the resolver, directly or through the proxy.
    fn socket(&self, deadline: &Deadline) -> Result<BoundedStream, NetError> {
        let url = &self.url;
        match &self.proxy {
            Some(proxy) => proxy.tunnel(&url.host, url.port, deadline),
            None => {
                let sock = connect_any(&bootstrap(&url.host, url.port, deadline)?, deadline)?;
                Ok(BoundedStream::new(sock, *deadline))
            }
        }
    }
}

/// Reads the HTTP response and returns its body, which must come with
/// status 200.
fn read_answer(stream: &mut TlsStream<BoundedStream>) -> Result<Vec<u8>, NetError> {
    let response = read_response(stream, MAX_BODY).map_err(|e| match e {
        NetError::Http(message) => NetError::Doh(format!("{message} from the resolver")),
        e => e,
    })?;
    if response.status != 200 {
        return Err(NetError::Doh(format!(
            "the resolver answered HTTP {}",
            response.status
        )));
    }
    Ok(response.body)
}

/// The resolver's own addresses: the fixed bootstrap for the default
/// resolver, else system DNS.
fn bootstrap(host: &str, port: u16, deadline: &Deadline) -> Result<Vec<SocketAddr>, NetError> {
    if host.eq_ignore_ascii_case(BOOTSTRAP_HOST) && port == 443 {
        return Ok(BOOTSTRAP_ADDRS
            .iter()
            .map(|&ip| SocketAddr::from((ip, port)))
            .collect());
    }
    resolve_system(host, port, deadline)
}
