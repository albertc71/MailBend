//! The small part of URL syntax the resolver and proxy settings need:
//! `host[:port]` authorities (IPv6 in brackets) and HTTPS resolver URLs.

use std::net::Ipv6Addr;

/// A parsed `https://host[:port][/path]` resolver URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DohUrl {
    pub host: String,
    pub port: u16,
    pub path: String,
}

impl DohUrl {
    /// Parses an HTTPS resolver URL; anything else (another scheme, user
    /// information, an empty host, a bad port or a fragment-only path) is
    /// `None`.
    pub fn parse(url: &str) -> Option<DohUrl> {
        let rest = url.strip_prefix("https://")?;
        let split = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let (authority, path) = rest.split_at(split);
        if path.starts_with('#') {
            return None;
        }
        let path = match path {
            "" => "/".to_string(),
            query if query.starts_with('?') => format!("/{query}"),
            path => path.split('#').next().unwrap_or(path).to_string(),
        };
        if path.bytes().any(is_control_or_space) {
            return None;
        }
        let (host, port) = parse_authority(authority, 443)?;
        Some(DohUrl { host, port, path })
    }
}

fn is_control_or_space(b: u8) -> bool {
    b <= b' ' || b == 0x7F
}

/// Parses `host[:port]` or `[v6][:port]` (no user information), using
/// `default_port` when none is given. Port 0 is refused.
pub fn parse_authority(authority: &str, default_port: u16) -> Option<(String, u16)> {
    if authority.contains('@') {
        return None;
    }
    let (host, port) = if let Some(bracketed) = authority.strip_prefix('[') {
        let (host, after) = bracketed.split_once(']')?;
        host.parse::<Ipv6Addr>().ok()?;
        match after {
            "" => (host, None),
            port => (host, Some(port.strip_prefix(':')?)),
        }
    } else {
        let (host, port) = match authority.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        };
        // An IPv6 address must be in brackets.
        if host.contains(':') {
            return None;
        }
        (host, port)
    };
    if host.is_empty() || host.bytes().any(|b| is_control_or_space(b) || b == b'/') {
        return None;
    }
    let port = match port {
        None => default_port,
        Some(digits) => parse_port(digits)?,
    };
    Some((host.to_string(), port))
}

/// A decimal port from 1 to 65535, digits only.
pub fn parse_port(digits: &str) -> Option<u16> {
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse::<u16>().ok().filter(|&p| p != 0)
}

/// `host:port` as written in an authority (IPv6 in brackets), leaving out
/// the port when it equals `implied_port`: the form of an HTTP `Host`
/// header and a `CONNECT` target.
pub fn format_authority(host: &str, port: u16, implied_port: Option<u16>) -> String {
    let host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    if implied_port == Some(port) {
        host
    } else {
        format!("{host}:{port}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolver_urls_must_be_https() {
        assert_eq!(
            DohUrl::parse("https://cloudflare-dns.com/dns-query"),
            Some(DohUrl {
                host: "cloudflare-dns.com".into(),
                port: 443,
                path: "/dns-query".into()
            })
        );
        let url = DohUrl::parse("https://[::1]:8443").expect("url");
        assert_eq!(
            (url.host.as_str(), url.port, url.path.as_str()),
            ("::1", 8443, "/")
        );
        assert_eq!(
            DohUrl::parse("https://dns.test?dns").map(|u| u.path),
            Some("/?dns".to_string())
        );
        for bad in [
            "http://localhost/dns-query",
            "https://",
            "https://u:p@host/",
            "https://host:0/",
            "https://host:99999/",
            "https://host:x/",
            "https://[nope]/",
            "https://ho st/",
            "https://host#frag",
            "https://::1/x",
        ] {
            assert_eq!(DohUrl::parse(bad), None, "{bad}");
        }
    }

    #[test]
    fn ports_are_plain_decimal_and_nonzero() {
        assert_eq!(parse_port("993"), Some(993));
        for bad in ["0", "", "+993", " 993", "65536", "99x"] {
            assert_eq!(parse_port(bad), None, "{bad}");
        }
    }

    #[test]
    fn authorities_bracket_ipv6_and_imply_default_ports() {
        assert_eq!(format_authority("dns.test", 443, Some(443)), "dns.test");
        assert_eq!(
            format_authority("dns.test", 8443, Some(443)),
            "dns.test:8443"
        );
        assert_eq!(format_authority("::1", 443, Some(443)), "[::1]");
        assert_eq!(format_authority("::1", 443, None), "[::1]:443");
    }
}
