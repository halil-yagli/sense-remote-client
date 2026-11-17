//! Sense Remote: IP addresses of the computer's network adapters for the panel's info section
//! (`sense.network`): every real Ethernet / Wi-Fi adapter with its addresses, Ethernet first.
//!
//! Source: the `default-net` crate already used by `lan.rs` (Windows: `GetAdaptersAddresses`,
//! IfType 6 = Ethernet, 71 = Wi-Fi; macOS: `getifaddrs` + the system's adapter type list).
//! Left out: loopback, tunnels / point-to-point (VPN), virtual adapters (Hyper-V, WSL, Docker,
//! VMware, VirtualBox ...), APIPA 169.254.x.x, IPv6 link-local fe80::/10, adapters without
//! an address. The MAC address is never sent.
//!
//! Order: Ethernet -> Wi-Fi -> other, then by interface index (the crate does not expose the
//! route metric, so the index stands in for "interface order").
//!
//! MAC-SONRA: compiles on macOS but is not checked on a Mac yet (adapter names en0/en1, Wi-Fi
//! detection through the crate's `networksetup` map).
//!
//! Sense Remote (wave 2 review):
//! - K2-5: `collect` tells "no adapter left" (`Some([])`, sent as `network: []` so the panel
//!   drops the old addresses) from "could not read" (`None`, field left out = unknown).
//! - K2-8: an entry that would not pass the panel's `SenseNetworkInterface` is skipped on its
//!   own, so one odd adapter never makes the panel drop the whole `sense` extension.
//! - G2-12: IPv6 addresses that carry the MAC (EUI-64, `..ff:fe..`) or an embedded IPv4
//!   (`::ffff:a.b.c.d`) are not sent.

// Sense Remote: some helpers are only reached on Windows / in tests.
#![allow(dead_code)]

use serde_derive::{Deserialize, Serialize};
use std::net::{Ipv4Addr, Ipv6Addr};

pub const MAX_ADAPTERS: usize = 16;
pub const MAX_ADDRESSES: usize = 8;
const MAX_NAME_CHARS: usize = 64;

/// One entry of `sense.network` (contract: `{ name, kind, ipv4, ipv6?, up? }`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SenseNetwork {
    pub name: String,
    pub kind: String,
    pub ipv4: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipv6: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub up: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Kind {
    Ethernet,
    Wifi,
    Other,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Ethernet => "ethernet",
            Kind::Wifi => "wifi",
            Kind::Other => "other",
        }
    }
}

/// What the OS reports for one adapter, before filtering.
#[derive(Debug, Clone)]
pub(super) struct RawAdapter {
    pub index: u32,
    /// Shown name ("Ethernet", "Wi-Fi", "en0").
    pub name: String,
    /// Driver description, only used to recognise virtual adapters; never sent.
    pub description: String,
    pub kind: Kind,
    pub loopback: bool,
    pub tunnel: bool,
    pub up: bool,
    pub ipv4: Vec<Ipv4Addr>,
    pub ipv6: Vec<Ipv6Addr>,
}

/// Adapters of this computer, filtered and ordered for the panel. `None` when the OS reported
/// no adapter at all (read failed or unsupported platform; Windows always has a loopback), so the
/// caller leaves `network` out; `Some(vec![])` when adapters exist but none is worth sending.
pub fn collect() -> Option<Vec<SenseNetwork>> {
    from_raw(read_adapters())
}

fn from_raw(adapters: Vec<RawAdapter>) -> Option<Vec<SenseNetwork>> {
    (!adapters.is_empty()).then(|| build(adapters))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn read_adapters() -> Vec<RawAdapter> {
    use default_net::interface::InterfaceType;
    default_net::get_interfaces()
        .into_iter()
        .map(|i| {
            let kind = match i.if_type {
                InterfaceType::Ethernet
                | InterfaceType::FastEthernetT
                | InterfaceType::FastEthernetFx
                | InterfaceType::GigabitEthernet => Kind::Ethernet,
                InterfaceType::Wireless80211 => Kind::Wifi,
                _ => Kind::Other,
            };
            RawAdapter {
                index: i.index,
                loopback: i.is_loopback() || i.if_type == InterfaceType::Loopback,
                tunnel: i.is_tun()
                    || i.is_point_to_point()
                    || matches!(i.if_type, InterfaceType::Tunnel | InterfaceType::Ppp),
                up: i.is_up(),
                name: i.friendly_name.clone().unwrap_or_else(|| i.name.clone()),
                description: i.description.clone().unwrap_or_default(),
                kind,
                ipv4: i.ipv4.iter().map(|n| n.addr).collect(),
                ipv6: i.ipv6.iter().map(|n| n.addr).collect(),
            }
        })
        .collect()
}

#[cfg(any(target_os = "ios", target_os = "android"))]
fn read_adapters() -> Vec<RawAdapter> {
    Vec::new()
}

/// Name / description fragments of virtual and helper adapters (lower case).
const VIRTUAL_MARKERS: [&str; 22] = [
    "virtual", "vethernet", "hyper-v", "vmware", "virtualbox", "vbox", "docker", "wsl",
    "loopback", "pseudo", "tap-", "tap ", "tunnel", "wireguard", "openvpn", "vpn", "zerotier",
    "tailscale", "npcap", "bluetooth", "teredo", "isatap",
];

/// macOS helper interfaces (AirDrop, VPN, bridges, Thunderbolt bridge ...) by name prefix.
const MAC_HELPER_PREFIXES: [&str; 10] = [
    "lo", "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap", "ipsec",
];

fn is_virtual(adapter: &RawAdapter) -> bool {
    let name = adapter.name.to_ascii_lowercase();
    let description = adapter.description.to_ascii_lowercase();
    if VIRTUAL_MARKERS
        .iter()
        .any(|m| name.contains(m) || description.contains(m))
    {
        return true;
    }
    cfg!(target_os = "macos") && MAC_HELPER_PREFIXES.iter().any(|p| name.starts_with(p))
}

fn keep_ipv4(ip: &Ipv4Addr) -> bool {
    !(ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() || ip.is_broadcast())
}

fn keep_ipv6(ip: &Ipv6Addr) -> bool {
    let s = ip.segments();
    // fe80::/10 (link-local) is only reachable on the same link.
    let link_local = (s[0] & 0xffc0) == 0xfe80;
    // Sense Remote (G2-12): an EUI-64 interface id (`xxxx:xxff:fexx:xxxx`) is built from the
    // MAC address, which the contract never sends.
    let eui64 = (s[5] & 0x00ff) == 0x00ff && (s[6] & 0xff00) == 0xfe00;
    // ::ffff:a.b.c.d (IPv4-mapped) and ::a.b.c.d (old IPv4-compatible) repeat an IPv4 address.
    let embeds_ipv4 = s[..5] == [0; 5] && (s[5] == 0xffff || s[5] == 0);
    !(ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_multicast()
        || link_local
        || eui64
        || embeds_ipv4)
}

/// Sense Remote (K2-8): the panel's `SenseNetworkInterface` limits (name <= 128 UTF-16 units,
/// <= 8 addresses each, known kind). `build` already keeps within them; this is the last check
/// before sending, so an entry that does not fit is skipped instead of failing the whole body.
fn fits_contract(n: &SenseNetwork) -> bool {
    let name_ok = !n.name.trim().is_empty()
        && n.name.encode_utf16().count() <= 128
        && !n.name.chars().any(char::is_control);
    let kind_ok = ["ethernet", "wifi", "other"].contains(&n.kind.as_str());
    let ipv4_ok =
        n.ipv4.len() <= MAX_ADDRESSES && n.ipv4.iter().all(|ip| ip.parse::<Ipv4Addr>().is_ok());
    let ipv6 = n.ipv6.as_deref().unwrap_or_default();
    let ipv6_ok = ipv6.len() <= MAX_ADDRESSES && ipv6.iter().all(|ip| ip.parse::<Ipv6Addr>().is_ok());
    name_ok && kind_ok && ipv4_ok && ipv6_ok && (!n.ipv4.is_empty() || !ipv6.is_empty())
}

fn build(adapters: Vec<RawAdapter>) -> Vec<SenseNetwork> {
    let mut kept: Vec<RawAdapter> = adapters
        .into_iter()
        .filter(|a| !a.loopback && !a.tunnel && !is_virtual(a))
        .map(|mut a| {
            a.ipv4.retain(keep_ipv4);
            a.ipv6.retain(keep_ipv6);
            a
        })
        .filter(|a| !a.ipv4.is_empty() || !a.ipv6.is_empty())
        .collect();
    kept.sort_by_key(|a| (a.kind, a.index));
    kept.into_iter()
        .take(MAX_ADAPTERS)
        .map(|a| {
            let name = a.name.trim();
            // Sense Remote (K2-8): control characters would make the name unreadable in the panel.
            let name: String = name
                .chars()
                .filter(|c| !c.is_control())
                .take(MAX_NAME_CHARS)
                .collect();
            let name = if name.trim().is_empty() {
                a.kind.as_str().to_owned()
            } else {
                name
            };
            let ipv4: Vec<String> = a
                .ipv4
                .iter()
                .take(MAX_ADDRESSES)
                .map(|ip| ip.to_string())
                .collect();
            let ipv6: Vec<String> = a
                .ipv6
                .iter()
                .take(MAX_ADDRESSES)
                .map(|ip| ip.to_string())
                .collect();
            SenseNetwork {
                name,
                kind: a.kind.as_str().to_owned(),
                ipv4,
                ipv6: (!ipv6.is_empty()).then_some(ipv6),
                up: Some(a.up),
            }
        })
        .filter(|n| {
            let ok = fits_contract(n);
            if !ok {
                hbb_common::log::warn!("Sense Remote: a network adapter entry was skipped");
            }
            ok
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter(index: u32, name: &str, kind: Kind, ipv4: &[&str]) -> RawAdapter {
        RawAdapter {
            index,
            name: name.into(),
            description: String::new(),
            kind,
            loopback: false,
            tunnel: false,
            up: true,
            ipv4: ipv4.iter().map(|s| s.parse().unwrap()).collect(),
            ipv6: Vec::new(),
        }
    }

    #[test]
    fn order_and_filters() {
        let mut wifi = adapter(3, "Wi-Fi", Kind::Wifi, &["192.168.1.20"]);
        wifi.ipv6 = vec!["fe80::1".parse().unwrap(), "2001:db8::5".parse().unwrap()];
        let mut hyperv = adapter(1, "vEthernet (WSL)", Kind::Ethernet, &["172.20.0.1"]);
        hyperv.description = "Hyper-V Virtual Ethernet Adapter".into();
        let mut vmware = adapter(2, "Ethernet 3", Kind::Ethernet, &["192.168.56.1"]);
        vmware.description = "VMware Virtual Ethernet Adapter for VMnet1".into();
        let mut loopback = adapter(0, "Loopback Pseudo-Interface 1", Kind::Other, &["127.0.0.1"]);
        loopback.loopback = true;
        let mut vpn = adapter(4, "Office", Kind::Other, &["10.8.0.2"]);
        vpn.tunnel = true;
        let input = vec![
            wifi,
            hyperv,
            vmware,
            loopback,
            vpn,
            adapter(9, "Ethernet 2", Kind::Ethernet, &["10.0.0.7", "169.254.3.4"]),
            adapter(5, "Ethernet", Kind::Ethernet, &["192.168.1.10"]),
            adapter(6, "Ethernet 4", Kind::Ethernet, &["169.254.10.10"]), // APIPA only
            adapter(7, "Cellular", Kind::Other, &["100.64.1.2"]),
        ];
        let out = build(input);
        let names: Vec<&str> = out.iter().map(|n| n.name.as_str()).collect();
        assert_eq!(names, ["Ethernet", "Ethernet 2", "Wi-Fi", "Cellular"]);
        assert_eq!(out[1].ipv4, ["10.0.0.7"]);
        assert_eq!(out[1].ipv6, None);
        assert_eq!(out[2].kind, "wifi");
        assert_eq!(out[2].ipv6.as_deref(), Some(&["2001:db8::5".to_owned()][..]));
        assert_eq!(out[3].kind, "other");
    }

    #[test]
    fn limits() {
        let many: Vec<String> = (1..=20).map(|i| format!("10.0.0.{i}")).collect();
        let many: Vec<&str> = many.iter().map(|s| s.as_str()).collect();
        let input: Vec<RawAdapter> = (0..20)
            .map(|i| adapter(i, &format!("Ethernet {i}"), Kind::Ethernet, &many))
            .collect();
        let out = build(input);
        assert_eq!(out.len(), MAX_ADAPTERS);
        assert!(out.iter().all(|n| n.ipv4.len() == MAX_ADDRESSES));
    }

    #[test]
    fn no_adapter_left_is_an_empty_list_not_unknown() {
        // K2-5: cable out, no Wi-Fi: the OS still reports the loopback -> Some([]), sent as
        // `network: []`.
        let mut loopback = adapter(1, "Loopback Pseudo-Interface 1", Kind::Other, &["127.0.0.1"]);
        loopback.loopback = true;
        let unplugged = adapter(2, "Ethernet", Kind::Ethernet, &[]);
        assert_eq!(from_raw(vec![loopback, unplugged]), Some(vec![]));
        // Nothing reported at all: unknown, the field is left out.
        assert_eq!(from_raw(vec![]), None);
    }

    #[test]
    fn ipv6_with_mac_or_ipv4_is_not_sent() {
        let mut eth = adapter(1, "Ethernet", Kind::Ethernet, &["192.168.1.10"]);
        eth.ipv6 = [
            "2001:db8::211:22ff:fe33:4455", // EUI-64 from MAC 00:11:22:33:44:55
            "2001:db8:0:0:211:22ff:fe33:4455",
            "::ffff:192.168.1.10",
            "::192.168.1.10",
            "2001:db8::5", // temporary / random interface id: kept
            "fd00::1234",  // ULA: kept
        ]
        .iter()
        .map(|s| s.parse().unwrap())
        .collect();
        let out = build(vec![eth]);
        assert_eq!(
            out[0].ipv6.as_deref(),
            Some(&["2001:db8::5".to_owned(), "fd00::1234".to_owned()][..])
        );
        // An adapter left with only such addresses is dropped.
        let mut only_mac = adapter(2, "Wi-Fi", Kind::Wifi, &[]);
        only_mac.ipv6 = vec!["2001:db8::211:22ff:fe33:4455".parse().unwrap()];
        assert!(build(vec![only_mac]).is_empty());
    }

    #[test]
    fn an_entry_outside_the_contract_is_skipped_alone() {
        let good = SenseNetwork {
            name: "Ethernet".into(),
            kind: "ethernet".into(),
            ipv4: vec!["10.0.0.7".into()],
            ipv6: None,
            up: Some(true),
        };
        assert!(fits_contract(&good));
        let bad = [
            SenseNetwork { name: " ".into(), ..good.clone() },
            SenseNetwork { name: "a\u{7}b".into(), ..good.clone() },
            // 65 astral characters = 130 UTF-16 units > 128.
            SenseNetwork { name: "\u{1F600}".repeat(65), ..good.clone() },
            SenseNetwork { kind: "cellular".into(), ..good.clone() },
            SenseNetwork { ipv4: vec!["10.0.0.300".into()], ..good.clone() },
            SenseNetwork { ipv4: vec!["10.0.0.1".into(); 9], ..good.clone() },
            SenseNetwork { ipv6: Some(vec!["fe80::1%12".into()]), ..good.clone() },
            SenseNetwork { ipv4: vec![], ipv6: None, ..good.clone() },
        ];
        for n in &bad {
            assert!(!fits_contract(n), "{n:?}");
        }
        // Names with control characters are cleaned in `build`, not dropped.
        let out = build(vec![adapter(1, "Eth\u{0}ernet", Kind::Ethernet, &["10.0.0.7"])]);
        assert_eq!(out[0].name, "Ethernet");
        let out = build(vec![adapter(1, "\u{1}", Kind::Wifi, &["10.0.0.8"])]);
        assert_eq!(out[0].name, "wifi");
    }

    /// Real adapters on the CI machine: whatever is found fits the contract.
    #[test]
    fn live_values_fit_contract() {
        for n in collect().unwrap_or_default() {
            assert!(fits_contract(&n), "{n:?}");
            assert!(["ethernet", "wifi", "other"].contains(&n.kind.as_str()));
            assert!(!n.name.is_empty() && n.name.chars().count() <= MAX_NAME_CHARS);
            assert!(n.ipv4.len() <= MAX_ADDRESSES);
            for ip in &n.ipv4 {
                let ip: Ipv4Addr = ip.parse().unwrap();
                assert!(keep_ipv4(&ip));
            }
            assert!(!n.ipv4.is_empty() || n.ipv6.is_some());
        }
    }
}
