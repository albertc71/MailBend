//! The byte encoding of everything the helpers write to stdout for the Bend
//! core.

/// Appends `bytes` to `out`, each byte 0x80-0xFF as the UTF-8 encoding of
/// U+0080-U+00FF, so the Bend core reads exactly one character per byte and
/// IMAP literal lengths stay exact.
pub fn encode_bytes(bytes: &[u8], out: &mut Vec<u8>) {
    for &c in bytes {
        if c < 0x80 {
            out.push(c);
        } else {
            out.push(0xC0 | (c >> 6));
            out.push(0x80 | (c & 0x3F));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn high_bytes_become_two_byte_utf8() {
        let mut out = Vec::new();
        encode_bytes(&[0x41, 0x7F, 0x80, 0xE9, 0xFF], &mut out);
        assert_eq!(out, [0x41, 0x7F, 0xC2, 0x80, 0xC3, 0xA9, 0xC3, 0xBF]);
    }

    #[test]
    fn every_byte_decodes_to_its_own_code_point() {
        let all: Vec<u8> = (0..=255).collect();
        let mut out = Vec::new();
        encode_bytes(&all, &mut out);
        let decoded: Vec<u32> = String::from_utf8(out)
            .expect("valid UTF-8")
            .chars()
            .map(u32::from)
            .collect();
        assert_eq!(decoded, (0..=255).collect::<Vec<u32>>());
    }
}
