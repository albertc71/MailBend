#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|line: &[u8]| {
    use mailbend_tls::imap::response;
    use mailbend_tls::imap::script::Expect;
    let _ = mailbend_tls::imap::literal_len(line);
    let _ = response::greeting(line);
    let _ = response::is_continuation(line);
    let _ = response::tagged_status(line, b"a1");
    let _ = Expect::Prefix(b"* OK [UIDVALIDITY 1]").met_by(line);
    let _ = Expect::Word(b"UIDPLUS").met_by(line);
});
