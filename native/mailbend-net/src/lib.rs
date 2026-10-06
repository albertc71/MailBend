//! The network code used by `mailbend-tls`: the one verified TLS
//! configuration, TCP connections under a single deadline, and the
//! DNS-over-HTTPS client with its parsers.

pub mod connect;
pub mod dns;
pub mod doh;
pub mod error;
pub mod http;
pub mod proxy;
pub mod tls;
pub mod url;

pub use error::NetError;
