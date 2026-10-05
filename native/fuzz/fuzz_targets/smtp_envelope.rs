#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|envelope: &[u8]| {
    let _ = mailbend_tls::smtp::envelope::parse(envelope);
});
