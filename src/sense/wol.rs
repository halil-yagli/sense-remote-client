//! Sense Remote (Sürüm 9, R1): Wake-on-LAN from the panel. To wake a computer that is off (the
//! target), the panel picks another Sense Host that is online at the same place (the relay) and
//! gives it a signed wake order in the heartbeat answer (`sense_wol`). This Host checks the order
//! and broadcasts the magic packet for the target's MAC addresses on its own network (UDP 9 and 7,
//! limited and directed broadcast on every IPv4 adapter that is up). RustDesk's own WOL only works
//! for a peer found on the local network (`lan.rs`); this one needs no discovery.
//!
//! Same envelope shape and panel keys as the strategy envelope (`{k, p, s}`, Ed25519), but its own
//! signing prefix `sense-remote/wol/v1\n`, so no other signed object counts as a wake order. It
//! does not touch the device `seq`. Checks, in the panel's order (`packages/shared/src/wol-node.ts`,
//! shared vector `testdata/wol-v1.json`):
//!
//! envelope shape → `k` known → p/s decode (s 64 bytes) → signature (wol prefix) → JSON + schema
//! (no unknown field, `typ` wol, `wid` = `wol_` + 16–32 base64url, 1–8 MACs in upper case with
//! colons, no repeats, never 00:..:00 / FF:..:FF, `0 < exp − iat ≤ 120`) → `iss` → `did` + `duuid`
//! (this computer) → `iat − 300 ≤ now ≤ exp + 300` → `wid` not used before.
//!
//! The panel gives the same order in every answer until it expires (in case one answer is lost);
//! the `wid`s already used are kept in memory, so the packets go out once. After a restart an
//! order still in its two minutes may go out once more, which only wakes the same computer again.
//! The MAC addresses come only from the panel's inventory of the target; this side cannot tell
//! which computer they belong to, so the signature is the protection. Nothing is written to disk;
//! the log names the order and the counts, never a MAC address.

use super::envelope_keys::{self, TrustedKey};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    config::Config,
    log,
    sodiumoxide::{
        self,
        crypto::sign::{verify_detached, PublicKey, Signature},
    },
};
use serde_derive::Deserialize;
use serde_json::Value;
use std::{
    net::{Ipv4Addr, SocketAddrV4, UdpSocket},
    sync::{Mutex, OnceLock},
};

/// Domain separation: signed data = this prefix (ASCII) ‖ payload bytes.
pub const SIGNING_PREFIX: &[u8] = b"sense-remote/wol/v1\n";
/// Same allowance as the strategy envelope.
pub const CLOCK_SKEW_S: i64 = super::envelope::CLOCK_SKEW_S;
/// `exp − iat` upper limit: two minutes.
pub const MAX_LIFETIME_S: i64 = 120;
/// MAC addresses in one order (the target's adapters).
pub const MAX_MACS: usize = 8;
/// Heartbeat capability: this build carries out signed wake orders. The panel picks a relay only
/// among the computers that report it.
pub const CAP_WOL: &str = "wol";
/// Where wake orders are carried out (the platforms whose `--server` sends the heartbeat).
pub const SUPPORTED: bool = cfg!(any(windows, target_os = "macos"));
/// Key of the heartbeat answer that carries the order.
pub const KEY_ANSWER: &str = "sense_wol";
/// Magic packet ports: 9 (discard, the usual one) and 7 (echo, some network cards listen there).
pub const PORTS: [u16; 2] = [9, 7];

const MAX_PAYLOAD_CHARS: usize = 65_536;
const SIGNATURE_CHARS: usize = 86;
/// The panel's numbers are JavaScript numbers: integers beyond this fail its schema.
const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
/// How many used `wid`s are remembered (an order lives two minutes; a handful is plenty).
const SEEN_KEEP: usize = 64;

/// Why an order was not carried out. Names are the panel's `WolRejectReason` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Malformed,
    UnknownKey,
    BadSignature,
    BadPayload,
    WrongIssuer,
    WrongDevice,
    NotYetValid,
    Expired,
    Replayed,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Malformed => "malformed",
            Reason::UnknownKey => "unknown_key",
            Reason::BadSignature => "bad_signature",
            Reason::BadPayload => "bad_payload",
            Reason::WrongIssuer => "wrong_issuer",
            Reason::WrongDevice => "wrong_device",
            Reason::NotYetValid => "not_yet_valid",
            Reason::Expired => "expired",
            Reason::Replayed => "replayed",
        }
    }
}

/// What this computer expects; all supplied by the caller.
#[derive(Debug, Clone, Copy)]
pub struct Expect<'a> {
    pub iss: &'a str,
    pub did: &'a str,
    pub duuid: &'a str,
    /// Local clock, Unix seconds.
    pub now_s: i64,
    /// `wid`s already carried out.
    pub seen: &'a [String],
}

/// A verified wake order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Order {
    pub wid: String,
    pub macs: Vec<[u8; 6]>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    v: i64,
    typ: String,
    iss: String,
    did: String,
    duuid: String,
    wid: String,
    macs: Vec<String>,
    iat: i64,
    exp: i64,
}

fn is_safe_int(value: i64) -> bool {
    (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&value)
}

fn len_between(value: &str, min: usize, max: usize) -> bool {
    // zod counts UTF-16 units; the panel only signs ASCII here, where both agree.
    let n = value.encode_utf16().count();
    (min..=max).contains(&n)
}

fn is_base64url_alphabet(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The panel's `WolId`: `wol_` + 16–32 base64url characters.
fn is_wid(value: &str) -> bool {
    value
        .strip_prefix("wol_")
        .is_some_and(|rest| (16..=32).contains(&rest.len()) && is_base64url_alphabet(rest))
}

/// The panel's `WolMac`: `AA:BB:CC:DD:EE:FF` in upper case, never all zero or all FF.
pub fn parse_mac(value: &str) -> Option<[u8; 6]> {
    let bytes = value.as_bytes();
    if bytes.len() != 17 {
        return None;
    }
    let mut mac = [0u8; 6];
    for (i, byte) in mac.iter_mut().enumerate() {
        let pair = &bytes[i * 3..i * 3 + 2];
        if i < 5 && bytes[i * 3 + 2] != b':' {
            return None;
        }
        if !pair
            .iter()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(b))
        {
            return None;
        }
        *byte = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    (mac != [0; 6] && mac != [0xff; 6]).then_some(mac)
}

impl Payload {
    /// The panel's `WolPayload` schema.
    fn is_valid(&self) -> bool {
        let macs_ok = (1..=MAX_MACS).contains(&self.macs.len())
            && self.macs.iter().all(|m| parse_mac(m).is_some())
            && self
                .macs
                .iter()
                .enumerate()
                .all(|(i, m)| !self.macs[..i].contains(m));
        self.v == 1
            && self.typ == "wol"
            && len_between(&self.iss, 1, 253)
            && len_between(&self.did, 1, 64)
            && len_between(&self.duuid, 1, 128)
            && is_wid(&self.wid)
            && macs_ok
            && self.iat >= 0
            && self.exp > 0
            && [self.iat, self.exp].into_iter().all(is_safe_int)
            && self.exp > self.iat
            && self.exp - self.iat <= MAX_LIFETIME_S
    }
}

fn sodium_ready() -> bool {
    static INIT: OnceLock<bool> = OnceLock::new();
    *INIT.get_or_init(|| {
        let ok = sodiumoxide::init().is_ok();
        if !ok {
            log::error!("Sense Remote: sodiumoxide init failed, wake orders cannot be verified");
        }
        ok
    })
}

fn signature_ok(public_key: &[u8; 32], payload: &[u8], signature: &[u8; 64]) -> bool {
    if !sodium_ready() {
        return false;
    }
    let Ok(signature) = Signature::from_bytes(signature) else {
        return false;
    };
    let mut signed = Vec::with_capacity(SIGNING_PREFIX.len() + payload.len());
    signed.extend_from_slice(SIGNING_PREFIX);
    signed.extend_from_slice(payload);
    verify_detached(&signature, &signed, &PublicKey(*public_key))
}

/// Every check, in the panel's order. Pure; `keys` are the trusted panel keys.
pub fn verify(envelope: &Value, keys: &[TrustedKey], expect: &Expect) -> Result<Order, Reason> {
    // 1. Shape: exactly {k, p, s}, strings in the panel's alphabet and lengths.
    let object = envelope.as_object().ok_or(Reason::Malformed)?;
    if object.len() != 3 {
        return Err(Reason::Malformed);
    }
    let field = |name: &str| object.get(name).and_then(Value::as_str);
    let (Some(k), Some(p), Some(s)) = (field("k"), field("p"), field("s")) else {
        return Err(Reason::Malformed);
    };
    if !envelope_keys::is_key_id(k)
        || p.is_empty()
        || p.len() > MAX_PAYLOAD_CHARS
        || !is_base64url_alphabet(p)
        || s.len() != SIGNATURE_CHARS
        || !is_base64url_alphabet(s)
    {
        return Err(Reason::Malformed);
    }
    // 2. Known key.
    let key = keys.iter().find(|key| key.k == k).ok_or(Reason::UnknownKey)?;
    // 3. Strict base64url, 64-byte signature.
    let payload = URL_SAFE_NO_PAD.decode(p).map_err(|_| Reason::Malformed)?;
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(s)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(Reason::Malformed)?;
    // 4. Signature over the wol prefix ‖ payload bytes, exactly as received.
    if !signature_ok(&key.public_key, &payload, &signature) {
        return Err(Reason::BadSignature);
    }
    // 5. Schema of the signed bytes (never re-canonicalized).
    let payload: Payload = serde_json::from_slice(&payload).map_err(|_| Reason::BadPayload)?;
    if !payload.is_valid() {
        return Err(Reason::BadPayload);
    }
    // 6. Issuer and this computer.
    if payload.iss != expect.iss {
        return Err(Reason::WrongIssuer);
    }
    if payload.did != expect.did || payload.duuid != expect.duuid {
        return Err(Reason::WrongDevice);
    }
    // 7. Validity window with clock skew allowance.
    if expect.now_s < payload.iat.saturating_sub(CLOCK_SKEW_S) {
        return Err(Reason::NotYetValid);
    }
    if expect.now_s > payload.exp.saturating_add(CLOCK_SKEW_S) {
        return Err(Reason::Expired);
    }
    // 8. Once per order.
    if expect.seen.iter().any(|wid| *wid == payload.wid) {
        return Err(Reason::Replayed);
    }
    Ok(Order {
        macs: payload.macs.iter().filter_map(|m| parse_mac(m)).collect(),
        wid: payload.wid,
    })
}

/// The magic packet: six 0xFF bytes, then the MAC sixteen times.
pub fn magic_packet(mac: &[u8; 6]) -> [u8; 102] {
    let mut packet = [0xffu8; 102];
    for chunk in packet[6..].chunks_exact_mut(6) {
        chunk.copy_from_slice(mac);
    }
    packet
}

/// Where the packets go: for every usable IPv4 address of an adapter that is up, bound to that
/// address, the limited broadcast `255.255.255.255` and (for a /1–/30 network) the network's own
/// broadcast address. A computer with several adapters reaches every network it is on. Loopback,
/// unspecified and link-local (169.254.x.x) addresses are skipped. No repeats.
pub fn broadcast_targets(addresses: &[(Ipv4Addr, u8)]) -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let mut targets = Vec::new();
    for &(addr, prefix) in addresses {
        if addr.is_loopback() || addr.is_unspecified() || addr.is_link_local() || prefix > 32 {
            continue;
        }
        let mut push = |dest: Ipv4Addr| {
            if !targets.contains(&(addr, dest)) {
                targets.push((addr, dest));
            }
        };
        push(Ipv4Addr::BROADCAST);
        if (1..=30).contains(&prefix) {
            let host_bits = u32::MAX >> prefix;
            push(Ipv4Addr::from(u32::from(addr) | host_bits));
        }
    }
    targets
}

/// IPv4 addresses (with prefix length) of the adapters that are up, loopback left out. Same
/// source as `network.rs` (`default-net`, not on the mobile platforms).
#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn local_addresses() -> Vec<(Ipv4Addr, u8)> {
    default_net::get_interfaces()
        .into_iter()
        .filter(|i| i.is_up() && !i.is_loopback())
        .flat_map(|i| i.ipv4.into_iter().map(|n| (n.addr, n.prefix_len)))
        .collect()
}

#[cfg(any(target_os = "ios", target_os = "android"))]
fn local_addresses() -> Vec<(Ipv4Addr, u8)> {
    Vec::new()
}

/// Sends every packet; returns how many went out. Blocking (a few UDP sends).
fn send(order: &Order) -> usize {
    let mut targets = broadcast_targets(&local_addresses());
    if targets.is_empty() {
        // No adapter address read: let the system pick the way out.
        targets.push((Ipv4Addr::UNSPECIFIED, Ipv4Addr::BROADCAST));
    }
    let mut sent = 0;
    for (bind, dest) in targets {
        let socket = match UdpSocket::bind(SocketAddrV4::new(bind, 0)) {
            Ok(socket) => socket,
            Err(err) => {
                log::debug!("Sense Remote: wake-on-LAN socket on {bind} not opened: {err}");
                continue;
            }
        };
        if let Err(err) = socket.set_broadcast(true) {
            log::debug!("Sense Remote: wake-on-LAN broadcast on {bind} refused: {err}");
            continue;
        }
        for mac in &order.macs {
            let packet = magic_packet(mac);
            for port in PORTS {
                if socket.send_to(&packet, SocketAddrV4::new(dest, port)).is_ok() {
                    sent += 1;
                }
            }
        }
    }
    sent
}

fn seen() -> &'static Mutex<Vec<String>> {
    static SEEN: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
    SEEN.get_or_init(|| Mutex::new(Vec::new()))
}

fn now_s() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Called by the heartbeat loop (`hbbs_http/sync.rs`) with the panel's answer. Does nothing when
/// the answer carries no `sense_wol`; otherwise verifies it and, once per order, sends the packets
/// on a separate thread so the heartbeat never waits.
pub fn on_answer(answer: &str) {
    if !SUPPORTED {
        return;
    }
    let Some(envelope) = serde_json::from_str::<Value>(answer)
        .ok()
        .and_then(|mut v| v.get_mut(KEY_ANSWER).map(Value::take))
    else {
        return;
    };
    let iss = super::envelope::expected_issuer();
    let did = Config::get_id();
    let duuid = crate::encode64(hbb_common::get_uuid());
    let order = {
        let mut seen = seen().lock().unwrap_or_else(|e| e.into_inner());
        let checked = verify(
            &envelope,
            envelope_keys::trusted_keys(),
            &Expect {
                iss: &iss,
                did: &did,
                duuid: &duuid,
                now_s: now_s(),
                seen: &seen,
            },
        );
        match checked {
            Ok(order) => {
                seen.push(order.wid.clone());
                if seen.len() > SEEN_KEEP {
                    seen.remove(0);
                }
                order
            }
            Err(Reason::Replayed) => return,
            Err(reason) => {
                log::warn!("Sense Remote: wake-on-LAN order refused: {}", reason.as_str());
                return;
            }
        }
    };
    std::thread::spawn(move || {
        let sent = send(&order);
        if sent > 0 {
            log::info!(
                "Sense Remote: wake-on-LAN order {} carried out: {sent} packets for {} computer address(es)",
                order.wid,
                order.macs.len()
            );
        } else {
            log::warn!("Sense Remote: wake-on-LAN order {}: no packet could be sent", order.wid);
        }
    });
}

#[cfg(test)]
mod tests {
    // Sense Remote: verification against the panel's shared vector (`wol-v1.json`, made by
    // `packages/shared/scripts/make-wol-vector.ts` with keys that existed only in memory; public
    // data only). Copied verbatim: update both repositories in the same change.
    use super::*;
    use crate::sense::envelope_keys::{key_id, parse_keys};

    const VECTOR: &str = include_str!("testdata/wol-v1.json");

    fn vector() -> Value {
        serde_json::from_str(VECTOR).expect("wol-v1.json is valid JSON")
    }

    fn str_of<'a>(value: &'a Value, field: &str) -> &'a str {
        value[field]
            .as_str()
            .unwrap_or_else(|| panic!("{field} is a string"))
    }

    fn vector_keys(v: &Value) -> Vec<TrustedKey> {
        let entries: Vec<String> = v["keys"]
            .as_array()
            .unwrap()
            .iter()
            .map(|key| format!("{}={}", str_of(key, "k"), str_of(key, "public_key")))
            .collect();
        parse_keys(&entries.join(",")).expect("vector keys parse as SENSE_ENVELOPE_KEYS")
    }

    #[test]
    fn vector_constants_match() {
        let v = vector();
        assert_eq!(v["v"], 1);
        assert_eq!(str_of(&v, "prefix").as_bytes(), SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::envelope::SIGNING_PREFIX);
        assert_ne!(SIGNING_PREFIX, crate::sense::grants::SIGNING_PREFIX);
        assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
        assert_eq!(v["max_lifetime_s"].as_i64(), Some(MAX_LIFETIME_S));
        assert_eq!(v["max_macs"].as_u64(), Some(MAX_MACS as u64));
        let keys = vector_keys(&v);
        assert_eq!(keys.len(), 2);
        for key in &keys {
            assert_eq!(key.k, key_id(&key.public_key));
        }
    }

    #[test]
    fn vector_cases_match() {
        let v = vector();
        let keys = vector_keys(&v);
        let cases = v["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 29);
        let mut failures = Vec::new();
        for case in cases {
            let name = str_of(case, "name");
            let wanted = str_of(case, "result");
            let e = &case["expect"];
            let seen: Vec<String> = serde_json::from_value(e["seen"].clone()).unwrap();
            let got = verify(
                &case["envelope"],
                &keys,
                &Expect {
                    iss: str_of(e, "iss"),
                    did: str_of(e, "did"),
                    duuid: str_of(e, "duuid"),
                    now_s: e["now_s"].as_i64().unwrap(),
                    seen: &seen,
                },
            );
            let got_name = match &got {
                Ok(_) => "ok",
                Err(reason) => reason.as_str(),
            };
            if got_name != wanted {
                failures.push(format!("{name}: expected {wanted}, got {got_name}"));
                continue;
            }
            if let Ok(order) = got {
                let macs: Vec<String> = serde_json::from_value(case["macs"].clone()).unwrap();
                let parsed: Vec<[u8; 6]> = macs.iter().map(|m| parse_mac(m).unwrap()).collect();
                assert_eq!(order.macs, parsed, "{name}");
                assert_eq!(Some(order.wid.as_str()), case["wid"].as_str(), "{name}");
            }
        }
        assert!(failures.is_empty(), "vector mismatch:\n{}", failures.join("\n"));
    }

    #[test]
    fn mac_parsing_follows_the_panel_schema() {
        assert_eq!(
            parse_mac("0A:1B:2C:3D:4E:5F"),
            Some([0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f])
        );
        for bad in [
            "0a:1b:2c:3d:4e:5f",
            "0A-1B-2C-3D-4E-5F",
            "0A:1B:2C:3D:4E",
            "0A:1B:2C:3D:4E:5F:00",
            "0A:1B:2C:3D:4E:5G",
            "00:00:00:00:00:00",
            "FF:FF:FF:FF:FF:FF",
            "",
        ] {
            assert_eq!(parse_mac(bad), None, "{bad}");
        }
    }

    #[test]
    fn magic_packet_layout() {
        let mac = [1, 2, 3, 4, 5, 6];
        let packet = magic_packet(&mac);
        assert_eq!(&packet[..6], &[0xff; 6]);
        for chunk in packet[6..].chunks(6) {
            assert_eq!(chunk, &mac);
        }
        assert_eq!(packet.len(), 6 + 16 * 6);
    }

    #[test]
    fn broadcast_targets_per_adapter() {
        let lan: Ipv4Addr = "192.168.1.20".parse().unwrap();
        let office: Ipv4Addr = "10.4.0.7".parse().unwrap();
        let targets = broadcast_targets(&[
            (lan, 24),
            (lan, 24),
            (office, 16),
            ("10.9.9.9".parse().unwrap(), 32),
            (Ipv4Addr::LOCALHOST, 8),
            ("169.254.3.4".parse().unwrap(), 16),
            (Ipv4Addr::UNSPECIFIED, 0),
        ]);
        assert_eq!(
            targets,
            vec![
                (lan, Ipv4Addr::BROADCAST),
                (lan, "192.168.1.255".parse().unwrap()),
                (office, Ipv4Addr::BROADCAST),
                (office, "10.4.255.255".parse().unwrap()),
                ("10.9.9.9".parse().unwrap(), Ipv4Addr::BROADCAST),
            ]
        );
        assert!(broadcast_targets(&[]).is_empty());
    }

    #[test]
    fn capability_fits_the_panel_schema() {
        assert!(!CAP_WOL.is_empty() && CAP_WOL.len() <= 32);
        assert_eq!(PORTS, [9, 7]);
    }
}
