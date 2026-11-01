//! The one place a TLS client configuration is built. Certificate chain and
//! host name verification are always on: there is no setting that turns
//! them off. Trust overrides only replace the trusted certificates.

use std::io::{self, Read, Write};
use std::net::{IpAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};

use crate::NetError;

/// A verified TLS stream, by default over a mail socket.
pub type TlsStream<S = TcpStream> = StreamOwned<ClientConnection, S>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrustSource {
    System,
    SslCertEnv,
    MailbendCaFile,
}

impl TrustSource {
    pub fn token(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::SslCertEnv => "ssl_cert_env",
            Self::MailbendCaFile => "mailbend_ca_file",
        }
    }
}

/// TLS 1.3 and 1.2 with the ring provider and the effective trust source.
/// `ca_file` takes precedence over native certificate environment settings.
pub fn client_config(ca_file: Option<&Path>) -> Result<(Arc<ClientConfig>, TrustSource), NetError> {
    let (roots, source) = match ca_file {
        Some(path) => (roots_from_file(path)?, TrustSource::MailbendCaFile),
        None => (system_roots(), native_trust_source()),
    };
    if roots.is_empty() {
        return Err(trust_store_error());
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])
        .map_err(|_| NetError::Tls("cannot create a TLS context".to_string()))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok((Arc::new(config), source))
}

/// MAILBEND_CA_FILE, if set and nonempty: the only certificates to trust
/// (for the local test servers).
pub fn ca_file_setting() -> Option<PathBuf> {
    std::env::var_os("MAILBEND_CA_FILE")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
}

fn trust_store_error() -> NetError {
    NetError::Tls("cannot load the trust store".to_string())
}

/// Every certificate in a PEM file; one unusable entry fails the whole file.
fn roots_from_file(path: &Path) -> Result<RootCertStore, NetError> {
    let mut roots = RootCertStore::empty();
    for cert in CertificateDer::pem_file_iter(path).map_err(|_| trust_store_error())? {
        let cert = cert.map_err(|_| trust_store_error())?;
        roots.add(cert).map_err(|_| trust_store_error())?;
    }
    Ok(roots)
}

fn native_trust_source() -> TrustSource {
    // rustls-native-certs ignores empty directory entries, but not an empty file value.
    let has_dirs = std::env::var_os("SSL_CERT_DIR")
        .is_some_and(|dirs| std::env::split_paths(&dirs).any(|path| !path.as_os_str().is_empty()));
    if std::env::var_os("SSL_CERT_FILE").is_some() || has_dirs {
        TrustSource::SslCertEnv
    } else {
        TrustSource::System
    }
}

/// Native trust honors SSL_CERT_FILE and SSL_CERT_DIR instead of platform
/// roots when configured. Unusable certificate entries are skipped.
fn system_roots() -> RootCertStore {
    let mut roots = RootCertStore::empty();
    for cert in rustls_native_certs::load_native_certs().certs {
        let _skipped = roots.add(cert);
    }
    roots
}

/// The identity to verify: an IP literal is checked against the
/// certificate's IP addresses and sent without SNI; anything else must be a
/// DNS name, which is verified and sent as SNI.
pub fn server_name(host: &str) -> Result<ServerName<'static>, NetError> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(ServerName::IpAddress(ip.into()));
    }
    ServerName::try_from(host.to_string())
        .map_err(|_| NetError::Tls("invalid host name".to_string()))
}

/// Runs the handshake for `host` on `sock` to completion and returns the
/// verified stream. The socket's own timeouts bound the handshake (a
/// `BoundedStream` bounds it by a deadline).
pub fn connect<S: Read + Write>(
    config: &Arc<ClientConfig>,
    host: &str,
    mut sock: S,
) -> Result<TlsStream<S>, NetError> {
    let name = server_name(host)?;
    let mut conn = ClientConnection::new(Arc::clone(config), name)
        .map_err(|_| NetError::Tls("cannot create a TLS session".to_string()))?;
    while conn.is_handshaking() {
        conn.complete_io(&mut sock)
            .map_err(|e| handshake_error(&e))?;
    }
    // The verifier already refused anything unverified; check again.
    if conn.peer_certificates().is_none_or(<[_]>::is_empty) {
        return Err(NetError::Tls(
            "TLS verification failed: no verified peer certificate".to_string(),
        ));
    }
    Ok(StreamOwned::new(conn, sock))
}

/// Why the handshake failed, with the rustls or I/O reason: the handshake
/// comes before any credential is sent, so neither can hold one.
fn handshake_error(e: &io::Error) -> NetError {
    if matches!(
        e.kind(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    ) {
        return NetError::TimedOut;
    }
    let rustls_error = e
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<rustls::Error>());
    match rustls_error {
        Some(
            err @ (rustls::Error::InvalidCertificate(_)
            | rustls::Error::NoCertificatesPresented
            | rustls::Error::InvalidCertRevocationList(_)),
        ) => NetError::Tls(format!("TLS verification failed: {err}")),
        Some(err) => NetError::Tls(format!("TLS handshake failed: {err}")),
        None => NetError::Tls(format!("TLS handshake failed: {}", e.kind())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ip_literals_are_ip_identities() {
        assert!(matches!(
            server_name("127.0.0.1"),
            Ok(ServerName::IpAddress(_))
        ));
        assert!(matches!(server_name("::1"), Ok(ServerName::IpAddress(_))));
        assert!(matches!(
            server_name("imap.mail.me.com"),
            Ok(ServerName::DnsName(_))
        ));
        assert!(server_name("bad host").is_err());
        assert!(server_name("").is_err());
    }

    #[test]
    fn handshake_errors_keep_their_reason() {
        let alert = io::Error::other(rustls::Error::AlertReceived(
            rustls::AlertDescription::HandshakeFailure,
        ));
        assert!(matches!(
            handshake_error(&alert),
            NetError::Tls(message) if message.starts_with("TLS handshake failed: received fatal alert")
        ));
        let reset = io::Error::from(io::ErrorKind::ConnectionReset);
        assert_eq!(
            handshake_error(&reset),
            NetError::Tls("TLS handshake failed: connection reset".into())
        );
        let late = io::Error::from(io::ErrorKind::WouldBlock);
        assert_eq!(handshake_error(&late), NetError::TimedOut);
    }

    #[test]
    fn a_missing_ca_file_fails_to_load() {
        let missing = Path::new("/nonexistent/mailbend-ca.pem");
        assert_eq!(
            client_config(Some(missing)).map(|_| ()),
            Err(trust_store_error())
        );
    }
}
