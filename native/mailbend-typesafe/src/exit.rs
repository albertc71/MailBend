//! The helper's exit statuses, part of its contract with the Bend core:
//! 0 answered (2xx), 2 key file, input or setting problem, 3 cannot reach
//! TypeSafe (connect, proxy or TLS), 6 unexpected answer, 7 key rejected,
//! 8 request refused, 9 overloaded or timed out after the retries.

/// Why the helper stopped without an answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Failure {
    Input = 2,
    Connect = 3,
    Unexpected = 6,
    KeyRejected = 7,
    Refused = 8,
    Unavailable = 9,
}

/// A failure and the reason printed on stderr. The reason never holds the
/// key: no message is ever formatted from it.
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

    pub fn input(message: impl Into<String>) -> Self {
        Exit::new(Failure::Input, message)
    }

    pub fn code(&self) -> u8 {
        self.failure as u8
    }
}
