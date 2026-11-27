//! Sense Remote (Sürüm 12, plan 2026-11-28 §2.1, §2.3): the admin terminal ("yönetici
//! terminali"). Skeleton from ÇK-0; ÇK fills it.
//!
//! The ticket: Ed25519 with the panel's envelope key, domain prefix `sense-term-admin-v1`, body
//! (JCS) `{v:1, purpose:"term-admin", host, uid, email, iat, exp: iat+60, nonce}`. The Host
//! checks signature, `purpose`, `host` == its own id, `exp`, an unused nonce (last 10 min, in
//! memory) and the local `enable-terminal` = `Y`. The Controller asks the panel for it in Rust and
//! sends it over the terminal connection (`sense.term-admin`): it never reaches Dart, the record
//! or a log.

/// Signing domain of the ticket (same as the panel, `packages/shared/src/term-admin-node.ts`).
pub const DOMAIN: &str = "sense-term-admin-v1";

/// Why the Host refused a ticket (contract codes, `sense.term-admin-result.err`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    BadSig,
    Expired,
    Replay,
    WrongHost,
    PolicyOff,
    Unsupported,
}

impl Refusal {
    pub fn code(self) -> &'static str {
        match self {
            Refusal::BadSig => "bad_sig",
            Refusal::Expired => "expired",
            Refusal::Replay => "replay",
            Refusal::WrongHost => "wrong_host",
            Refusal::PolicyOff => "policy_off",
            Refusal::Unsupported => "unsupported",
        }
    }
}

/// Host: checks a ticket. Until ÇK verifies them every ticket is `unsupported`.
pub fn check_ticket(ticket: &str) -> Result<(), Refusal> {
    let _ = ticket;
    Err(Refusal::Unsupported)
}

/// `session_sense_term_admin_begin`: "" when the ticket was asked for and sent (the answer comes
/// as `sense_term_admin_result`); for now `unsupported`.
pub fn ffi_begin() -> String {
    "unsupported".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_match_the_contract() {
        let all = [
            (Refusal::BadSig, "bad_sig"),
            (Refusal::Expired, "expired"),
            (Refusal::Replay, "replay"),
            (Refusal::WrongHost, "wrong_host"),
            (Refusal::PolicyOff, "policy_off"),
            (Refusal::Unsupported, "unsupported"),
        ];
        for (r, code) in all {
            assert_eq!(r.code(), code);
        }
    }

    #[test]
    fn skeleton_refuses_every_ticket() {
        assert_eq!(check_ticket("a.b.c"), Err(Refusal::Unsupported));
        assert_eq!(ffi_begin(), "unsupported");
    }
}
