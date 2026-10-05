//! The HTTP proxy the DoH resolver connection may use, chosen like curl
//! chooses one for HTTPS. Mail connections never use a proxy.

use std::io::{Read, Write};

use base64ct::{Base64, Encoding};
use mailbend_io::env::text_var;

use crate::NetError;
use crate::connect::{BoundedStream, Deadline, connect_any, resolve_system};
use crate::http::MAX_HEADER;
use crate::url::{format_authority, parse_authority};

/// The port of a proxy URL that names none, as in curl.
const DEFAULT_PROXY_PORT: u16 = 1080;

/// An HTTP proxy, reached with `CONNECT`.
#[derive(Debug, PartialEq, Eq)]
pub struct Proxy {
    pub host: String,
    pub port: u16,
    /// `user:password` for Basic proxy authentication, percent-decoded.
    pub credentials: Option<String>,
}

impl Proxy {
    /// Parses `[http://][user:password@]host[:port][/]`. Other schemes,
    /// such as `socks5://` or `https://`, are refused rather than bypassed.
    pub fn parse(url: &str) -> Result<Proxy, NetError> {
        let unsupported = || {
            NetError::Proxy(
                "the HTTPS proxy setting is not a supported http:// proxy URL".to_string(),
            )
        };
        let rest = match url.split_once("://") {
            Some((scheme, rest)) if scheme.eq_ignore_ascii_case("http") => rest,
            Some(_) => return Err(unsupported()),
            None => url,
        };
        let rest = rest.strip_suffix('/').unwrap_or(rest);
        let (credentials, authority) = match rest.rsplit_once('@') {
            Some((userinfo, authority)) => {
                let credentials = percent_decode(userinfo).ok_or_else(unsupported)?;
                (Some(credentials), authority)
            }
            None => (None, rest),
        };
        let (host, port) =
            parse_authority(authority, DEFAULT_PROXY_PORT).ok_or_else(unsupported)?;
        Ok(Proxy {
            host,
            port,
            credentials,
        })
    }

    /// Opens a `CONNECT` tunnel through this proxy to `host:port`, with
    /// every read and write bounded by the deadline.
    pub fn tunnel(
        &self,
        host: &str,
        port: u16,
        deadline: &Deadline,
    ) -> Result<BoundedStream, NetError> {
        let addrs = resolve_system(&self.host, self.port, deadline)?;
        let sock =
            connect_any(&addrs, deadline).map_err(|e| NetError::Proxy(format!("proxy: {e}")))?;
        let mut sock = BoundedStream::new(sock, *deadline);
        sock.write_all(self.connect_request(host, port).as_bytes())
            .map_err(|_| NetError::Proxy("proxy: write failed".to_string()))?;
        let reply = read_reply_head(&mut sock)?;
        let accepted = reply.starts_with(b"HTTP/1.") && reply.get(8..10) == Some(&b" 2"[..]);
        if !accepted {
            return Err(NetError::Proxy(
                "proxy refused the resolver connection".to_string(),
            ));
        }
        Ok(sock)
    }

    fn connect_request(&self, host: &str, port: u16) -> String {
        let target = format_authority(host, port, None);
        let mut request = format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n");
        if let Some(credentials) = &self.credentials {
            let token = Base64::encode_string(credentials.as_bytes());
            request.push_str(&format!("Proxy-Authorization: Basic {token}\r\n"));
        }
        request.push_str("\r\n");
        request
    }
}

/// Reads the proxy's reply head byte by byte, so no byte of the TLS stream
/// that follows is consumed.
fn read_reply_head(sock: &mut BoundedStream) -> Result<Vec<u8>, NetError> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if head.len() > MAX_HEADER {
            return Err(NetError::Proxy("proxy: reply too long".to_string()));
        }
        match sock.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            _ => return Err(NetError::Proxy("proxy: no reply to CONNECT".to_string())),
        }
    }
    Ok(head)
}

/// The proxy configured for an HTTPS request to `host`, like curl:
/// https_proxy, HTTPS_PROXY, all_proxy or ALL_PROXY, unless no_proxy (or
/// NO_PROXY) lists the host.
pub fn proxy_for(host: &str) -> Result<Option<Proxy>, NetError> {
    let Some(url) = first_setting(&["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"])?
    else {
        return Ok(None);
    };
    if first_setting(&["no_proxy", "NO_PROXY"])?.is_some_and(|list| no_proxy_matches(&list, host)) {
        return Ok(None);
    }
    Proxy::parse(&url).map(Some)
}

/// The first of `names` that is set and nonempty. A value that is not
/// UTF-8 is an error, never skipped.
fn first_setting(names: &[&str]) -> Result<Option<String>, NetError> {
    for name in names {
        if let Some(value) = text_var(name).map_err(NetError::Proxy)? {
            return Ok(Some(value));
        }
    }
    Ok(None)
}

/// Whether a no_proxy list covers `host`: `*`, the host itself, or a
/// parent domain (with or without a leading dot).
pub fn no_proxy_matches(list: &str, host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    list.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .any(|entry| {
            if entry == "*" {
                return true;
            }
            let domain = entry
                .trim_start_matches('.')
                .trim_end_matches('.')
                .to_ascii_lowercase();
            host == domain || host.ends_with(&format!(".{domain}"))
        })
}

/// `%XX` escapes decoded; `None` for a bad escape or a non-UTF-8 result.
fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_urls_follow_curl() {
        assert_eq!(
            Proxy::parse("http://u%40x:p%3A@proxy.test:3128/"),
            Ok(Proxy {
                host: "proxy.test".into(),
                port: 3128,
                credentials: Some("u@x:p:".into())
            })
        );
        assert_eq!(
            Proxy::parse("10.0.0.1"),
            Ok(Proxy {
                host: "10.0.0.1".into(),
                port: 1080,
                credentials: None
            })
        );
        for bad in [
            "socks5://proxy:1080",
            "https://proxy:443",
            "http://u%zz@p",
            "http://",
        ] {
            assert!(Proxy::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn connect_requests_name_the_target_and_credentials() {
        let proxy = Proxy::parse("http://u:p@proxy.test:3128").expect("proxy");
        assert_eq!(
            proxy.connect_request("::1", 443),
            "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:443\r\n\
             Proxy-Authorization: Basic dTpw\r\n\r\n"
        );
    }

    #[test]
    fn no_proxy_lists_match_whole_domains() {
        assert!(no_proxy_matches("*", "anything"));
        assert!(!no_proxy_matches(
            "example.com, .dns.test",
            "cloudflare-dns.test"
        ));
        assert!(no_proxy_matches("example.com,.dns.test", "a.dns.test"));
        assert!(no_proxy_matches("dns.test", "dns.test."));
        assert!(!no_proxy_matches("ns.test", "dns.test"));
    }
}
