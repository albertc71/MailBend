//! The byte encoding of what the helpers and the Bend core pass each other:
//! the core reads one character per byte from a helper's stdout, and
//! Process.run writes each character of the core's text to a helper's stdin
//! as UTF-8.

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

/// Input that is not bytes in the core's encoding: a character above
/// U+00FF, or bytes that are not UTF-8.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotBytes;

/// Undoes `encode_bytes`: appends the bytes that `input` encodes to `out`
/// and returns how much of `input` it used. A lead byte at the very end,
/// whose continuation has not been read yet, is left unused.
pub fn decode_bytes(input: &[u8], out: &mut Vec<u8>) -> Result<usize, NotBytes> {
    let mut used = 0;
    while let Some(&lead) = input.get(used) {
        match lead {
            0x00..=0x7F => {
                out.push(lead);
                used += 1;
            }
            0xC2 | 0xC3 => {
                let Some(&next) = input.get(used + 1) else {
                    break;
                };
                if next & 0xC0 != 0x80 {
                    return Err(NotBytes);
                }
                out.push(((lead & 0x03) << 6) | (next & 0x3F));
                used += 2;
            }
            _ => return Err(NotBytes),
        }
    }
    Ok(used)
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

    #[test]
    fn decoding_undoes_encoding() {
        let all: Vec<u8> = (0..=255).collect();
        let mut encoded = Vec::new();
        encode_bytes(&all, &mut encoded);
        let mut decoded = Vec::new();
        assert_eq!(decode_bytes(&encoded, &mut decoded), Ok(encoded.len()));
        assert_eq!(decoded, all);
    }

    #[test]
    fn a_final_lead_byte_waits_for_its_continuation() {
        let mut out = Vec::new();
        assert_eq!(decode_bytes(&[0x41, 0xC3], &mut out), Ok(1));
        assert_eq!(out, [0x41]);
        assert_eq!(decode_bytes(&[0xC3, 0xA9], &mut out), Ok(2));
        assert_eq!(out, [0x41, 0xE9]);
    }

    #[test]
    fn other_characters_are_refused() {
        for bad in [
            &[0xC4, 0x80][..],
            &[0xE2, 0x80, 0xAE],
            &[0xC3, 0x41],
            &[0x80],
            &[0xFF],
        ] {
            assert_eq!(decode_bytes(bad, &mut Vec::new()), Err(NotBytes), "{bad:?}");
        }
    }
}
