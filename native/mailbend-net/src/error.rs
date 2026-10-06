//! Why a lookup, connection or handshake failed. Every message is safe to
//! print: none carries credentials or mail content.

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NetError {
    /// The shared deadline passed.
    TimedOut,
    /// A name could not be resolved, by system DNS or the DoH resolver.
    Dns(String),
    /// No address accepted a TCP connection.
    Connect(String),
    /// The DoH exchange failed: the request, or the resolver's HTTP response.
    Doh(String),
    /// An HTTP response was missing, malformed or too long.
    Http(String),
    /// The proxy setting is unusable or the proxy refused the tunnel.
    Proxy(String),
    /// The trust store, the TLS session or the handshake failed.
    Tls(String),
}

impl fmt::Display for NetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NetError::TimedOut => f.write_str("timed out"),
            NetError::Dns(message)
            | NetError::Connect(message)
            | NetError::Doh(message)
            | NetError::Http(message)
            | NetError::Proxy(message)
            | NetError::Tls(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for NetError {}
