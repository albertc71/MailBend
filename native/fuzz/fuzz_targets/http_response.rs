#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|buf: &[u8]| {
    let _ = mailbend_net::http::parse_response(buf, false);
    let _ = mailbend_net::http::parse_response(buf, true);
});
