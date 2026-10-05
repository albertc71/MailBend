#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|bytes: &[u8]| {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return;
    };
    let _ = mailbend_net::url::DohUrl::parse(text);
    let _ = mailbend_net::proxy::Proxy::parse(text);
    if let Some((list, host)) = text.split_once('\n') {
        let _ = mailbend_net::proxy::no_proxy_matches(list, host);
    }
});
