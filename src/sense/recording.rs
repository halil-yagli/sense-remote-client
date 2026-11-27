//! Sense Remote (#136, after #114): the Controller's session recording, as the UI and the
//! diagnostics log see it.
//!
//! - The recording is "on" for the UI only when a file really opened (`started`), not when the
//!   switch was pressed (tarama B5: "Kayıt · Açık" while nothing was being written).
//! - It is `failed` when the Host does not allow recording (`izin_yok`), the folder or file could
//!   not be made (`klasor`, `dosya`) or the codec cannot be recorded (`kodek`); a failure stops
//!   the recording so the switch and the bar chip go back to off.
//! - When it stops, the note "Kaydedildi · Klasörü aç" comes after every file got its tail, with
//!   the first file so the file manager can show it selected; a recording that left no file says
//!   `empty` and leaves no empty folder behind.
//!
//! UI events (session window): `sense_record_state` {id, state = starting | started | failed |
//! stopped | empty, display, part, reason} and `sense_record_saved` {dir, file}. Diagnostics
//! (`record/*`) carry counts, sizes and codec only: no path, file name or computer name.
use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use hbb_common::log;
use scrap::record_sense::{self, SenseRecordEvent};
use serde_json::json;

use crate::{
    client::{Data, Interface},
    ui_session_interface::{InvokeUiSession, Session},
};

/// How long the "Kaydedildi" note waits for the files' tails at most.
const FINISH_WAIT: Duration = Duration::from_secs(10);
const FINISH_STEP: Duration = Duration::from_millis(100);

/// UI state and reason for a recorder event.
pub fn ui_state(e: &SenseRecordEvent) -> (&'static str, &'static str) {
    match e {
        SenseRecordEvent::Started { .. } => ("started", ""),
        SenseRecordEvent::Failed { reason } => ("failed", *reason),
    }
}

fn peer_id<T: InvokeUiSession>(session: &Session<T>) -> String {
    session.lc.read().unwrap().id.clone()
}

/// The switch was turned on or off (before anything is written): `starting` / `stopped`.
pub fn requested<T: InvokeUiSession>(session: &Session<T>, on: bool) {
    log_requested(on);
    let state = if on { "starting" } else { "stopped" };
    session.sense_record_state(&peer_id(session), state, 0, 0, "");
}

fn log_requested(on: bool) {
    crate::sense::diag::event("record", "istek", json!({ "acik": on }));
}

/// A display's recorder opened its file or cannot go on (video thread).
pub fn on_recorder_event<T: InvokeUiSession>(session: &Session<T>, display: usize, e: SenseRecordEvent) {
    let (state, reason) = ui_state(&e);
    let mut part = 1;
    match &e {
        SenseRecordEvent::Started {
            part: p,
            codec,
            width,
            height,
            ..
        } => {
            part = *p;
            crate::sense::diag::event(
                "record",
                "basladi",
                json!({ "ekran": display, "parca": p, "kodek": codec, "cozunurluk": format!("{width}x{height}") }),
            );
        }
        SenseRecordEvent::Failed { reason } => {
            log::warn!("record display #{display} failed: {reason}");
            crate::sense::diag::event("record", "basarisiz", json!({ "ekran": display, "neden": reason }));
            // Stop it the normal way, so the switch, the bar chip and the Host's "recording"
            // sign all go off together.
            session.send(Data::RecordScreen(false));
        }
    }
    session.sense_record_state(&peer_id(session), state, display, part, reason);
}

/// The switch was turned on but the Host does not allow recording (nothing will be written).
pub fn refused<T: InvokeUiSession>(session: &Session<T>) {
    crate::sense::diag::event("record", "basarisiz", json!({ "neden": "izin_yok" }));
    session.sense_record_state(&peer_id(session), "failed", 0, 0, "izin_yok");
}

/// Recording stopped: once every recorder of `folder` closed its file, say where the files are
/// (or that there are none). Runs on its own thread; the stop itself does not wait.
pub fn finish<T: InvokeUiSession>(session: Session<T>, folder: String) {
    let dir = PathBuf::from(crate::ui_interface::video_save_directory(false)).join(&folder);
    std::thread::spawn(move || {
        let start = Instant::now();
        while record_sense::open_recorders(&folder) > 0 && start.elapsed() < FINISH_WAIT {
            std::thread::sleep(FINISH_STEP);
        }
        let files = record_sense::finish_folder(&dir);
        report_finished(&session, &dir, &files);
    });
}

fn report_finished<T: InvokeUiSession>(session: &Session<T>, dir: &Path, files: &[PathBuf]) {
    let Some(first) = files.first() else {
        crate::sense::diag::event("record", "bos", json!({}));
        session.sense_record_state(&peer_id(session), "empty", 0, 0, "");
        return;
    };
    let bytes: u64 = files
        .iter()
        .filter_map(|f| std::fs::metadata(f).ok())
        .map(|m| m.len())
        .sum();
    crate::sense::diag::event(
        "record",
        "kaydedildi",
        json!({ "dosya": files.len(), "bayt": bytes }),
    );
    session.sense_record_saved(&dir.to_string_lossy(), &first.to_string_lossy());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_map_to_ui_states() {
        let started = SenseRecordEvent::Started {
            file: "x.mp4".into(),
            part: 1,
            codec: "H265".into(),
            width: 3840,
            height: 2160,
        };
        assert_eq!(ui_state(&started), ("started", ""));
        for reason in ["klasor", "dosya", "kodek"] {
            assert_eq!(ui_state(&SenseRecordEvent::Failed { reason }), ("failed", reason));
        }
    }

    // ---- scrap::record_sense (its crate's tests do not run in the CI) ----

    #[test]
    fn backwards_timestamp_continues_by_real_time() {
        use scrap::record_sense::continue_offset;
        // Last frame went out at 20 000 ms; the new encoder restarts at 0, 120 ms later.
        let off = continue_offset(20_000, 0, 120);
        assert_eq!(off, 20_120);
        // The following frames of the new encoder keep the same offset.
        assert_eq!(33 + off, 20_153);
        // No real time measured (same instant): still grows.
        let off = continue_offset(500, 10, 0);
        assert_eq!(10 + off, 501);
        // A restart that lands above zero.
        let off = continue_offset(9_000, 4_000, 40);
        assert_eq!(4_000 + off, 9_040);
    }

    fn temp_dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sense-rec-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn finished_folder_lists_files_in_order() {
        let d = temp_dir("order");
        let base = "Slayer_2026-11-27_03-52-04";
        for n in [
            format!("{base}_Ekran2.mp4"),
            format!("{base}_Ekran1_2.webm"),
            format!("{base}_Ekran1.mp4"),
            "not-a-recording.txt".to_owned(),
        ] {
            std::fs::write(d.join(n), b"x").unwrap();
        }
        let names: Vec<String> = record_sense::finish_folder(&d)
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        assert_eq!(
            names,
            vec![
                format!("{base}_Ekran1.mp4"),
                format!("{base}_Ekran1_2.webm"),
                format!("{base}_Ekran2.mp4"),
            ]
        );
        assert!(d.is_dir());
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn empty_folder_is_removed_other_content_stays() {
        let d = temp_dir("empty");
        assert!(record_sense::finish_folder(&d).is_empty());
        assert!(!d.exists());
        let d = temp_dir("other");
        std::fs::write(d.join("note.txt"), b"x").unwrap();
        assert!(record_sense::finish_folder(&d).is_empty());
        assert!(d.is_dir());
        std::fs::remove_dir_all(&d).ok();
    }

    // The v9 case (Slayer, 03:52): the Host rebuilt its encoder twice during one recording, the
    // timestamps went back to 0 and every restart opened a new file. Now one display = one file,
    // `Started` comes once, and the open count follows the recorder.
    #[test]
    fn host_encoder_restart_keeps_one_file_per_display() {
        use base::message_proto::{video_frame, EncodedVideoFrame, EncodedVideoFrames};
        use scrap::record::{Recorder, RecorderContext};

        let root = temp_dir("restart");
        let folder = "Slayer_2026-11-27_03-52-04".to_owned();
        let mut rec = Recorder::new(RecorderContext {
            server: false,
            id: "test".into(),
            dir: root.to_string_lossy().to_string(),
            display_idx: 1,
            camera: false,
            tx: None,
            sense_folder: Some(folder.clone()),
        })
        .unwrap();
        assert_eq!(record_sense::open_recorders(&folder), 1);
        let frame = |pts: i64, key: bool| {
            video_frame::Union::Vp9s(EncodedVideoFrames {
                frames: vec![EncodedVideoFrame {
                    data: vec![0u8; 32].into(),
                    key,
                    pts,
                    ..Default::default()
                }],
                ..Default::default()
            })
        };
        let mut started = 0;
        let mut feed = |rec: &mut Recorder, pts: i64, key: bool| {
            rec.write_frame(&frame(pts, key), 1920, 1080).ok();
            match rec.sense_take_event() {
                Some(SenseRecordEvent::Started { part, .. }) => {
                    assert_eq!(part, 1);
                    started += 1;
                }
                Some(e) => panic!("unexpected {e:?}"),
                None => {}
            }
        };
        for pts in [0, 33, 66, 100] {
            feed(&mut rec, pts, pts == 0);
        }
        // Encoder restart: timestamps from 0 again, a delta frame first (left out), then the key.
        feed(&mut rec, 0, false);
        feed(&mut rec, 5, true);
        feed(&mut rec, 38, false);
        // Second restart.
        feed(&mut rec, 0, true);
        feed(&mut rec, 33, false);
        assert_eq!(started, 1);
        let files = record_sense::saved_files(&root.join(&folder));
        assert_eq!(files.len(), 1, "{files:?}");
        assert!(files[0].to_string_lossy().ends_with("Slayer_2026-11-27_03-52-04_Ekran2.webm"));
        drop(rec);
        assert_eq!(record_sense::open_recorders(&folder), 0);
        // Under a second long: the stock rule removes the piece; the folder goes with it.
        assert!(record_sense::finish_folder(&root.join(&folder)).is_empty());
        assert!(!root.join(&folder).exists());
        std::fs::remove_dir_all(&root).ok();
    }

    // A size change is a new part in the same folder (a file cannot change its picture size).
    #[test]
    fn size_change_is_a_second_part() {
        use base::message_proto::{video_frame, EncodedVideoFrame, EncodedVideoFrames};
        use scrap::record::{Recorder, RecorderContext};

        let root = temp_dir("size");
        let folder = "PC_2026-11-27_10-00-00".to_owned();
        let mut rec = Recorder::new(RecorderContext {
            server: false,
            id: "test".into(),
            dir: root.to_string_lossy().to_string(),
            display_idx: 0,
            camera: false,
            tx: None,
            sense_folder: Some(folder.clone()),
        })
        .unwrap();
        let key = video_frame::Union::Vp9s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: vec![0u8; 32].into(),
                key: true,
                pts: 0,
                ..Default::default()
            }],
            ..Default::default()
        });
        rec.write_frame(&key, 1920, 1080).unwrap();
        assert!(matches!(rec.sense_take_event(), Some(SenseRecordEvent::Started { part: 1, .. })));
        rec.write_frame(&key, 2560, 1440).unwrap();
        assert!(matches!(rec.sense_take_event(), Some(SenseRecordEvent::Started { part: 2, .. })));
        let names: Vec<String> = record_sense::saved_files(&root.join(&folder))
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        // The first part was under a second and was removed when the second part began.
        assert_eq!(names, vec!["PC_2026-11-27_10-00-00_Ekran1_2.webm".to_owned()]);
        drop(rec);
        std::fs::remove_dir_all(&root).ok();
    }

    // The folder cannot be made (a file sits where it should be): `Failed { klasor }`, once.
    #[test]
    fn folder_that_cannot_be_made_fails_once() {
        use base::message_proto::{video_frame, EncodedVideoFrame, EncodedVideoFrames};
        use scrap::record::{Recorder, RecorderContext};

        let root = temp_dir("fail");
        let folder = "PC_2026-11-27_11-00-00".to_owned();
        std::fs::write(root.join(&folder), b"not a folder").unwrap();
        let mut rec = Recorder::new(RecorderContext {
            server: false,
            id: "test".into(),
            dir: root.to_string_lossy().to_string(),
            display_idx: 0,
            camera: false,
            tx: None,
            sense_folder: Some(folder.clone()),
        })
        .unwrap();
        let key = video_frame::Union::Vp9s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: vec![0u8; 32].into(),
                key: true,
                pts: 0,
                ..Default::default()
            }],
            ..Default::default()
        });
        assert!(rec.write_frame(&key, 1920, 1080).is_err());
        assert_eq!(rec.sense_take_event(), Some(SenseRecordEvent::Failed { reason: "klasor" }));
        assert!(rec.write_frame(&key, 1920, 1080).is_err());
        assert_eq!(rec.sense_take_event(), None);
        drop(rec);
        assert_eq!(record_sense::open_recorders(&folder), 0);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn diag_lines_are_valid_and_carry_no_path() {
        // The category / event names pass the log's rules (an invalid name is dropped silently).
        for k in ["istek", "basladi", "basarisiz", "bos", "kaydedildi"] {
            assert!(crate::sense::diag::line::is_kind(k), "{k}");
        }
        assert!(crate::sense::diag::line::is_category("record"));
        log_requested(true);
        let got = crate::sense::diag::sink::take();
        assert!(got.contains(&("record".to_owned(), "istek".to_owned())), "{got:?}");
    }
}
