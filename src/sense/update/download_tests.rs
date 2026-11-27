// Sense Remote (update plan 2026-11-21, §3.6): tests of the download (`download.rs`), with a
// fake HTTP server on 127.0.0.1.
use super::*;
use hbb_common::tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

const FILE: &str = "SenseRemote-Kurulum-4.exe";

fn sha_of(body: &[u8]) -> String {
    hex::encode(Sha256::digest(body))
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sense-u2-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Serves `reply` (raw HTTP) once per connection, `count` connections; returns the base url.
async fn serve(replies: Vec<Vec<u8>>, delay: Duration) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        for reply in replies {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let mut request = Vec::new();
            let mut buffer = [0u8; 1024];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                match stream.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => request.extend_from_slice(&buffer[..n]),
                }
            }
            tokio::time::sleep(delay).await;
            let _ = stream.write_all(&reply).await;
            let _ = stream.shutdown().await;
        }
    });
    format!("http://{address}")
}

fn ok_reply(body: &[u8], length: Option<usize>) -> Vec<u8> {
    let mut head = "HTTP/1.1 200 OK\r\nConnection: close\r\n".to_owned();
    if let Some(length) = length {
        head.push_str(&format!("Content-Length: {length}\r\n"));
    }
    head.push_str("\r\n");
    let mut reply = head.into_bytes();
    reply.extend_from_slice(body);
    reply
}

fn request(base: &str, dir: &Path, body: &[u8], size: u64) -> Request {
    Request {
        url: format!("{base}/indir/{FILE}"),
        sha256: sha_of(body),
        size,
        dir: dir.to_path_buf(),
        file: FILE.to_owned(),
    }
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().build().unwrap()
}

async fn get(request: &Request, limit: Duration) -> Result<PathBuf, UpdateError> {
    fetch_with(&client(), request, limit, &|_| {}).await
}

fn leftovers(dir: &Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect()
}

#[tokio::test]
async fn downloads_a_matching_file() {
    let dir = temp_dir("ok");
    let body = vec![7u8; 200_000];
    let base = serve(vec![ok_reply(&body, Some(body.len()))], Duration::ZERO).await;
    let request = request(&base, &dir, &body, body.len() as u64);
    let seen = std::sync::Mutex::new(Vec::new());
    let progress = |pct: u8| seen.lock().unwrap().push(pct);
    let path = fetch_with(&client(), &request, Duration::from_secs(20), &progress)
        .await
        .unwrap();
    assert_eq!(path, dir.join(FILE));
    assert_eq!(std::fs::read(&path).unwrap(), body);
    assert_eq!(leftovers(&dir), vec![FILE.to_owned()]);
    let seen = seen.into_inner().unwrap();
    assert_eq!(seen.first(), Some(&0));
    assert_eq!(seen.last(), Some(&100));
    assert!(seen.windows(2).all(|w| w[0] < w[1]));
    assert_eq!(verify_file(&path, body.len() as u64, &request.sha256), Ok(()));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn refuses_wrong_size_cut_body_wrong_hash_and_errors() {
    let body = b"installer bytes".to_vec();
    let size = body.len() as u64;
    let mut more = body.clone();
    more.extend_from_slice(b"+extra");
    let cases: Vec<(&str, Vec<u8>, UpdateError)> = vec![
        // Announced longer than signed.
        ("long-header", ok_reply(&more, Some(more.len())), UpdateError::SizeMismatch),
        // No length announced, more bytes than signed: stopped while streaming.
        ("long-stream", ok_reply(&more, None), UpdateError::SizeMismatch),
        // No length announced, fewer bytes.
        ("short-stream", ok_reply(&body[..5], None), UpdateError::SizeMismatch),
        // Length announced, connection cut early.
        ("cut", ok_reply(&body[..5], Some(body.len())), UpdateError::DownloadFailed),
        // Right size, other bytes.
        ("hash", ok_reply(&vec![b'x'; body.len()], Some(body.len())), UpdateError::HashMismatch),
        (
            "status",
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
            UpdateError::DownloadFailed,
        ),
    ];
    for (name, reply, expected) in cases {
        let dir = temp_dir(name);
        let base = serve(vec![reply], Duration::ZERO).await;
        let result = get(&request(&base, &dir, &body, size), Duration::from_secs(20)).await;
        assert_eq!(result, Err(expected), "{name}");
        assert!(leftovers(&dir).is_empty(), "{name}: nothing is left behind");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[tokio::test]
async fn stops_at_the_time_limit() {
    let dir = temp_dir("slow");
    let body = b"late".to_vec();
    let base = serve(vec![ok_reply(&body, Some(4))], Duration::from_secs(5)).await;
    let result = get(&request(&base, &dir, &body, 4), Duration::from_millis(300)).await;
    assert_eq!(result, Err(UpdateError::DownloadFailed));
    assert!(leftovers(&dir).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn refuses_a_redirect_to_another_origin() {
    let dir = temp_dir("redirect");
    let body = b"from elsewhere".to_vec();
    let other = serve(vec![ok_reply(&body, Some(body.len()))], Duration::ZERO).await;
    let moved = format!(
        "HTTP/1.1 302 Found\r\nLocation: {other}/indir/{FILE}\r\nContent-Length: 0\r\n\
         Connection: close\r\n\r\n"
    )
    .into_bytes();
    let base = serve(vec![moved], Duration::ZERO).await;
    let result = get(&request(&base, &dir, &body, body.len() as u64), Duration::from_secs(20)).await;
    assert_eq!(result, Err(UpdateError::DownloadFailed));
    assert!(leftovers(&dir).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn refuses_a_file_name_with_a_path() {
    let dir = temp_dir("name");
    let mut bad = request("http://127.0.0.1:9", &dir, b"", 0);
    for name in ["../SenseRemote.exe", "a/b.exe", "a\\b.exe", "", ".hidden", "C:x.exe"] {
        bad.file = name.to_owned();
        assert_eq!(get(&bad, Duration::from_secs(5)).await, Err(UpdateError::DownloadFailed));
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn check_counts_and_hashes() {
    let body = b"abcdef";
    let mut check = Check::new(6);
    check.push(b"abc").unwrap();
    assert_eq!(check.progress(), 50);
    check.push(b"def").unwrap();
    assert_eq!(check.progress(), 100);
    assert_eq!(check.finish(&sha_of(body).to_uppercase()), Ok(()));
    let mut over = Check::new(5);
    assert_eq!(over.push(body), Err(UpdateError::SizeMismatch));
    let mut short = Check::new(7);
    short.push(body).unwrap();
    assert_eq!(short.finish(&sha_of(body)), Err(UpdateError::SizeMismatch));
    let mut wrong = Check::new(6);
    wrong.push(body).unwrap();
    assert_eq!(wrong.finish(&sha_of(b"abcdeg")), Err(UpdateError::HashMismatch));
    assert_eq!(Check::new(0).progress(), 100);
    assert_eq!(Check::new(u64::MAX).progress(), 0);
}

#[test]
fn verify_file_reads_the_whole_file() {
    let dir = temp_dir("verify");
    let path = dir.join(FILE);
    let body = vec![3u8; 150_000];
    std::fs::write(&path, &body).unwrap();
    assert_eq!(verify_file(&path, body.len() as u64, &sha_of(&body)), Ok(()));
    assert_eq!(
        verify_file(&path, body.len() as u64 - 1, &sha_of(&body)),
        Err(UpdateError::SizeMismatch)
    );
    assert_eq!(
        verify_file(&path, body.len() as u64, &sha_of(b"x")),
        Err(UpdateError::HashMismatch)
    );
    assert_eq!(
        verify_file(&dir.join("missing"), 1, &sha_of(b"x")),
        Err(UpdateError::DownloadFailed)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn disk_needs_three_times_the_size() {
    assert!(enough_disk(300, 100));
    assert!(!enough_disk(299, 100));
    assert!(!enough_disk(u64::MAX - 1, u64::MAX / 2));
    assert!(enough_disk(0, 0));
}

#[test]
fn free_space_of_the_deepest_mount() {
    let mounts = vec![
        (PathBuf::from("/"), 10),
        (PathBuf::from("/var"), 20),
        (PathBuf::from("/var/lib"), 30),
    ];
    assert_eq!(free_on(&mounts, Path::new("/var/lib/sense/dl")), Some(30));
    assert_eq!(free_on(&mounts, Path::new("/var/tmp")), Some(20));
    assert_eq!(free_on(&mounts, Path::new("/home")), Some(10));
    assert_eq!(free_on(&mounts, Path::new("/variable")), Some(10));
    assert_eq!(free_on(&[], Path::new("/home")), None);
}

#[test]
fn origins() {
    let base = "https://panel.example/indir/SenseRemote-Kurulum-4.exe";
    assert!(same_origin(base, "https://panel.example:443/other"));
    for other in [
        "http://panel.example/indir/SenseRemote-Kurulum-4.exe",
        "https://panel.example:8443/indir/SenseRemote-Kurulum-4.exe",
        "https://cdn.example/indir/SenseRemote-Kurulum-4.exe",
        "https://panel.example.evil/indir/x",
        "not a url",
    ] {
        assert!(!same_origin(base, other), "{other}");
    }
}

#[test]
fn plain_file_names() {
    assert!(is_plain_file_name("SenseRemote-Kurulum-4.exe"));
    assert!(is_plain_file_name("SenseRemote-4.dmg"));
    for bad in ["", ".", "..", "../x", "a/b", "a\\b", "C:x", ".part", "a b", "ğ.exe"] {
        assert!(!is_plain_file_name(bad), "{bad}");
    }
    assert!(!is_plain_file_name(&"a".repeat(129)));
}

// Sense Remote (#134, D6): free space of the download volume, also when the folder does not
// exist yet (the first download makes it).
#[test]
fn free_space_of_a_real_folder() {
    let dir = std::env::temp_dir();
    assert!(free_bytes(&dir).is_some_and(|free| free > 0));
    let missing = dir.join(format!("sense-free-{}", std::process::id())).join("dl");
    assert!(!missing.exists());
    assert!(free_bytes(&missing).is_some_and(|free| free > 0));
}
