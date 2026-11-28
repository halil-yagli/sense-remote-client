// Sense Remote (Sürüm 12, #169, FAV-Ç): the preference store client, pure parts.
use super::*;

fn cached(os: &str, key: &str, value: Value, rev: u64) -> Cached {
    Cached {
        os: os.to_owned(),
        key: key.to_owned(),
        value,
        rev,
        updated_at: "2026-11-28T10:00:00.000Z".to_owned(),
    }
}

fn w(os: &str, key: &str, value: Value) -> (String, String, Value) {
    (os.to_owned(), key.to_owned(), value)
}

#[test]
fn keys_and_systems_match_the_panel() {
    assert!(key_os_ok("win", "fav.items"));
    assert!(key_os_ok("linux", "fav.recent"));
    assert!(key_os_ok("any", "view.quality"));
    assert!(!key_os_ok("any", "fav.items"));
    assert!(!key_os_ok("win", "view.scale"));
    assert!(!key_os_ok("win", "window.position"));
    assert!(!os_ok("android"));
}

#[test]
fn set_body_is_checked_before_it_is_kept() {
    let ok = parse_set(r#"{"entries":[{"os":"win","key":"fav.items","value":[{"id":"win.taskmgr","key":1}]}]}"#).unwrap();
    assert_eq!(ok.len(), 1);
    for bad in [
        "nope",
        r#"{"entries":[]}"#,
        r#"{"entries":[{"os":"any","key":"fav.items","value":[]}]}"#,
        r#"{"entries":[{"os":"win","key":"secret.token","value":"x"}]}"#,
        r#"{"entries":[{"os":"win","key":"fav.items"}]}"#,
        r#"{"entries":[{"os":"win","key":"fav.items","value":[]},{"os":"win","key":"fav.items","value":[]}]}"#,
    ] {
        assert_eq!(parse_set(bad), Err("invalid"), "{bad}");
    }
    let big = format!(r#"{{"entries":[{{"os":"any","key":"keys.bindings","value":"{}"}}]}}"#, "x".repeat(MAX_VALUE_BYTES));
    assert_eq!(parse_set(&big), Err("invalid"));
    let many: Vec<String> = (0..17).map(|_| r#"{"os":"any","key":"view.scale","value":{}}"#.to_owned()).collect();
    assert_eq!(parse_set(&format!(r#"{{"entries":[{}]}}"#, many.join(","))), Err("invalid"));
}

#[test]
fn an_offline_write_shows_at_once_and_is_sent_with_its_base_rev_later() {
    let mut c = Cache::default();
    c.entries.push(cached("win", "fav.items", json!([]), 3));
    c.entries.push(cached("any", "view.quality", json!({"mode": "best"}), 1));
    c.entries.push(cached("mac", "fav.items", json!([{"id": "mac.finder", "key": null}]), 2));
    // Offline: kept in the queue, the view already shows it.
    c.stage(vec![w("win", "fav.items", json!([{"id": "win.taskmgr", "key": 1}]))]);
    c.stage(vec![w("win", "fav.recent", json!(["win.taskmgr"]))]);
    let view = c.view("win");
    let entries = view["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 3, "win + any + the new recent, not mac");
    assert!(entries.iter().any(|e| e["key"] == "fav.items" && e["value"][0]["id"] == "win.taskmgr"));
    // A second write of the same slot keeps the first base_rev.
    c.stage(vec![w("win", "fav.items", json!([{"id": "win.explorer", "key": null}]))]);
    let (sent, body) = put_body(&c.pending);
    assert_eq!(sent.len(), 2);
    assert_eq!(body["entries"][0]["base_rev"], 3);
    assert_eq!(body["entries"][1]["base_rev"], 0);
    assert_eq!(body["entries"][0]["value"][0]["id"], "win.explorer");
    // Back online: 200.
    c.apply_put_ok(&sent, &[("win".into(), "fav.items".into(), 4), ("win".into(), "fav.recent".into(), 1)]);
    assert!(c.pending.is_empty());
    assert_eq!(c.rev_of("win", "fav.items"), 4);
    assert_eq!(c.rev_of("win", "fav.recent"), 1);
}

#[test]
fn a_write_made_while_sending_stays_on_top_of_the_new_revision() {
    let mut c = Cache::default();
    c.stage(vec![w("any", "view.ghost_start", json!(true))]);
    let (sent, _) = put_body(&c.pending);
    c.stage(vec![w("any", "view.ghost_start", json!(false))]);
    c.apply_put_ok(&sent, &[("any".into(), "view.ghost_start".into(), 1)]);
    assert_eq!(c.pending.len(), 1);
    assert_eq!(c.pending[0].base_rev, 1);
    assert_eq!(c.pending[0].value, json!(false));
}

#[test]
fn on_409_the_panel_wins_where_it_moved_and_the_rest_is_sent_again() {
    let mut c = Cache::default();
    c.entries.push(cached("win", "fav.items", json!([]), 3));
    c.entries.push(cached("any", "view.scale", json!({"mode": "fit"}), 2));
    c.stage(vec![
        w("win", "fav.items", json!([{"id": "win.cmd", "key": null}])),
        w("any", "view.scale", json!({"mode": "original"})),
    ]);
    let (sent, _) = put_body(&c.pending);
    let answer = parse_put(
        409,
        r#"{"error":"rev_conflict","current":[
            {"os":"win","key":"fav.items","value":[{"id":"win.ps","key":2}],"rev":5,"updated_at":"2026-11-28T11:00:00.000Z"},
            {"os":"any","key":"view.scale","value":{"mode":"fit"},"rev":2,"updated_at":"2026-11-28T09:00:00.000Z"}]}"#,
    );
    let PutAnswer::Conflict(current) = answer else {
        panic!("not a conflict: {answer:?}");
    };
    assert!(c.apply_conflict(&sent, current));
    // fav.items moved on the panel (another computer): the panel value, local write dropped.
    assert_eq!(c.rev_of("win", "fav.items"), 5);
    assert_eq!(c.view("win")["entries"].as_array().unwrap().iter().find(|e| e["key"] == "fav.items").unwrap()["value"][0]["id"], "win.ps");
    // view.scale did not move: still pending, sent again.
    assert_eq!(c.pending.len(), 1);
    assert_eq!(c.pending[0].key, "view.scale");
}

#[test]
fn panel_answers_are_read_strictly() {
    assert_eq!(parse_put(400, r#"{"error":"invalid"}"#), PutAnswer::Invalid);
    assert_eq!(parse_put(401, r#"{"error":"token_invalid"}"#), PutAnswer::Later);
    assert_eq!(parse_put(429, ""), PutAnswer::Later);
    assert_eq!(parse_put(409, r#"{"error":"too_many"}"#), PutAnswer::Later);
    assert_eq!(
        parse_put(200, r#"{"entries":[{"os":"win","key":"fav.items","rev":2}]}"#),
        PutAnswer::Ok(vec![("win".into(), "fav.items".into(), 2)])
    );
    let (entries, custom) = parse_get(
        200,
        r#"{"entries":[
            {"os":"win","key":"fav.items","value":[],"rev":1,"updated_at":"2026-11-28T10:00:00.000Z"},
            {"os":"win","key":"later.key","value":1,"rev":1,"updated_at":"2026-11-28T10:00:00.000Z"}],
           "custom":[{"id":"custom:0b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b","os":"win","label":"Oynatıcı","kind":"program","scope":"device"}]}"#,
    )
    .unwrap();
    assert_eq!(entries.len(), 1, "an unknown key from a newer panel is left out");
    assert_eq!(custom.len(), 1);
    assert!(parse_get(401, "{}").is_none());
    assert!(parse_get(200, r#"{"error":"x"}"#).is_none());
}

#[test]
fn a_panel_read_replaces_only_its_systems_slots() {
    let mut c = Cache::default();
    c.entries.push(cached("mac", "fav.items", json!([]), 1));
    c.entries.push(cached("win", "fav.items", json!([]), 1));
    c.custom.push(json!({"id": "custom:a", "os": "mac", "label": "x"}));
    let changed = c.apply_get(
        "win",
        vec![cached("win", "fav.items", json!([{"id": "win.cmd", "key": null}]), 2), cached("any", "view.quality", json!({"mode": "low"}), 1)],
        vec![json!({"id": "custom:b", "os": "win", "label": "y"})],
    );
    assert!(changed);
    assert_eq!(c.rev_of("mac", "fav.items"), 1, "the Mac list is not touched");
    assert_eq!(c.rev_of("win", "fav.items"), 2);
    assert_eq!(c.custom.len(), 2);
    assert_eq!(c.view("win")["custom"].as_array().unwrap().len(), 1);
    // The same answer again changes nothing (no event).
    let again = c.apply_get(
        "win",
        vec![cached("win", "fav.items", json!([{"id": "win.cmd", "key": null}]), 2), cached("any", "view.quality", json!({"mode": "low"}), 1)],
        vec![json!({"id": "custom:b", "os": "win", "label": "y"})],
    );
    assert!(!again);
}

#[test]
fn two_employees_have_separate_cache_files_without_their_address_in_the_name() {
    let a = cache_name("ayse@example.test");
    let b = cache_name("mehmet@example.test");
    assert_ne!(a, b);
    assert_eq!(a, cache_name("  AYSE@example.test "));
    for name in [&a, &b] {
        assert!(name.starts_with(CACHE_PREFIX) && name.ends_with(CACHE_SUFFIX));
        assert!(!name.contains('@') && !name.contains("ayse") && !name.contains("mehmet"));
    }
    // The cache holds preferences only.
    let mut c = Cache::default();
    c.stage(vec![w("any", "view.ghost_start", json!(true))]);
    let text = serde_json::to_string(&c).unwrap();
    assert!(!text.contains("token") && !text.contains("access"));
}

#[test]
fn old_view_settings_move_once_only_where_the_account_is_empty() {
    let empty = Cache::default();
    assert_eq!(
        migration(&empty, "custom", "24", "original"),
        vec![
            w("any", "view.quality", json!({"mode": "custom", "fps": 24})),
            w("any", "view.scale", json!({"mode": "original"})),
        ]
    );
    assert_eq!(migration(&empty, "balanced", "", "adaptive")[1], w("any", "view.scale", json!({"mode": "fit"})));
    assert!(migration(&empty, "custom", "500", "custom").is_empty());
    let mut has = Cache::default();
    has.entries.push(cached("any", "view.quality", json!({"mode": "best"}), 1));
    has.stage(vec![w("any", "view.scale", json!({"mode": "fit"}))]);
    assert!(migration(&has, "low", "", "original").is_empty());
}

#[test]
fn custom_request_keeps_the_contract_and_maps_this_computer_to_device() {
    let body = custom_body(r#"{"os":"win","kind":"program","label":"Oynatıcı","target":"C:\\Sergi\\oynatici.exe","scope":"person","scope_ref":"123456789"}"#).unwrap();
    assert_eq!(body["scope"], "device");
    assert_eq!(body["scope_ref"], "123456789");
    let person = custom_body(r#"{"os":"win","kind":"url","label":"Durum","target":"https://example.test","scope":"person"}"#).unwrap();
    assert_eq!(person, json!({"os":"win","kind":"url","label":"Durum","target":"https://example.test","scope":"person"}));
    for bad in [
        r#"{"os":"win","kind":"program","label":"x","target":"C:\\a.exe -x","scope":"all"}"#,
        r#"{"os":"win","kind":"url","label":"x","target":"http://e.test","scope":"all"}"#,
        r#"{"os":"win","kind":"program","label":"x","target":"C:\\a.exe","scope":"project"}"#,
        r#"{"os":"win","kind":"script","label":"x","target":"C:\\a.exe","scope":"all"}"#,
        "[]",
    ] {
        assert_eq!(custom_body(bad), Err("invalid"), "{bad}");
    }
    assert_eq!(
        custom_answer(202, r#"{"id":"custom:0b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b","status":"pending"}"#),
        json!({"id":"custom:0b6f0c1e-1d2a-4f3b-9a1e-2c3d4e5f6a7b","status":"pending"})
    );
    assert_eq!(custom_answer(409, r#"{"error":"too_many"}"#), json!({"error": "too_many"}));
    assert_eq!(custom_answer(500, "oops"), json!({"error": "panel_error"}));
}
