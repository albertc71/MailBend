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

/// Allow-listed refusal evidence, never a server-supplied explanation.
/// Bend decides the guidance; this does not change the exit status or retry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthReason {
    Credentials,
    Temporary,
    Limit,
    InUse,
    Expired,
    ContactAdmin,
    GreetingRefused,
    Unknown,
}

impl AuthReason {
    pub fn token(self) -> &'static str {
        match self {
            Self::Credentials => "credentials",
            Self::Temporary => "temporary",
            Self::Limit => "limit",
            Self::InUse => "in_use",
            Self::Expired => "expired",
            Self::ContactAdmin => "contact_admin",
            Self::GreetingRefused => "greeting_refused",
            Self::Unknown => "unknown",
        }
    }

    pub(crate) fn smtp(code: u16) -> Self {
        match code {
            432 => Self::Unknown,
            400..=499 => Self::Temporary,
            535 => Self::Credentials,
            _ => Self::Unknown,
        }
    }
}

/// A failure and the reason printed on stderr. The reason never holds
/// credentials.
#[derive(Debug, PartialEq, Eq)]
pub struct Exit {
    pub failure: Failure,
    pub message: String,
    pub auth_reason: Option<AuthReason>,
}

impl Exit {
    pub fn new(failure: Failure, message: impl Into<String>) -> Self {
        Exit {
            failure,
            message: message.into(),
            auth_reason: None,
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

    pub fn with_auth_reason(mut self, reason: AuthReason) -> Self {
        self.auth_reason = Some(reason);
        self
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

#[cfg(test)]
mod tests {
    use super::AuthReason;

    #[test]
    fn smtp_refusal_reasons_preserve_exceptions_and_range_boundaries() {
        for (code, expected) in [
            (399, AuthReason::Unknown),
            (400, AuthReason::Temporary),
            (421, AuthReason::Temporary),
            (431, AuthReason::Temporary),
            (432, AuthReason::Unknown),
            (433, AuthReason::Temporary),
            (454, AuthReason::Temporary),
            (499, AuthReason::Temporary),
            (500, AuthReason::Unknown),
            (534, AuthReason::Unknown),
            (535, AuthReason::Credentials),
            (536, AuthReason::Unknown),
        ] {
            assert_eq!(AuthReason::smtp(code), expected, "SMTP reply {code}");
        }
    }
}
