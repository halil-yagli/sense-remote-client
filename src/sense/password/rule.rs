//! Sense Remote (permanent password plan §3.8): the password rule, one source for the UI hint and
//! the privileged process's decision. U9: every password is refused (`unsupported`); U10 writes
//! the rule (`length`, `charset`, `repeated`, `contains_id`, `common`).

/// `Ok` or the rule code. `rid` = this computer's ID.
pub fn check(password: &str, rid: &str) -> Result<(), &'static str> {
    let _ = (password, rid);
    Err(super::UNSUPPORTED)
}
