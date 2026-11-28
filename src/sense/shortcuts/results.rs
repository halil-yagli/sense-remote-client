//! Sense Remote (Sürüm 12, #171): the optional result body of `sense.shortcut-result` (`res`)
//! and the one argument a few entries take. Pure functions, tested on every platform.
//!
//! - ping: `{"ping": {"sent", "received", "avg_ms" | null, "loss"}}` (loss in percent);
//! - window / app list: `{"windows": [{"pid", "name", "hung"}]}` (names only go to the
//!   Controller, never to the record);
//! - IP card: `{"ip": {"ip" | null, "gateway": [..], "dns": [..]}}`.
//!
//! The argument (ping address, process id to close) is never put through a shell: it is one
//! argument of a fixed program, and only letters, digits, `.`, `-`, `:` pass.

use serde_json::{json, Value};

/// Longest argument (a DNS name is at most 253 characters).
pub const MAX_ARG: usize = 253;
/// Pings sent per run.
pub const PING_COUNT: u32 = 4;
/// Windows listed at most.
pub const MAX_WINDOWS: usize = 24;
/// Characters of a window / app name kept.
pub const MAX_NAME_CHARS: usize = 60;
/// The serialised result body stays under this (the peer message limit is 4096 bytes).
pub const MAX_RES_BYTES: usize = 3000;

/// Why an argument is refused; `None` = it may be used.
pub fn arg_problem(arg: &str) -> Option<&'static str> {
    if arg.is_empty() || arg.len() > MAX_ARG {
        return Some("length");
    }
    if arg.starts_with('-') || arg.starts_with('.') {
        return Some("leading");
    }
    if !arg
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':'))
    {
        return Some("chars");
    }
    None
}

/// A ping address: a host name, IPv4 or IPv6 literal (checked by [`arg_problem`] first).
pub fn ping_target(arg: &str) -> Option<&str> {
    arg_problem(arg).is_none().then_some(arg)
}

/// A process id to close (digits only, not 0).
pub fn pid_arg(arg: &str) -> Option<u32> {
    if arg.is_empty() || arg.len() > 10 || !arg.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    arg.parse::<u32>().ok().filter(|pid| *pid != 0)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ping {
    pub sent: u32,
    pub received: u32,
    pub avg_ms: Option<u32>,
}

impl Ping {
    pub fn loss(&self) -> u32 {
        if self.sent == 0 {
            return 100;
        }
        let lost = self.sent.saturating_sub(self.received.min(self.sent));
        (lost * 100 + self.sent / 2) / self.sent
    }

    pub fn to_res(&self) -> Value {
        json!({ "ping": {
            "sent": self.sent,
            "received": self.received,
            "avg_ms": self.avg_ms,
            "loss": self.loss(),
        }})
    }
}

/// The number just before `ms` in one reply line ("süre=18ms", "time<1ms", "time=18.123 ms").
fn reply_ms(line: &str) -> Option<f64> {
    let lower = line.to_ascii_lowercase();
    let at = lower.find("ms")?;
    let head = lower[..at].trim_end();
    let start = head
        .char_indices()
        .rev()
        .find(|(_, c)| !(c.is_ascii_digit() || *c == '.' || *c == ','))
        .map_or(0, |(i, c)| i + c.len_utf8());
    let number = head[start..].replace(',', ".");
    let value: f64 = number.parse().ok()?;
    // "time<1ms": under a millisecond counts as 1.
    let less = head[..start].ends_with('<');
    Some(if less { value.max(1.0) } else { value })
}

/// Reads `ping` output in any language: a reply line carries `TTL=` (Windows, every language)
/// or `ttl=` (macOS) and the time before `ms`.
pub fn parse_ping(output: &str, sent: u32) -> Ping {
    let mut received = 0u32;
    let mut times = Vec::new();
    for line in output.lines() {
        if !line.to_ascii_lowercase().contains("ttl=") {
            continue;
        }
        received += 1;
        if let Some(ms) = reply_ms(line) {
            times.push(ms);
        }
    }
    let received = received.min(sent);
    let avg_ms = (!times.is_empty())
        .then(|| (times.iter().sum::<f64>() / times.len() as f64).round() as u32);
    Ping {
        sent,
        received,
        avg_ms: if received == 0 { None } else { avg_ms },
    }
}

/// One window (Windows) or app (macOS) of the signed-in user.
#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    pub pid: u32,
    pub name: String,
    pub hung: bool,
}

/// A name as sent: control characters out, trimmed, at most [`MAX_NAME_CHARS`].
pub fn clean_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    let mut out: String = trimmed.chars().take(MAX_NAME_CHARS).collect();
    if trimmed.chars().count() > MAX_NAME_CHARS {
        out.push('…');
    }
    out
}

/// The list as sent: one entry per process (its first named window), the ones that do not
/// answer first, then by name; at most [`MAX_WINDOWS`] and under [`MAX_RES_BYTES`].
pub fn windows_res(mut list: Vec<Window>, own_pid: u32) -> Value {
    list.retain(|w| w.pid != own_pid && w.pid != 0);
    for w in list.iter_mut() {
        w.name = clean_name(&w.name);
    }
    list.retain(|w| !w.name.is_empty());
    let mut seen = std::collections::HashSet::new();
    list.retain(|w| seen.insert(w.pid));
    list.sort_by(|a, b| b.hung.cmp(&a.hung).then_with(|| a.name.cmp(&b.name)));
    list.truncate(MAX_WINDOWS);
    loop {
        let items: Vec<Value> = list
            .iter()
            .map(|w| json!({ "pid": w.pid, "name": w.name, "hung": w.hung }))
            .collect();
        let res = json!({ "windows": items });
        if res.to_string().len() <= MAX_RES_BYTES || list.is_empty() {
            return res;
        }
        list.pop();
    }
}

/// The IP card from the adapters the status popup shows (`sense.network`, Ethernet first) and
/// the inventory's gateway / DNS of the same adapter (Controller's `senseFavIpInfoFrom`).
pub fn ip_res(
    networks: &[super::super::network::SenseNetwork],
    adapters: &[super::super::health_model::NetAdapter],
) -> Value {
    let find = |name: &str| {
        adapters
            .iter()
            .find(|a| a.name == name || a.device.as_deref() == Some(name))
    };
    for n in networks {
        if n.up == Some(false) {
            continue;
        }
        let Some(ip) = n.ipv4.first() else {
            continue;
        };
        let inv = find(&n.name);
        if inv.and_then(|a| a.connected) == Some(false) {
            continue;
        }
        let ip = ip.split('/').next().unwrap_or(ip);
        return card(Some(ip), inv);
    }
    let inv = adapters.iter().find(|a| {
        a.connected == Some(true)
            && (a.gateway.as_ref().is_some_and(|g| !g.is_empty())
                || a.dns.as_ref().is_some_and(|d| !d.is_empty()))
    });
    card(None, inv)
}

fn card(ip: Option<&str>, inv: Option<&super::super::health_model::NetAdapter>) -> Value {
    let list = |v: Option<&Vec<String>>| -> Vec<String> {
        v.map(|l| l.iter().take(4).cloned().collect()).unwrap_or_default()
    };
    json!({ "ip": {
        "ip": ip,
        "gateway": list(inv.and_then(|a| a.gateway.as_ref())),
        "dns": list(inv.and_then(|a| a.dns.as_ref())),
    }})
}
