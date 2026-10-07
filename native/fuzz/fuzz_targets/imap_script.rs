#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|script: &[u8]| {
    let _ = mailbend_tls::imap::script::parse(script);
});
