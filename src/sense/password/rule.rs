//! Sense Remote (permanent password plan §3.8): the password rule, one source for the UI hint and
//! the privileged process's decision. The panel never sees the password; its copy of the rule
//! (`packages/shared/scripts/password-vector/rule.ts`) only builds the shared test vector, which
//! this module must pass case for case (`testdata/password-v1.json`, `rule` cases).

pub const MIN_LENGTH: usize = 12;
pub const MAX_LENGTH: usize = 64;
/// At least this many different characters. Every repetition with a period of 4 or less
/// (`aaaa…`, `abab…`, `Xy7#Xy7#…`) has at most 4, so this covers them too.
pub const MIN_DISTINCT: usize = 6;

/// Check order: the code of the first rule that fails is returned. `charset` first, so the
/// length is counted on ASCII only (character = byte).
pub const ORDER: [&str; 5] = ["charset", "length", "repeated", "contains_id", "common"];

/// Looked for as a substring of the candidate with A–Z lowered. All lowercase ASCII.
pub const COMMON: [&str; 15] = [
    "sense",
    "sensedepartment",
    "senseremote",
    "snsdpt",
    "rustdesk",
    "password",
    "parola",
    "sifre",
    "qwerty",
    "asdfgh",
    "123456",
    "654321",
    "letmein",
    "welcome",
    "zxcvbn",
];

/// "Next" character: code + 1, but `9`, `z`, `Z` wrap INSTEAD (9→0, z→a, Z→A). So `9:`,
/// `Z[` and `z{` are not a sequence.
fn next(code: u8) -> u8 {
    match code {
        b'9' => b'0',
        b'z' => b'a',
        b'Z' => b'A',
        _ => code.wrapping_add(1),
    }
}

fn is_repeated_or_sequence(bytes: &[u8]) -> bool {
    let mut distinct = [false; 128];
    for &b in bytes {
        distinct[usize::from(b & 0x7f)] = true;
    }
    let pairs = || bytes.windows(2).map(|w| (w[0], w[1]));
    distinct.iter().filter(|seen| **seen).count() < MIN_DISTINCT
        || pairs().all(|(a, b)| b == next(a))
        || pairs().all(|(a, b)| a == next(b))
}

/// `Ok` or the code of the first failing rule (`ORDER`). `rid` = this computer's ID.
pub fn check(password: &str, rid: &str) -> Result<(), &'static str> {
    let bytes = password.as_bytes();
    // charset: printable ASCII without space (0x21–0x7E).
    if !bytes.iter().all(|b| (0x21..=0x7e).contains(b)) {
        return Err("charset");
    }
    if !(MIN_LENGTH..=MAX_LENGTH).contains(&bytes.len()) {
        return Err("length");
    }
    if is_repeated_or_sequence(bytes) {
        return Err("repeated");
    }
    // contains_id: the ID as it is (case-sensitive).
    if !rid.is_empty() && password.contains(rid) {
        return Err("contains_id");
    }
    // common: only A–Z are lowered (no locale-dependent mapping). Sense Remote (security review
    // C2): the lowered copy is a password too, so it lives in a buffer that is zeroed on drop.
    let lower = super::SensePasswordSecret::new(password.to_ascii_lowercase());
    if COMMON.iter().any(|word| lower.expose().contains(word)) {
        return Err("common");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rule_table() {
        assert_eq!(check("Mavi-Kapi_47!tuz", "123456789"), Ok(()));
        assert_eq!(check("Mavi Kapi 47 tuz", ""), Err("charset"));
        assert_eq!(check("Mavi-Kapı_47!tuz", ""), Err("charset"));
        assert_eq!(check("aB3$eF7!kL9", ""), Err("length"));
        assert_eq!(check("", ""), Err("length"));
        assert_eq!(check("123456789012", ""), Err("repeated"));
        assert_eq!(check("lkjihgfedcba", ""), Err("repeated"));
        assert_eq!(check("Kx7#mKx7#mKx", ""), Err("repeated"));
        // 9 -> : is not a step (wrap instead).
        assert_eq!(check("456789:;<=>?", ""), Ok(()));
        assert_eq!(check("Kx!123456789#Tz", "123456789"), Err("contains_id"));
        assert_eq!(check("Kx!SeNsE#47Tz", ""), Err("common"));
    }
}
