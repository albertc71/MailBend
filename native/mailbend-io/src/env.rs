//! Reading text settings from the environment.

use std::ffi::OsString;

/// The value of `name` if it is set and nonempty. A value that is not UTF-8
/// is an error (with a message naming the variable), never treated as
/// unset.
pub fn text_var(name: &str) -> Result<Option<String>, String> {
    match std::env::var_os(name).map(OsString::into_string) {
        None => Ok(None),
        Some(Ok(value)) => Ok(Some(value).filter(|v| !v.is_empty())),
        Some(Err(_)) => Err(format!("{name} is not valid UTF-8")),
    }
}
