//! Sense Remote (#103): one line of the event record, built and cleaned. Pure functions only
//! (tested): the writer, the reader and the panic hook all go through [`build_line`].
//!
//! Line (contract `Calisma/plan/2026-11-26_kayit-sozlesmesi.md` §1), one JSON object per line:
//! `{"t":<unix ms>,"c":"<category>","k":"<event>","p":"<process>","s":"<session|yok>", ...fields}`
//!
//! Privacy (K10/K11, never changes): every string goes through `log_upload::sanitize_line`
//! (passwords, tokens, keys, e-mail addresses, user folder names masked); a field with a secret
//! name (`is_secret_name`) keeps only `***`; fields that would carry content (screen, typed keys,
//! clipboard, chat, file content) are dropped whatever they hold. A setting whose name is secret
//! never shows its old or new value.

use crate::sense::log_upload::{is_secret_name, sanitize_line};
use serde_json::{Map, Value};

/// A line is at most this many bytes (UTF-8); longer field values are cut.
pub const MAX_LINE_BYTES: usize = 4096;
/// `s` when the event belongs to no session.
pub const NO_SESSION: &str = "yok";
/// Longest string kept in a field (characters); a line still too long keeps less.
const MAX_STRING_CHARS: usize = 512;
const SHORT_STRING_CHARS: usize = 96;
/// Nesting and list limits of a field value.
const MAX_DEPTH: usize = 4;
const MAX_ITEMS: usize = 32;
const MAX_FIELDS: usize = 48;
const MAX_FIELD_NAME: usize = 48;

/// Field names whose value is content and never goes into the record, whatever it holds.
const CONTENT_NAMES: [&str; 26] = [
    "text",
    "metin",
    "content",
    "icerik",
    "body",
    "govde",
    "clipboard",
    "pano",
    "message",
    "mesaj",
    "chat",
    "sohbet",
    "keys",
    "key_event",
    "keystroke",
    "tus",
    "tuslar",
    "screenshot",
    "ekran_goruntusu",
    "image",
    "frame",
    "frame_data",
    "file_content",
    "dosya_icerik",
    "data",
    "veri",
];

/// The value next to a setting name (`ad`) that names a secret is not written.
const VALUE_NAMES: [&str; 8] = ["eski", "yeni", "deger", "value", "old", "new", "onceki", "sonraki"];

/// Reserved names: a field cannot overwrite them.
const RESERVED: [&str; 5] = ["t", "c", "k", "p", "s"];

pub fn is_content_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    CONTENT_NAMES.contains(&lower.as_str())
}

/// `c`: lower-case letters and `_`, 1–16 (panel `CategoryParam`).
pub fn is_category(c: &str) -> bool {
    !c.is_empty() && c.len() <= 16 && c.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
}

/// `k`: `A-Za-z0-9_.-`, 1–48.
pub fn is_kind(k: &str) -> bool {
    !k.is_empty()
        && k.len() <= 48
        && k
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
}

/// `p`: lower-case letters, digits, `_`, `-`, 1–16.
pub fn is_process(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 16
        && p
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// `s`: a session id as the upload contract takes it (`A-Za-z0-9_-`, 1–64).
pub fn is_session(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn cut_chars(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.to_owned(),
    }
}

/// A field name as written: cleaned and short. `None` when nothing usable is left.
fn clean_name(name: &str) -> Option<String> {
    let name = sanitize_line(&cut_chars(name.trim(), MAX_FIELD_NAME));
    (!name.is_empty()).then_some(name)
}

/// A field value as written. `None` drops the field.
pub fn clean_value(name: &str, value: &Value, max_chars: usize, depth: usize) -> Option<Value> {
    if is_content_name(name) {
        return None;
    }
    if is_secret_name(name) {
        return Some(Value::String("***".to_owned()));
    }
    Some(match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        Value::String(text) => Value::String(sanitize_line(&cut_chars(text, max_chars))),
        Value::Array(items) => {
            if depth >= MAX_DEPTH {
                return Some(Value::String("…".to_owned()));
            }
            Value::Array(
                items
                    .iter()
                    .take(MAX_ITEMS)
                    .filter_map(|item| clean_value(name, item, max_chars, depth + 1))
                    .collect(),
            )
        }
        Value::Object(map) => {
            if depth >= MAX_DEPTH {
                return Some(Value::String("…".to_owned()));
            }
            Value::Object(clean_object(map, max_chars, depth + 1, &[]))
        }
    })
}

/// Whether the object names a secret setting (`ad` / `name` holds a secret name).
fn names_secret_setting(map: &Map<String, Value>) -> bool {
    ["ad", "name"].iter().any(|key| {
        map.get(*key)
            .and_then(Value::as_str)
            .is_some_and(is_secret_name)
    })
}

fn clean_object(map: &Map<String, Value>, max_chars: usize, depth: usize, skip: &[&str]) -> Map<String, Value> {
    let secret_setting = names_secret_setting(map);
    let mut out = Map::new();
    for (name, value) in map.iter() {
        if out.len() >= MAX_FIELDS {
            break;
        }
        if skip.contains(&name.as_str()) {
            continue;
        }
        let Some(clean) = clean_name(name) else {
            continue;
        };
        if secret_setting && VALUE_NAMES.contains(&name.to_ascii_lowercase().as_str()) {
            out.insert(clean, Value::String("***".to_owned()));
            continue;
        }
        if let Some(value) = clean_value(name, value, max_chars, depth) {
            out.insert(clean, value);
        }
    }
    out
}

/// The line of one event, or `None` when `c` / `k` are not valid names. `fields` that is not an
/// object goes in as `deger`. Never longer than [`MAX_LINE_BYTES`].
pub fn build_line(t_ms: i64, c: &str, k: &str, p: &str, s: Option<&str>, fields: &Value) -> Option<String> {
    if !is_category(c) || !is_kind(k) {
        return None;
    }
    let p = if is_process(p) { p } else { "bilinmiyor" };
    let s = s.filter(|s| is_session(s)).unwrap_or(NO_SESSION);
    let head = |out: &mut Map<String, Value>| {
        out.insert("t".to_owned(), Value::from(t_ms.max(0)));
        out.insert("c".to_owned(), Value::from(c));
        out.insert("k".to_owned(), Value::from(k));
        out.insert("p".to_owned(), Value::from(p));
        out.insert("s".to_owned(), Value::from(s));
    };
    for max_chars in [MAX_STRING_CHARS, SHORT_STRING_CHARS] {
        let mut out = match fields {
            Value::Object(map) => clean_object(map, max_chars, 0, &RESERVED),
            Value::Null => Map::new(),
            other => {
                let mut map = Map::new();
                if let Some(value) = clean_value("deger", other, max_chars, 0) {
                    map.insert("deger".to_owned(), value);
                }
                map
            }
        };
        head(&mut out);
        let line = Value::Object(out).to_string();
        if line.len() <= MAX_LINE_BYTES {
            return Some(line);
        }
    }
    let mut out = Map::new();
    head(&mut out);
    out.insert("kirpildi".to_owned(), Value::Bool(true));
    Some(Value::Object(out).to_string())
}

/// A line read back from a file (written by any process of this computer, any version): parsed,
/// checked and cleaned again. `(t, line)`, or `None` for a line that is not an event.
pub fn clean_event_line(line: &str) -> Option<(i64, String)> {
    let line = line.trim();
    if line.is_empty() || line.len() > MAX_LINE_BYTES * 2 {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    let map = value.as_object()?;
    let t = map.get("t")?.as_i64().filter(|t| *t >= 0)?;
    let c = map.get("c")?.as_str()?;
    let k = map.get("k")?.as_str()?;
    let p = map.get("p").and_then(Value::as_str).unwrap_or("bilinmiyor");
    let s = map.get("s").and_then(Value::as_str);
    let fields = Value::Object(map.clone());
    build_line(t, c, k, p, s, &fields).map(|line| (t, line))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(line: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(line).unwrap().as_object().unwrap().clone()
    }

    #[test]
    fn line_has_the_contract_head_and_fields() {
        let line = build_line(
            1_764_150_000_123,
            "conn",
            "punch",
            "client",
            Some("c1764150000-0"),
            &json!({"deneme": 1, "yontem": "udp", "hedef": "wan", "sonuc": "basarisiz", "ms": 830}),
        )
        .unwrap();
        let m = parse(&line);
        assert_eq!(m["t"], json!(1_764_150_000_123i64));
        assert_eq!(m["c"], json!("conn"));
        assert_eq!(m["k"], json!("punch"));
        assert_eq!(m["p"], json!("client"));
        assert_eq!(m["s"], json!("c1764150000-0"));
        assert_eq!(m["yontem"], json!("udp"));
        assert_eq!(m["ms"], json!(830));
        assert!(!line.contains('\n'));
    }

    #[test]
    fn no_session_and_bad_names() {
        let m = parse(&build_line(1, "sys", "load", "server", None, &json!({})).unwrap());
        assert_eq!(m["s"], json!("yok"));
        let m = parse(&build_line(1, "sys", "load", "server", Some("bad id!"), &json!({})).unwrap());
        assert_eq!(m["s"], json!("yok"));
        let m = parse(&build_line(1, "sys", "load", "Bad Proc", None, &json!({})).unwrap());
        assert_eq!(m["p"], json!("bilinmiyor"));
        assert!(build_line(1, "Conn", "x", "server", None, &json!({})).is_none());
        assert!(build_line(1, "conn", "", "server", None, &json!({})).is_none());
        assert!(build_line(1, "conn", "a b", "server", None, &json!({})).is_none());
        assert!(build_line(1, "averyveryverylongcategory", "x", "server", None, &json!({})).is_none());
    }

    #[test]
    fn fields_cannot_overwrite_the_head() {
        let m = parse(&build_line(5, "ui", "button", "main", None, &json!({"t": 9, "c": "x", "s": "h1", "ad": "kaydet"})).unwrap());
        assert_eq!(m["t"], json!(5));
        assert_eq!(m["c"], json!("ui"));
        assert_eq!(m["s"], json!("yok"));
        assert_eq!(m["ad"], json!("kaydet"));
    }

    #[test]
    fn secrets_are_masked_in_names_and_values() {
        let line = build_line(
            1,
            "ui",
            "setting",
            "main",
            None,
            &json!({
                "password": "hunter2",
                "api_token": {"a": 1},
                "not": "password=hunter2 user ayse@example.com",
                "yol": "C:\\Users\\Ayse\\AppData",
                "uzun": "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0UvWx",
            }),
        )
        .unwrap();
        assert!(!line.contains("hunter2"), "{line}");
        assert!(!line.contains("ayse@example.com"), "{line}");
        assert!(!line.contains("Ayse"), "{line}");
        assert!(!line.contains("A1b2C3d4E5f6G7h8I9j0"), "{line}");
        let m = parse(&line);
        assert_eq!(m["password"], json!("***"));
        assert_eq!(m["api_token"], json!("***"));
    }

    #[test]
    fn a_secret_setting_shows_no_old_or_new_value() {
        let m = parse(&build_line(1, "ui", "setting", "main", None, &json!({"ad": "permanent-password", "eski": "abc", "yeni": "def"})).unwrap());
        assert_eq!(m["eski"], json!("***"));
        assert_eq!(m["yeni"], json!("***"));
        let m = parse(&build_line(1, "ui", "setting", "main", None, &json!({"ad": "image-quality", "eski": "balanced", "yeni": "best"})).unwrap());
        assert_eq!(m["eski"], json!("balanced"));
        assert_eq!(m["yeni"], json!("best"));
    }

    #[test]
    fn content_never_goes_in() {
        let line = build_line(
            1,
            "ui",
            "chat",
            "cm",
            None,
            &json!({
                "text": "gizli sohbet",
                "mesaj": "merhaba",
                "clipboard": "pano icerigi",
                "keys": ["a", "b"],
                "screenshot": "iVBOR",
                "dosya_icerik": "...",
                "ic": {"icerik": "x", "sayi": 3},
                "sayi": 2,
            }),
        )
        .unwrap();
        for word in ["gizli sohbet", "merhaba", "pano icerigi", "iVBOR", "\"keys\"", "\"icerik\""] {
            assert!(!line.contains(word), "{word} in {line}");
        }
        let m = parse(&line);
        assert_eq!(m["sayi"], json!(2));
        assert_eq!(m["ic"]["sayi"], json!(3));
    }

    #[test]
    fn long_lines_are_cut_to_the_limit() {
        let big = "x ".repeat(5000);
        let line = build_line(1, "error", "flutter", "main", None, &json!({"hata": big, "yigin": big})).unwrap();
        assert!(line.len() <= MAX_LINE_BYTES);
        assert!(line.contains("hata"));
        let many: Map<String, Value> = (0..200).map(|n| (format!("alan{n}"), json!("y ".repeat(200)))).collect();
        let line = build_line(1, "error", "flutter", "main", None, &Value::Object(many)).unwrap();
        assert!(line.len() <= MAX_LINE_BYTES, "{}", line.len());
        let m = parse(&line);
        assert_eq!(m["c"], json!("error"));
    }

    #[test]
    fn deep_values_and_non_objects() {
        let m = parse(&build_line(1, "ui", "x", "main", None, &json!({"a": {"b": {"c": {"d": {"e": {"f": 1}}}}}})).unwrap());
        assert_eq!(m["a"]["b"]["c"]["d"]["e"], json!("…"));
        let m = parse(&build_line(1, "ui", "x", "main", None, &json!("duz deger")).unwrap());
        assert_eq!(m["deger"], json!("duz deger"));
        let m = parse(&build_line(1, "ui", "x", "main", None, &Value::Null).unwrap());
        assert_eq!(m.len(), 5);
    }

    #[test]
    fn lines_read_back_are_checked_and_cleaned_again() {
        let (t, line) = clean_event_line(r#"{"t":7,"c":"conn","k":"rtt","p":"client","s":"yok","ms":180}"#).unwrap();
        assert_eq!(t, 7);
        assert_eq!(parse(&line)["ms"], json!(180));
        // An old or foreign writer: the secret is masked on the way out.
        let (_, line) = clean_event_line(r#"{"t":7,"c":"ui","k":"x","p":"main","s":"yok","token":"abc","not":"pwd=1234"}"#).unwrap();
        assert!(!line.contains("abc") && !line.contains("1234"), "{line}");
        for bad in ["", "not json", "[1,2]", r#"{"c":"ui","k":"x"}"#, r#"{"t":-1,"c":"ui","k":"x"}"#, r#"{"t":1,"c":"UI","k":"x"}"#, r#"{"t":1.5,"c":"ui","k":"x"}"#] {
            assert!(clean_event_line(bad).is_none(), "{bad}");
        }
        // Idempotent: cleaning a clean line changes nothing.
        let first = build_line(3, "ui", "x", "main", None, &json!({"yol": "/Users/ayse/x", "e": "a@b.co"})).unwrap();
        assert_eq!(clean_event_line(&first).unwrap().1, first);
    }
}
