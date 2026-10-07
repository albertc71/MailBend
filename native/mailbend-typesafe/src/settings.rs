//! The settings and inputs of one run, read and checked before anything
//! connects: the key from MAILBEND_TYPESAFE_KEY_FILE, the request on stdin,
//! the time budget and the route to TypeSafe.

use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::time::Duration;

use mailbend_io::env::timeout;
use mailbend_io::secret::read_secret_file;
use mailbend_net::doh::Resolver;
use mailbend_net::proxy::{Proxy, proxy_for};
use mailbend_net::tls::ca_file_setting;
use zeroize::Zeroizing;

use crate::exit::Exit;

/// TypeSafe's fixed endpoint: no setting changes it.
pub const HOST: &str = "api.typesafe.ai";
pub const PORT: u16 = 443;
pub const PATH: &str = "/v1/systemone";

/// The setting naming the key file, kept through the re-execution.
pub const KEY_FILE: &str = "MAILBEND_TYPESAFE_KEY_FILE";

/// The shortest key accepted: redacting a shorter one from answers could
/// also hide ordinary text.
const MIN_KEY: usize = 8;
/// The core's requests stay far below this (TypeSafe takes at most 64k
/// tokens); larger input is refused before connecting.
const MAX_REQUEST: usize = 1024 * 1024;

#[derive(Debug)]
pub struct Settings {
    /// MAILBEND_TIMEOUT_MS: the budget of each attempt, from connecting to
    /// the end of the answer.
    pub timeout: Duration,
    /// MAILBEND_CA_FILE: trust only these certificates.
    pub ca_file: Option<PathBuf>,
    /// https_proxy and the like: reach TypeSafe through this proxy, which
    /// then resolves its name.
    pub proxy: Option<Proxy>,
    /// MAILBEND_DOH_URL: resolve TypeSafe's name through this resolver.
    pub doh: Option<Resolver>,
}

impl Settings {
    pub fn from_env() -> Result<Settings, Exit> {
        Ok(Settings {
            timeout: timeout().map_err(Exit::input)?,
            ca_file: ca_file_setting(),
            proxy: proxy_for(HOST).map_err(|e| Exit::input(e.to_string()))?,
            doh: Resolver::from_setting().map_err(Exit::input)?,
        })
    }
}

/// The key from MAILBEND_TYPESAFE_KEY_FILE (the same file rules as the
/// mail password file), kept in a buffer wiped on drop.
pub fn read_key() -> Result<Zeroizing<Vec<u8>>, Exit> {
    let path = std::env::var_os(KEY_FILE)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| Exit::input(format!("{KEY_FILE} is not set")))?;
    let key = read_secret_file(path.as_bytes(), KEY_FILE).map_err(Exit::input)?;
    if key.len() < MIN_KEY || !is_bearer_token(&key) {
        return Err(Exit::input(format!(
            "the key in {KEY_FILE} must be one line of at least {MIN_KEY} characters: \
             letters, digits and . _ ~ + / -, then optional = padding"
        )));
    }
    Ok(key)
}

/// Whether `key` is an RFC 6750 b64token, the Bearer grammar. It holds no
/// quote or backslash, so JSON encoders write it as it is, or with `\/` for
/// each `/`.
fn is_bearer_token(key: &[u8]) -> bool {
    let token = |b: &u8| b.is_ascii_alphanumeric() || b"._~+/-".contains(b);
    let body = key.iter().position(|b| !token(b)).unwrap_or(key.len());
    body > 0 && key[body..].iter().all(|&b| b == b'=')
}

/// The JSON request on stdin: UTF-8, nonempty and within the input limit.
/// Its content is the core's; the helper only carries it.
pub fn read_request() -> Result<Vec<u8>, Exit> {
    let mut request = Vec::new();
    std::io::stdin()
        .take(MAX_REQUEST as u64 + 1)
        .read_to_end(&mut request)
        .map_err(|_| Exit::input("cannot read the request"))?;
    if request.len() > MAX_REQUEST {
        return Err(Exit::input("the request exceeds the input limit"));
    }
    if request.is_empty() || std::str::from_utf8(&request).is_err() {
        return Err(Exit::input("the request must be nonempty UTF-8 JSON"));
    }
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_follow_the_bearer_token_grammar() {
        for good in [
            &b"ts_live_abc123"[..],
            b"a.b_c~d+e/f-g",
            b"abcdefgh==",
            b"YWJj/ZGVm+Z2hp=",
        ] {
            assert!(is_bearer_token(good), "{}", String::from_utf8_lossy(good));
        }
        for bad in [
            &b""[..],
            b"========",
            b"ts_te\"st_key",
            b"ts_te\\st_key",
            b"ts key with spaces",
            b"abc=def",
            b"abc,def",
            b"caf\xc3\xa9_key",
        ] {
            assert!(!is_bearer_token(bad), "{}", String::from_utf8_lossy(bad));
        }
    }
}
