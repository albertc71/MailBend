//! The helper's exit statuses, part of its contract with the Bend core:
//! 0 ok, 2 usage/config, 3 connect/TLS/verification, 4 authentication
//! rejected, 5 command rejected, 6 protocol/timeout/limit.

use mailbend_net::NetError;

/// How a run that reached the server ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Every command was accepted.
    Completed,
    /// A command was rejected, for the reason given; later commands were
    /// not sent.
    Rejected(String),
}

impl Outcome {
    /// 0, or 5 for a rejection (the other statuses are `Failure`s).
    pub fn code(&self) -> u8 {
        match self {
            Outcome::Completed => 0,
            Outcome::Rejected(_) => 5,
        }
    }
}

/// Why the helper stopped early.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Failure {
    Usage = 2,
    Connect = 3,
    Auth = 4,
    Protocol = 6,
}

/// A failure and the reason printed on stderr. The reason never holds
/// credentials.
#[derive(Debug, PartialEq, Eq)]
pub struct Exit {
    pub failure: Failure,
    pub message: String,
}

impl Exit {
    pub fn new(failure: Failure, message: impl Into<String>) -> Self {
        Exit {
            failure,
            message: message.into(),
        }
    }

    pub fn usage(message: impl Into<String>) -> Self {
        Exit::new(Failure::Usage, message)
    }

    pub fn connect(message: impl Into<String>) -> Self {
        Exit::new(Failure::Connect, message)
    }

    pub fn auth(message: impl Into<String>) -> Self {
        Exit::new(Failure::Auth, message)
    }

    pub fn protocol(message: impl Into<String>) -> Self {
        Exit::new(Failure::Protocol, message)
    }

    pub fn code(&self) -> u8 {
        self.failure as u8
    }
}

/// Resolving, connecting and the TLS handshake all fail with exit 3.
impl From<NetError> for Exit {
    fn from(error: NetError) -> Self {
        Exit::connect(error.to_string())
    }
}
