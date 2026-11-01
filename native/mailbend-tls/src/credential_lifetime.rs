use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ServerConfig, ServerConnection, StreamOwned};
use zeroize::Zeroizing;

use crate::connection::Connection;
use crate::creds::{Credentials, DropWitness};
use crate::settings::SmtpTlsMode;
use crate::{imap, smtp};

struct Certificates(PathBuf);

impl Certificates {
    fn new(name: &str) -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let dir = std::env::temp_dir().join(format!(
            "mailbend-credentials-{name}-{}",
            std::process::id()
        ));
        let result = Command::new("sh")
            .arg(root.join("tests/gen-test-certs.sh"))
            .arg(&dir)
            .output()
            .expect("generate test certificates");
        assert!(result.status.success(), "{result:?}");
        Self(dir)
    }

    fn der(&self, args: &[&str], file: &str) -> Vec<u8> {
        let result = Command::new("openssl")
            .args(args)
            .arg("-in")
            .arg(self.0.join(file))
            .output()
            .expect("convert test certificate");
        assert!(result.status.success(), "{result:?}");
        result.stdout
    }

    fn server(&self) -> Arc<ServerConfig> {
        let cert = self.der(&["x509", "-outform", "DER"], "server.pem");
        let key = self.der(
            &["pkcs8", "-topk8", "-nocrypt", "-outform", "DER"],
            "server-key.pem",
        );
        Arc::new(
            ServerConfig::builder()
                .with_no_client_auth()
                .with_single_cert(
                    vec![CertificateDer::from(cert)],
                    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key)),
                )
                .expect("server TLS"),
        )
    }
}

impl Drop for Certificates {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove test certificates");
    }
}

type Peer = BufReader<StreamOwned<ServerConnection, TcpStream>>;

fn send(peer: &mut Peer, reply: &[u8]) {
    peer.get_mut().write_all(reply).expect("server reply");
    peer.get_mut().flush().expect("flush reply");
}

fn line(peer: &mut Peer) -> String {
    let mut line = String::new();
    assert_ne!(peer.read_line(&mut line).expect("client command"), 0);
    line
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Authentication {
    ImapLogin,
    ImapPreauth,
    SmtpPlain,
    SmtpLogin,
}

fn session(certs: &Certificates, authentication: Authentication, reject: bool) {
    let smtp = matches!(
        authentication,
        Authentication::SmtpPlain | Authentication::SmtpLogin
    );
    let preauth = authentication == Authentication::ImapPreauth;
    let login_auth = authentication == Authentication::SmtpLogin;
    let server_config = certs.server();
    let client_config =
        mailbend_net::tls::client_config(Some(&certs.0.join("ca.pem"))).expect("client trust");
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("address");
    let dropped = Arc::new(AtomicBool::new(false));
    let server_dropped = Arc::clone(&dropped);
    let server = std::thread::spawn(move || {
        let (socket, _) = listener.accept().expect("accept");
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let tls = ServerConnection::new(server_config).expect("TLS server");
        let mut peer = BufReader::new(StreamOwned::new(tls, socket));
        if smtp {
            send(&mut peer, b"220 ready\r\n");
            assert!(line(&mut peer).starts_with("EHLO "));
            send(
                &mut peer,
                if login_auth {
                    b"250 AUTH LOGIN\r\n"
                } else {
                    b"250 AUTH PLAIN\r\n"
                },
            );
            assert!(line(&mut peer).starts_with("AUTH "));
            if login_auth {
                send(&mut peer, b"334 user\r\n");
                let _ = line(&mut peer);
                send(&mut peer, b"334 password\r\n");
                let _ = line(&mut peer);
            }
        } else {
            send(
                &mut peer,
                if preauth {
                    b"* PREAUTH ready\r\n"
                } else {
                    b"* OK ready\r\n"
                },
            );
            if !preauth {
                assert!(line(&mut peer).starts_with("L LOGIN "));
            }
        }
        if !preauth {
            assert!(!server_dropped.load(Ordering::SeqCst));
            send(
                &mut peer,
                match (smtp, reject) {
                    (true, true) => b"535 refused\r\n",
                    (true, false) => b"235 authenticated\r\n",
                    (false, true) => b"L NO refused\r\n",
                    (false, false) => b"L OK authenticated\r\n",
                },
            );
        }
        if reject {
            return;
        }
        assert_eq!(
            line(&mut peer),
            if smtp {
                "MAIL FROM:<user@example.com>\r\n"
            } else {
                "a1 NOOP\r\n"
            }
        );
        assert!(
            server_dropped.load(Ordering::SeqCst),
            "credential buffers outlived authentication"
        );
        send(
            &mut peer,
            if smtp {
                b"250 accepted\r\n"
            } else {
                b"a1 OK accepted\r\n"
            },
        );
        assert_eq!(
            line(&mut peer),
            if smtp { "QUIT\r\n" } else { "Z LOGOUT\r\n" }
        );
        send(
            &mut peer,
            if smtp {
                b"221 bye\r\n"
            } else {
                b"Z OK bye\r\n"
            },
        );
    });
    let creds = Credentials {
        user: Zeroizing::new(b"user@example.com".to_vec()),
        pass: Zeroizing::new(b"fixture-password".to_vec()),
        _drop_witness: Some(DropWitness(Arc::clone(&dropped))),
    };
    let socket = TcpStream::connect(address).expect("connect");
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    socket
        .set_write_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    let mut conn = Connection::new(socket);
    let result = if smtp {
        smtp::session::run(
            &mut conn,
            &client_config,
            "localhost",
            SmtpTlsMode::Implicit,
            creds,
            &[smtp::envelope::Step::Command(
                b"MAIL FROM:<user@example.com>\r\n",
            )],
        )
    } else {
        imap::session::run(
            &mut conn,
            &client_config,
            "localhost",
            creds,
            &imap::script::parse(b"a1 NOOP\r\n").expect("plan"),
        )
    };
    assert_eq!(result.is_err(), reject, "{result:?}");
    assert!(dropped.load(Ordering::SeqCst));
    drop(conn);
    server.join().expect("server checks");
}

#[test]
fn imap_drops_credentials_before_commands() {
    let certs = Certificates::new("imap");
    session(&certs, Authentication::ImapLogin, false);
    session(&certs, Authentication::ImapPreauth, false);
    session(&certs, Authentication::ImapLogin, true);
}

#[test]
fn smtp_drops_credentials_before_commands() {
    let certs = Certificates::new("smtp");
    session(&certs, Authentication::SmtpPlain, false);
    session(&certs, Authentication::SmtpLogin, false);
    session(&certs, Authentication::SmtpPlain, true);
}
