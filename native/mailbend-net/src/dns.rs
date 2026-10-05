//! DNS wire format for the DoH client: A/AAAA questions and their answers,
//! read with bounded name compression and RCODE 0 required.

use std::net::IpAddr;

use crate::NetError;

const CLASS_IN: u16 = 1;
const HEADER_LEN: usize = 12;
/// Name compression pointers are not followed, so this bounds the labels of
/// one name, not a pointer chain.
const MAX_LABELS: usize = 128;

/// The address records MailBend asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordType {
    A,
    Aaaa,
}

impl RecordType {
    fn code(self) -> u16 {
        match self {
            RecordType::A => 1,
            RecordType::Aaaa => 28,
        }
    }
}

/// A query for `name` (ASCII; IDNs arrive as punycode), ID 0 as RFC 8484
/// recommends, recursion desired.
pub fn build_query(name: &str, record: RecordType) -> Result<Vec<u8>, NetError> {
    let name = name.strip_suffix('.').unwrap_or(name);
    let invalid = || NetError::Dns(format!("cannot look up {name}"));
    if name.is_empty() || name.len() > 253 || !name.is_ascii() {
        return Err(invalid());
    }
    // ID 0, flags RD, one question, no other records.
    let mut query = vec![0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
    for label in name.split('.') {
        let len = u8::try_from(label.len())
            .ok()
            .filter(|n| (1..=63).contains(n))
            .ok_or_else(invalid)?;
        query.push(len);
        query.extend_from_slice(label.as_bytes());
    }
    query.push(0);
    query.extend_from_slice(&record.code().to_be_bytes());
    query.extend_from_slice(&CLASS_IN.to_be_bytes());
    Ok(query)
}

/// The addresses of type `record` in a DNS response. A failed lookup (RCODE
/// other than 0), a query ID other than 0, or a malformed message is an
/// error; CNAME and other records are skipped.
pub fn parse_answer(msg: &[u8], record: RecordType) -> Result<Vec<IpAddr>, NetError> {
    let malformed = || NetError::Dns("malformed DNS answer".to_string());
    let field = |at: usize| read_u16(msg, at).ok_or_else(malformed);
    let (id, flags) = (field(0)?, field(2)?);
    let is_response = flags & 0x8000 != 0;
    if id != 0 || !is_response {
        return Err(malformed());
    }
    match flags & 0x000F {
        0 => {}
        3 => return Err(NetError::Dns("name does not exist (NXDOMAIN)".to_string())),
        rcode => return Err(NetError::Dns(format!("DNS lookup failed (RCODE {rcode})"))),
    }
    let (questions, answers) = (field(4)?, field(6)?);
    let mut at = HEADER_LEN;
    for _ in 0..questions {
        // The name, then QTYPE and QCLASS.
        at = skip_name(msg, at).ok_or_else(malformed)? + 4;
    }
    let mut found = Vec::new();
    for _ in 0..answers {
        // The name, then TYPE, CLASS, TTL (4 bytes), RDLENGTH and RDATA.
        at = skip_name(msg, at).ok_or_else(malformed)?;
        let (rtype, class) = (field(at)?, field(at + 2)?);
        let rdata_len = usize::from(field(at + 8)?);
        let rdata = msg
            .get(at + 10..at + 10 + rdata_len)
            .ok_or_else(malformed)?;
        at += 10 + rdata_len;
        if rtype != record.code() || class != CLASS_IN {
            continue;
        }
        let address = match record {
            RecordType::A => <[u8; 4]>::try_from(rdata).map(IpAddr::from),
            RecordType::Aaaa => <[u8; 16]>::try_from(rdata).map(IpAddr::from),
        };
        found.push(address.map_err(|_| malformed())?);
    }
    if at > msg.len() {
        return Err(malformed());
    }
    Ok(found)
}

fn read_u16(msg: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*msg.get(at)?, *msg.get(at + 1)?]))
}

/// The offset just past the (possibly compressed) name at `at`. A pointer
/// ends the name and is not followed, so no loop is possible.
fn skip_name(msg: &[u8], mut at: usize) -> Option<usize> {
    for _ in 0..MAX_LABELS {
        let len = *msg.get(at)?;
        match len >> 6 {
            0 if len == 0 => return Some(at + 1),
            0 => at += 1 + usize::from(len),
            // A compression pointer: two bytes.
            3 => {
                msg.get(at + 1)?;
                return Some(at + 2);
            }
            _ => return None,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_are_rfc8484_wire_format() {
        let q = build_query("mailbend.test.", RecordType::Aaaa).expect("query");
        assert_eq!(&q[..12], &[0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(&q[12..], b"\x08mailbend\x04test\x00\x00\x1c\x00\x01");
        for bad in ["", "a..b", &"a".repeat(64), "é.test"] {
            assert!(build_query(bad, RecordType::A).is_err(), "{bad}");
        }
    }

    fn answer(rcode: u16, records: &[(u16, &[u8])]) -> Vec<u8> {
        let mut m = build_query("x.test", RecordType::A).expect("query");
        m[2..4].copy_from_slice(&(0x8180 | rcode).to_be_bytes());
        m[6..8].copy_from_slice(&u16::try_from(records.len()).expect("few").to_be_bytes());
        for (rtype, data) in records {
            m.extend_from_slice(b"\xc0\x0c");
            m.extend_from_slice(&rtype.to_be_bytes());
            m.extend_from_slice(&[0, 1, 0, 0, 0, 60]);
            m.extend_from_slice(&u16::try_from(data.len()).expect("short").to_be_bytes());
            m.extend_from_slice(data);
        }
        m
    }

    #[test]
    fn answers_yield_matching_addresses_only() {
        let cname: &[u8] = b"\x01a\x00";
        let msg = answer(0, &[(5, cname), (1, &[127, 0, 0, 1]), (28, &[0; 16])]);
        assert_eq!(
            parse_answer(&msg, RecordType::A),
            Ok(vec![IpAddr::from([127, 0, 0, 1])])
        );
        assert_eq!(
            parse_answer(&msg, RecordType::Aaaa),
            Ok(vec![IpAddr::from([0u8; 16])])
        );
        assert_eq!(parse_answer(&answer(0, &[]), RecordType::A), Ok(vec![]));
    }

    #[test]
    fn failed_or_malformed_answers_are_errors() {
        assert!(parse_answer(&answer(3, &[]), RecordType::A).is_err());
        assert!(parse_answer(&answer(2, &[]), RecordType::A).is_err());
        assert!(parse_answer(b"not a DNS packet", RecordType::A).is_err());
        assert!(parse_answer(&answer(0, &[(1, &[1, 2, 3])]), RecordType::A).is_err());
        let mut truncated = answer(0, &[(1, &[1, 2, 3, 4])]);
        truncated.truncate(truncated.len() - 1);
        assert!(parse_answer(&truncated, RecordType::A).is_err());
        let mut nonzero_id = answer(0, &[]);
        nonzero_id[1] = 7;
        assert!(parse_answer(&nonzero_id, RecordType::A).is_err());
        // A label length with the reserved 01 or 10 top bits.
        let mut reserved = answer(0, &[]);
        reserved[12] = 0x40;
        assert!(parse_answer(&reserved, RecordType::A).is_err());
    }
}
