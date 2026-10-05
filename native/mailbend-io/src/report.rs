//! Reporting to stderr. A closed stderr is ignored: `eprintln!` would panic
//! instead and replace the helper's exit status.

use std::fmt::Display;
use std::io::Write;

/// Writes `program: message` to stderr.
pub fn report(program: &str, message: impl Display) {
    let _ignored = writeln!(std::io::stderr(), "{program}: {message}");
}
