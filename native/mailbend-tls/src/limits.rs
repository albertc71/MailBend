//! Size limits on everything the helper reads or writes.

/// One server response line (a big SEARCH reply).
pub const MAX_LINE: usize = 32 << 20;
/// One IMAP literal.
pub const MAX_LITERAL: u64 = 64 << 20;
/// The whole command script or envelope on stdin.
pub const MAX_SCRIPT: usize = 64 << 20;
/// Transcript bytes; at most doubled on stdout by the encoding.
pub const MAX_OUTPUT: u64 = 60 << 20;
