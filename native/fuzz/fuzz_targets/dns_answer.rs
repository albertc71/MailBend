#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|msg: &[u8]| {
    use mailbend_net::dns::{RecordType, parse_answer};
    let _ = parse_answer(msg, RecordType::A);
    let _ = parse_answer(msg, RecordType::Aaaa);
});
