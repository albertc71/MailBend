#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|reply: &[u8]| {
    use mailbend_tls::smtp::reply;
    let _ = reply::parse_line(reply);
    let _ = reply::has_extension(reply, b"STARTTLS");
    let _ = reply::has_auth(reply, b"PLAIN");
});
