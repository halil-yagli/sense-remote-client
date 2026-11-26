//! Sense Remote (#103): named events of the contract (§1), so callers in other modules write one
//! line and the field names stay the same everywhere. Some are used by later work (connection
//! quality, update) and are not called from this crate yet.
#![allow(dead_code)]

use serde_json::{json, Value};

// ---------------------------------------------------------------------------------------------
// conn
// ---------------------------------------------------------------------------------------------

/// `conn/path`: how the connection goes. `yol` = `direct` | `relay` | `lan`.
pub fn conn_path(yol: &str, akis: &str, nat: Option<&str>, relay: Option<&str>) {
    super::event("conn", "path", json!({ "yol": yol, "akis": akis, "nat": nat, "relay": relay }));
}

/// `conn/punch`: one hole-punching attempt. `yontem` = `udp` | `tcp` | `ipv6`, `hedef` = `lan` |
/// `wan`, `sonuc` = `basarili` | `basarisiz` | `zaman_asimi` …
pub fn conn_punch(deneme: u32, yontem: &str, hedef: &str, sonuc: &str, ms: u64) {
    super::event(
        "conn",
        "punch",
        json!({ "deneme": deneme, "yontem": yontem, "hedef": hedef, "sonuc": sonuc, "ms": ms }),
    );
}

/// `conn/reconnect` with its reason.
pub fn conn_reconnect(neden: &str) {
    super::event("conn", "reconnect", json!({ "neden": neden }));
}

/// `conn/drop`: an open connection ended without being closed from this side (`akis_hatasi`,
/// `karsi_kapatti`, `karsi_yeniden_basliyor`, `zaman_asimi_30sn` …).
pub fn conn_drop(neden: &str, hata: Option<&str>) {
    super::event("conn", "drop", json!({ "neden": neden, "hata": hata }));
}

/// `conn/fail`: the connection could not be made (error text cleaned like every field).
pub fn conn_fail(hata: &str) {
    super::event("conn", "fail", json!({ "hata": hata }));
}

/// NAT type as the rendezvous reports it (`Config::get_nat_type`, `NatType`).
pub fn nat_name(nat: i32) -> &'static str {
    match nat {
        1 => "asymmetric",
        2 => "symmetric",
        _ => "unknown",
    }
}

// ---------------------------------------------------------------------------------------------
// video
// ---------------------------------------------------------------------------------------------

/// `video/encoder`: `olay` = `kuruldu` | `hata` | `yeniden` …
pub fn video_encoder(olay: &str, kodek: &str, donanim: bool, hata: Option<&str>) {
    super::event(
        "video",
        "encoder",
        json!({ "olay": olay, "kodek": kodek, "donanim": donanim, "hata": hata }),
    );
}

/// `video/decoder`: `olay` = `kuruldu` | `hata` …
pub fn video_decoder(olay: &str, kodek: &str, donanim: bool, hata: Option<&str>) {
    super::event(
        "video",
        "decoder",
        json!({ "olay": olay, "kodek": kodek, "donanim": donanim, "hata": hata }),
    );
}

/// `video/capture`: capture method (`dxgi`, `gdi`, `wgc`, `cg`, `sck` …) and display size.
pub fn video_capture(yontem: &str, ekran: usize, genislik: usize, yukseklik: usize) {
    super::event(
        "video",
        "capture",
        json!({ "yontem": yontem, "ekran": ekran, "cozunurluk": format!("{genislik}x{yukseklik}") }),
    );
}

/// `video/keyframe_req` with its reason (`kuyruk_dolu`, `gecikme`, `cozucu_hatasi` …).
pub fn keyframe_req(neden: &str, ekran: usize) {
    super::event("video", "keyframe_req", json!({ "neden": neden, "ekran": ekran }));
}

// ---------------------------------------------------------------------------------------------
// update (U package)
// ---------------------------------------------------------------------------------------------

/// `update/state`: a state change of the updater.
pub fn update_state(eski: &str, yeni: &str) {
    super::event("update", "state", json!({ "eski": eski, "yeni": yeni }));
}

/// `update/wait`: why the update waits (`incoming_connection`, `outgoing_session_marker` …).
pub fn update_wait(neden: &str) {
    super::event("update", "wait", json!({ "neden": neden }));
}

// ---------------------------------------------------------------------------------------------
// Controller session: login and the five-second statistics (src/client/io_loop.rs)
// ---------------------------------------------------------------------------------------------

/// `conn/login`: the Host's platform, version and displays (sizes only).
pub fn peer_info(pi: &base::message_proto::PeerInfo) {
    let ekranlar: Vec<Value> = pi
        .displays
        .iter()
        .map(|d| {
            json!({
                "cozunurluk": format!("{}x{}", d.width, d.height),
                "olcek": d.scale,
                "cevrimici": d.online,
            })
        })
        .collect();
    super::event(
        "conn",
        "login",
        json!({
            "karsi_platform": pi.platform,
            "karsi_surum": pi.version,
            "ekranlar": ekranlar,
            "gecerli_ekran": pi.current_display,
        }),
    );
}

/// What one status tick (once a second) of a Controller session measured.
#[derive(Debug, Clone, Default)]
pub struct Tick {
    /// Frames shown in the last second, summed over the displays.
    pub fps: i32,
    /// Bytes received in the last second.
    pub bytes_per_s: usize,
    pub codec: Option<String>,
    pub chroma: Option<String>,
    pub last_frame_ms: Option<i64>,
    pub loss: Option<f32>,
    pub direct: bool,
    pub stream: String,
    /// Image quality setting of the session (`balanced`, `best`, `low`, `custom`).
    pub quality: String,
}

/// Seconds averaged into one `video/stats` line.
pub const STATS_EVERY: u32 = 5;

/// Five seconds of a Controller session: averages for `video/stats`, the latest round trip for
/// `conn/rtt`, frames dropped by the full decode queue, and `conn/path` once at the start.
#[derive(Debug, Default)]
pub struct StatsWindow {
    seconds: u32,
    fps_sum: i64,
    fps_min: Option<i32>,
    bytes: u64,
    worst_frame_ms: Option<i64>,
    dropped: u32,
    rtt_ms: Option<u32>,
    path_sent: bool,
}

impl StatsWindow {
    /// A delay probe answer (`TestDelay.last_delay`, the round trip in ms the Host measured).
    pub fn on_rtt(&mut self, ms: u32) {
        self.rtt_ms = Some(ms);
    }

    /// The decode queue was full and a frame was dropped (a refresh is asked for).
    pub fn on_drop(&mut self) {
        self.dropped = self.dropped.saturating_add(1);
    }

    /// One second; returns the events due now (pure).
    pub fn tick(&mut self, tick: &Tick, nat: &str) -> Vec<(&'static str, &'static str, Value)> {
        let mut out = Vec::new();
        if !self.path_sent {
            self.path_sent = true;
            out.push((
                "conn",
                "path",
                json!({
                    "yol": if tick.direct { "direct" } else { "relay" },
                    "akis": tick.stream,
                    "nat": nat,
                }),
            ));
        }
        self.seconds += 1;
        self.fps_sum += tick.fps as i64;
        self.fps_min = Some(self.fps_min.map_or(tick.fps, |m| m.min(tick.fps)));
        self.bytes += tick.bytes_per_s as u64;
        if let Some(ms) = tick.last_frame_ms {
            self.worst_frame_ms = Some(self.worst_frame_ms.map_or(ms, |w| w.max(ms)));
        }
        if self.seconds < STATS_EVERY {
            return out;
        }
        let seconds = self.seconds as i64;
        out.push((
            "video",
            "stats",
            json!({
                "fps": ((self.fps_sum as f64 / seconds as f64) * 10.0).round() / 10.0,
                "fps_en_az": self.fps_min,
                "kbps": (self.bytes * 8 / 1000) / seconds as u64,
                "kodek": tick.codec,
                "kroma": tick.chroma,
                "kalite": tick.quality,
                "atlanan": self.dropped,
                "son_kare_ms": self.worst_frame_ms,
                "kayip": tick.loss.map(|l| ((l as f64) * 10.0).round() / 10.0),
                "yol": if tick.direct { "direct" } else { "relay" },
            }),
        ));
        if let Some(ms) = self.rtt_ms {
            out.push(("conn", "rtt", json!({ "ms": ms })));
        }
        let (rtt, path_sent) = (self.rtt_ms, self.path_sent);
        *self = StatsWindow {
            rtt_ms: rtt,
            path_sent,
            ..Default::default()
        };
        out
    }
}

/// One status tick of a Controller session: records what is due.
pub fn controller_tick(window: &mut StatsWindow, tick: &Tick) {
    let nat = nat_name(hbb_common::config::Config::get_nat_type());
    for (c, k, fields) in window.tick(tick, nat) {
        super::event(c, k, fields);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tick(fps: i32, bytes: usize, last: Option<i64>) -> Tick {
        Tick {
            fps,
            bytes_per_s: bytes,
            codec: Some("H265".to_owned()),
            chroma: Some("4:2:0".to_owned()),
            last_frame_ms: last,
            loss: Some(2.04),
            direct: false,
            stream: "TCP".to_owned(),
            quality: "balanced".to_owned(),
        }
    }

    #[test]
    fn five_seconds_make_one_stats_line_and_a_round_trip() {
        let mut w = StatsWindow::default();
        let first = w.tick(&tick(20, 125_000, Some(30)), "symmetric");
        assert_eq!(first.len(), 1);
        assert_eq!((first[0].0, first[0].1), ("conn", "path"));
        assert_eq!(first[0].2["yol"], "relay");
        assert_eq!(first[0].2["nat"], "symmetric");
        w.on_rtt(180);
        w.on_drop();
        w.on_drop();
        for (fps, last) in [(10, 40), (30, 1400), (20, 20)] {
            assert!(w.tick(&tick(fps, 125_000, Some(last)), "symmetric").is_empty());
        }
        let due = w.tick(&tick(20, 125_000, None), "symmetric");
        assert_eq!(due.len(), 2);
        let (c, k, stats) = &due[0];
        assert_eq!((*c, *k), ("video", "stats"));
        assert_eq!(stats["fps"], 20.0);
        assert_eq!(stats["fps_en_az"], 10);
        assert_eq!(stats["kbps"], 1000);
        assert_eq!(stats["atlanan"], 2);
        assert_eq!(stats["son_kare_ms"], 1400);
        assert_eq!(stats["kodek"], "H265");
        assert_eq!(stats["kayip"], 2.0);
        assert_eq!(due[1].2["ms"], 180);
        // The next window starts clean but keeps the last round trip; no second path line.
        for _ in 0..4 {
            assert!(w.tick(&tick(30, 0, None), "symmetric").is_empty());
        }
        let due = w.tick(&tick(30, 0, None), "symmetric");
        assert_eq!(due[0].2["atlanan"], 0);
        assert_eq!(due[0].2["fps"], 30.0);
        assert!(due[0].2["son_kare_ms"].is_null());
        assert_eq!(due[1].2["ms"], 180);
    }

    #[test]
    fn no_round_trip_before_a_probe() {
        let mut w = StatsWindow::default();
        let mut all = Vec::new();
        for _ in 0..STATS_EVERY {
            all.extend(w.tick(&tick(1, 1, None), "unknown"));
        }
        assert!(all.iter().all(|(_, k, _)| *k != "rtt"));
    }

    #[test]
    fn nat_names() {
        assert_eq!(nat_name(0), "unknown");
        assert_eq!(nat_name(1), "asymmetric");
        assert_eq!(nat_name(2), "symmetric");
    }

    #[test]
    fn stats_lines_are_valid_events() {
        let mut w = StatsWindow::default();
        let mut all = Vec::new();
        w.on_rtt(5);
        for _ in 0..STATS_EVERY {
            all.extend(w.tick(&tick(25, 50_000, Some(10)), "unknown"));
        }
        for (c, k, fields) in all {
            let line = crate::sense::diag::line::build_line(1, c, k, "client", Some("c1-0"), &fields).unwrap();
            assert!(crate::sense::diag::line::clean_event_line(&line).is_some(), "{line}");
        }
    }
}
