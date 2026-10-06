#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|buf: &[u8]| {
    let _ = mailbend_net::http::read_response(&mut &buf[..], 65535);
});
