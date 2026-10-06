//! Local helpers shared by MailBend's native programs: environment
//! settings, no-symlink file opening, stderr reports and the byte encoding
//! the helpers and the core pass each other. Nothing here opens a network
//! connection, so the credential-free `mailbend-attach` can depend on it
//! too.

pub mod env;
pub mod fs;
pub mod report;
pub mod transcript;
