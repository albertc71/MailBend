//! A minimal RFC 8484 DNS-over-HTTPS client: one POST of an
//! application/dns-message per question, over the same verified TLS
//! configuration as mail, with every read and write bounded by the caller's
//! deadline. There is no fallback to system DNS for the name being looked
//! up.

use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;

use rustls::{ClientConfig, ClientConnection, StreamOwned};

use crate::NetError;
use crate::connect::{BoundedStream, Deadline, connect_any, resolve_system};
use crate::dns::{RecordType, build_query, parse_answer};
use crate::http::{MAX_BODY, MAX_HEADER, parse_response};
use crate::proxy::{Proxy, proxy_for};
use crate::tls;
use crate::url::{DohUrl, format_authority};

/// The default cloud resolver, reached without consulting system DNS. These
/// are the resolver's anycast addresses, never pinned mail addresses.
const BOOTSTRAP_HOST: &str = "cloudflare-dns.com";
const BOOTSTRAP_ADDRS: [Ipv4Addr; 2] = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(1, 0, 0, 1)];

type DohStream = StreamOwned<ClientConnection, BoundedStream>;

/// A DoH resolver and the way to reach it.
#[derive(Debug)]
pub struct Resolver {
    pub url: DohUrl,
    pub proxy: Option<Proxy>,
}

impl Resolver {
    /// The resolver at `url`, reached through the proxy the environment
    /// configures for it, if any.
    pub fn from_env(url: DohUrl) -> Result<Resolver, NetError> {
        let proxy = proxy_for(&url.host)?;
        Ok(Resolver { url, proxy })
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
        read_response(&mut stream)
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
fn read_response(stream: &mut DohStream) -> Result<Vec<u8>, NetError> {
    let no_answer = || NetError::Doh("no answer from the resolver".to_string());
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let (n, eof) = match stream.read(&mut chunk) {
            Ok(0) => (0, true),
            Ok(n) => (n, false),
            // Many servers close without TLS close_notify; the response's
            // own framing and the DNS checks decide whether it is complete.
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => (0, true),
            Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) => {
                return Err(NetError::TimedOut);
            }
            Err(_) => return Err(no_answer()),
        };
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() > MAX_HEADER + MAX_BODY {
            return Err(NetError::Doh(
                "the resolver's answer is too long".to_string(),
            ));
        }
        if let Some(response) = parse_response(&buf, eof)? {
            if response.status != 200 {
                return Err(NetError::Doh(format!(
                    "the resolver answered HTTP {}",
                    response.status
                )));
            }
            return Ok(response.body);
        }
        if eof {
            return Err(no_answer());
        }
    }
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
