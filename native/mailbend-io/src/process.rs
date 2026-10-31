//! Process-local protection for helpers that read secrets.

use nix::sys::prctl::set_dumpable;
use nix::sys::resource::{Resource, setrlimit};

/// Refuse file core dumps and piped crash collectors before reading secrets.
/// Reapply after exec, which resets dumpability.
pub fn no_dumps() -> Result<(), String> {
    setrlimit(Resource::RLIMIT_CORE, 0, 0).map_err(|_| "cannot disable core files".to_string())?;
    set_dumpable(false).map_err(|_| "cannot disable process dumps".to_string())
}
