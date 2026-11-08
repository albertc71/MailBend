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
    let (client_config, _) =
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

#[test]
fn buffered_verified_tls_lines_and_literals_respect_login_deadlines() {
    let certs = Certificates::new("buffered-login-deadline");
    for literal in [false, true] {
        let config = certs.server();
        let (client_config, _) =
            mailbend_net::tls::client_config(Some(&certs.0.join("ca.pem"))).expect("trust");
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        let server = std::thread::spawn(move || {
            let (socket, _) = listener.accept().expect("accept");
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .expect("timeout");
            socket
                .set_write_timeout(Some(Duration::from_secs(5)))
                .expect("timeout");
            let tls = ServerConnection::new(config).expect("server TLS");
            let mut peer = BufReader::new(StreamOwned::new(tls, socket));
            send(&mut peer, b"first\r\nsecond\r\n");
        });
        let socket = TcpStream::connect(address).expect("connect");
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let observer = socket.try_clone().expect("socket options");
        let mut conn = Connection::new(socket);
        conn.start_tls(&client_config, "localhost")
            .expect("verified TLS");
        observer
            .set_read_timeout(Some(Duration::from_millis(300)))
            .expect("timeout");
        observer
            .set_write_timeout(Some(Duration::from_millis(300)))
            .expect("timeout");
        assert_eq!(
            conn.read_line().expect("first line"),
            Some(b"first\r\n".to_vec())
        );
        conn.begin_login_continuation().expect("bounded");
        std::thread::sleep(Duration::from_millis(350));
        let result = if literal {
            conn.pass_bytes(6)
        } else {
            conn.read_line().map(|_| ())
        };
        assert_eq!(
            result,
            Err(crate::Exit::protocol("read from server timed out"))
        );
        drop(conn);
        server.join().expect("server");
    }
}

#[test]
fn verified_tls_login_restores_the_socket_and_both_original_timeouts() {
    let certs = Certificates::new("restored-login-deadline");
    let config = certs.server();
    let (client_config, _) =
        mailbend_net::tls::client_config(Some(&certs.0.join("ca.pem"))).expect("trust");
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("address");
    let server = std::thread::spawn(move || {
        let (socket, _) = listener.accept().expect("accept");
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .expect("timeout");
        let tls = ServerConnection::new(config).expect("server TLS");
        let mut peer = BufReader::new(StreamOwned::new(tls, socket));
        send(&mut peer, b"first\r\n");
        assert_eq!(line(&mut peer), "begin\r\n");
        std::thread::sleep(Duration::from_millis(200));
        send(&mut peer, b"ready\r\n");
        assert_eq!(line(&mut peer), "shrink\r\n");
        assert_eq!(line(&mut peer), "after\r\n");
        std::thread::sleep(Duration::from_millis(200));
        send(&mut peer, b"restored\r\n");
    });
    let socket = TcpStream::connect(address).expect("connect");
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    socket
        .set_write_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    let observer = socket.try_clone().expect("socket options");
    let mut conn = Connection::new(socket);
    conn.start_tls(&client_config, "localhost")
        .expect("verified TLS");
    assert_eq!(
        conn.read_line().expect("first line"),
        Some(b"first\r\n".to_vec())
    );
    observer
        .set_read_timeout(Some(Duration::from_millis(300)))
        .expect("read timeout");
    observer
        .set_write_timeout(Some(Duration::from_millis(700)))
        .expect("write timeout");
    conn.begin_login_continuation().expect("bounded");
    conn.write(b"begin\r\n").expect("begin");
    assert_eq!(
        conn.read_line().expect("ready"),
        Some(b"ready\r\n".to_vec())
    );
    conn.write(b"shrink\r\n").expect("bounded write");
    conn.finish_login_continuation().expect("restored");
    assert_eq!(
        observer.read_timeout().expect("read timeout"),
        Some(Duration::from_millis(300))
    );
    assert_eq!(
        observer.write_timeout().expect("write timeout"),
        Some(Duration::from_millis(700))
    );
    conn.write(b"after\r\n").expect("ordinary write");
    assert_eq!(
        conn.read_line().expect("restored read"),
        Some(b"restored\r\n".to_vec())
    );
    drop(conn);
    server.join().expect("server");
}
