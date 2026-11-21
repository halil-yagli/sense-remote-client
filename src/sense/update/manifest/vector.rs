// Sense Remote: the panel and the client must reach the same result on the same bytes.
// `release-v1.json` is made by the panel (`packages/shared/scripts/make-release-vector.ts`) with
// test keys whose ids are refused everywhere (`keys::TEST_VECTOR_KEY_IDS`); it holds public data
// only. Copied byte for byte: update both repositories in the same change (plan §3.12).

use super::*;
use crate::sense::{
    envelope_keys::parse_keys,
    update::order::{self, ORDER_TTL_S, UPDATE_ORDER_SIGNING_PREFIX},
};

const VECTOR: &str = include_str!("../../testdata/release-v1.json");

fn vector() -> Value {
    serde_json::from_str(VECTOR).expect("release-v1.json is valid JSON")
}

fn str_of<'a>(value: &'a Value, field: &str) -> &'a str {
    value[field]
        .as_str()
        .unwrap_or_else(|| panic!("{field} is a string"))
}

/// Through the `SENSE_ENVELOPE_KEYS` format, which also proves both sides derive `k` alike.
fn keys_of(list: &Value) -> Vec<TrustedKey> {
    let entries: Vec<String> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|key| format!("{}={}", str_of(key, "k"), str_of(key, "public_key")))
        .collect();
    parse_keys(&entries.join(",")).expect("vector keys parse")
}

/// A held release as the vector gives it (`{version, platform, sha256}` or `null`), valid
/// until the end of time so that only `order::verify`'s own rules decide.
fn held_release(value: &Value) -> Option<Release> {
    if value.is_null() {
        return None;
    }
    Some(Release {
        k: String::new(),
        version: value["version"].as_u64().unwrap() as u32,
        platform: str_of(value, "platform").to_owned(),
        file: String::new(),
        url: String::new(),
        sha256: str_of(value, "sha256").to_owned(),
        size: 1,
        notes_url: None,
        published_at: 0,
        iat: 0,
        exp: MAX_UNIX_SECONDS,
        build: BuildStatement {
            k: String::new(),
            version: 0,
            platform: String::new(),
            file: String::new(),
            sha256: String::new(),
            size: 1,
            commit: String::new(),
            run_id: 1,
            iat: 0,
        },
    })
}

fn result_name<T>(result: Result<T, Reason>) -> &'static str {
    match result {
        Ok(_) => "ok",
        Err(reason) => reason.as_str(),
    }
}

/// What this client answers for one case: `ok`, `ignored` or a reason name.
fn run_case(v: &Value, input: &Value) -> &'static str {
    let panel = keys_of(&v["panel_keys"]);
    let build = keys_of(input.get("build_keys").unwrap_or(&v["build_keys"]));
    let installed = input["installed_version"].as_u64().map(|n| n as u32);
    let now_s = input["now_s"].as_i64();
    match str_of(input, "kind") {
        "release" => {
            let expect = Expect {
                iss: str_of(input, "iss"),
                api_server: str_of(input, "api_server"),
                platform: str_of(input, "platform"),
                now_s: now_s.unwrap(),
            };
            match verify(&input["release"], &panel, &build, &expect) {
                // Step 12: not an error, the notice is dropped silently.
                Ok(release) if !release.is_newer_than(installed.unwrap()) => "ignored",
                other => result_name(other),
            }
        }
        "order" => {
            let held = held_release(&input["release"]);
            let expect = order::Expect {
                iss: str_of(input, "iss"),
                did: str_of(input, "did"),
                duuid: str_of(input, "duuid"),
                now_s: now_s.unwrap(),
                release: held.as_ref(),
                installed: installed.unwrap(),
            };
            result_name(order::verify(&input["order"], &panel, &expect))
        }
        "build" => result_name(verify_build(&input["build"], &build)),
        kind => panic!("unknown case kind {kind}"),
    }
}

fn case<'a>(v: &'a Value, name: &str) -> &'a Value {
    v["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|case| case["name"] == name)
        .unwrap_or_else(|| panic!("case {name}"))
}

#[test]
fn vector_constants_match() {
    let v = vector();
    assert_eq!(v["v"], 1);
    assert_eq!(str_of(&v["prefixes"], "release").as_bytes(), RELEASE_SIGNING_PREFIX);
    assert_eq!(str_of(&v["prefixes"], "update_order").as_bytes(), UPDATE_ORDER_SIGNING_PREFIX);
    assert_eq!(str_of(&v["prefixes"], "build").as_bytes(), BUILD_SIGNING_PREFIX);
    assert_eq!(v["clock_skew_s"].as_i64(), Some(CLOCK_SKEW_S));
    assert_eq!(v["max_signed_p_chars"].as_u64(), Some(MAX_SIGNED_P_CHARS as u64));
    assert_eq!(v["max_url_chars"].as_u64(), Some(MAX_URL_CHARS as u64));
    assert_eq!(v["release_ttl_s"].as_i64(), Some(RELEASE_TTL_S));
    assert_eq!(v["order_ttl_s"].as_i64(), Some(ORDER_TTL_S));
    assert_eq!(keys_of(&v["panel_keys"]).len(), 2);
    assert_eq!(keys_of(&v["build_keys"]).len(), 1);
}

#[test]
fn vector_cases_match() {
    let v = vector();
    let cases = v["cases"].as_array().unwrap();
    assert!(cases.len() >= 200, "{} cases", cases.len());
    let mut failures = Vec::new();
    for case in cases {
        let expected = str_of(case, "expect");
        assert!(
            expected == "ok" || expected == "ignored" || Reason::parse(expected).is_some(),
            "unknown expectation {expected}"
        );
        let got = run_case(&v, &case["input"]);
        if got != expected {
            failures.push(format!("{}: expected {expected}, got {got}", str_of(case, "name")));
        }
    }
    assert!(failures.is_empty(), "{} failing cases:\n{}", failures.len(), failures.join("\n"));
}

// The `url` rule against both kinds of build: the release build (`https://…`) and a local test
// build (`SENSE_API_SERVER=http://…`). Each accepts only its own exact address.
#[test]
fn url_rule_follows_the_build_api_server() {
    let v = vector();
    let https = &case(&v, "release_ok_windows")["input"];
    let http = &case(&v, "release_ok_http_dev_build")["input"];
    assert_eq!(run_case(&v, https), "ok");
    assert_eq!(run_case(&v, http), "ok");
    let swap = |input: &Value, api_server: &Value| {
        let mut input = input.clone();
        input["api_server"] = api_server.clone();
        input
    };
    assert_eq!(run_case(&v, &swap(https, &http["api_server"])), "bad_url");
    assert_eq!(run_case(&v, &swap(http, &https["api_server"])), "bad_url");
    let trailing_slash = Value::String(format!("{}/", str_of(https, "api_server")));
    assert_eq!(run_case(&v, &swap(https, &trailing_slash)), "bad_url");
}

#[test]
fn verified_release_carries_the_build() {
    let v = vector();
    let input = &case(&v, "release_ok_notes_url")["input"];
    let expect = Expect {
        iss: str_of(input, "iss"),
        api_server: str_of(input, "api_server"),
        platform: str_of(input, "platform"),
        now_s: input["now_s"].as_i64().unwrap(),
    };
    let release = verify(
        &input["release"],
        &keys_of(&v["panel_keys"]),
        &keys_of(&v["build_keys"]),
        &expect,
    )
    .unwrap();
    assert_eq!(release.url, format!("{}/indir/{}", expect.api_server, release.file));
    assert_eq!(
        release.notes_url,
        Some(format!("{}/#surum-{}", expect.api_server, release.version))
    );
    assert_eq!((release.build.version, release.build.size), (release.version, release.size));
    assert_eq!(release.build.sha256, release.sha256);
    assert!(release.is_newer_than(release.version - 1));
    assert!(!release.is_newer_than(release.version));
}

// The order is bound to the held release: the same order passes with it, fails without it, with
// another version, and once the held release has expired.
#[test]
fn order_is_bound_to_the_held_release() {
    let v = vector();
    let input = &case(&v, "order_ok")["input"];
    let panel = keys_of(&v["panel_keys"]);
    let mut held = held_release(&input["release"]).unwrap();
    let now_s = input["now_s"].as_i64().unwrap();
    let run = |release: Option<&Release>| {
        let expect = order::Expect {
            iss: str_of(input, "iss"),
            did: str_of(input, "did"),
            duuid: str_of(input, "duuid"),
            now_s,
            release,
            installed: input["installed_version"].as_u64().unwrap() as u32,
        };
        order::verify(&input["order"], &panel, &expect).map(|order| order.version)
    };
    assert_eq!(run(Some(&held)), Ok(held.version));
    assert_eq!(run(None), Err(Reason::VersionMismatch));
    held.exp = now_s - CLOCK_SKEW_S;
    assert_eq!(run(Some(&held)), Ok(held.version));
    held.exp = now_s - CLOCK_SKEW_S - 1;
    assert_eq!(run(Some(&held)), Err(Reason::VersionMismatch));
    held.exp = MAX_UNIX_SECONDS;
    held.version += 1;
    assert_eq!(run(Some(&held)), Err(Reason::VersionMismatch));
}
