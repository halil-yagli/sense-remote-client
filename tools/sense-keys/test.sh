#!/usr/bin/env bash
# Sense Remote: anahtar ve imza betiklerinin birim testi.
#
#   bash tools/sense-keys/test.sh
#
# Gerçek hiçbir şeye dokunmaz: GitHub yerine SAHTE bir `gh` (geçici klasöre yazar), anahtar
# yerine bu koşuda üretilen ve koşu bitince silinen DENEME anahtarları kullanılır.
# Linux / Git Bash: iki üretim betiği + sense-sign-build.sh.
# macOS: ayrıca sertifika imza yolu (sense-macos-package.sh işlevleri) küçük bir deneme
# paketiyle: p12 anahtar zincirine alınıyor mu, imza ve DR denetimi tutuyor mu.
# shellcheck disable=SC2317  # işlevler check / refuse / trap üzerinden dolaylı çağrılır
set -euo pipefail
set +x

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
sign_build="$repo_root/.github/scripts/sense-sign-build.sh"
package_script="$repo_root/.github/scripts/sense-macos-package.sh"
readonly TEST_REPO="deneme/sense-remote-client"

root=$(mktemp -d)
last_log=""
cleanup() {
  local status=$?
  # Beklenmedik çıkışta son adımın çıktısı gösterilir (deneme değerleri; gerçek sır yok).
  if [[ "$status" -ne 0 && -n "$last_log" && -s "$last_log" ]]; then
    cat "$last_log"
  fi
  cd /
  if declare -F remove_signing_keychain >/dev/null; then
    remove_signing_keychain || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT

passed=0
failed=0
ok() {
  passed=$((passed + 1))
  echo "  geçti: $1"
}
bad() {
  failed=$((failed + 1))
  echo "  DÜŞTÜ: $1"
}
# check <açıklama> <komut...>: komut başarılıysa geçer.
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
# refuse <açıklama> <komut...>: komut başarısızsa geçer.
refuse() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

# --- sahte gh ---------------------------------------------------------------------------------
bin="$root/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Sahte gh: çağrıları ve yazılan değerleri FAKE_GH_STORE altına kaydeder; ağa çıkmaz.
set -euo pipefail
store=${FAKE_GH_STORE:?}
printf '%s\n' "$*" >> "$store/calls.log"
option() { # option <ad> <bağımsız değişkenler...>: --ad'ın değeri
  local wanted=$1
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "repo view") echo "deneme/sense-remote-client" ;;
  # Ortam: env.<ad> = custom_branch_policies (true/false); policies.<ad> = "tür:ad" satırları
  # (gerçek gh'ın --jq çıktısının aynısı).
  "api "*)
    path=${2##*/environments/}
    case "$path" in
      */deployment-branch-policies)
        name=${path%/deployment-branch-policies}
        [[ -e "$store/env.$name" ]] || exit 1
        cat "$store/policies.$name" 2>/dev/null || true
        ;;
      *)
        [[ -e "$store/env.$path" ]] || exit 1
        cat "$store/env.$path"
        ;;
    esac
    ;;
  "secret set")
    [[ "$(option --repo "$@")" == "deneme/sense-remote-client" ]] || exit 1
    environment=$(option --env "$@") || exit 1
    [[ -e "$store/env.$environment" ]] || exit 1
    if [[ -e "$store/fail.secret" ]]; then
      exit 1
    fi
    # Değer yalnız stdin'den kabul edilir: komut satırındaki değer süreç listesinde görünür.
    if option --body "$@" >/dev/null; then
      echo "secret --body" >> "$store/violations"
    fi
    cat > "$store/secret.$3"
    printf '%s' "$environment" > "$store/secret.$3.env"
    ;;
  "variable set")
    [[ "$(option --repo "$@")" == "deneme/sense-remote-client" ]] || exit 1
    option --body "$@" > "$store/var.$3"
    ;;
  "variable list")
    for path in "$store"/var.*; do
      if [[ -e "$path" ]]; then
        echo "${path##*/var.}"
      fi
    done
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$bin/gh"
export PATH="$bin:$PATH"
# Güvenlik ağı: sahte gh öne geçmediyse HİÇBİR betik çalıştırılmaz (gerçek depoya yazılmasın).
if [[ "$(command -v gh)" != "$bin/gh" ]]; then
  echo "Sahte gh PATH'te öne alınamadı; test durduruldu." >&2
  exit 1
fi

# Ed25519 bilen openssl (macOS'ta sistem openssl'i LibreSSL olabilir).
ossl=""
for candidate in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" genpkey -algorithm ed25519 >/dev/null 2>&1; then
    ossl=$candidate
    break
  fi
done

new_store() {
  FAKE_GH_STORE="$root/store.$1"
  export FAKE_GH_STORE
  rm -rf "$FAKE_GH_STORE"
  mkdir -p "$FAKE_GH_STORE"
  export TMPDIR="$root/tmp.$1"
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
}
# make_env <ortam> <kural...>: sahte GitHub'da "Selected branches and tags" kurallı ortam.
make_env() {
  local name=$1
  shift
  echo true > "$FAKE_GH_STORE/env.$name"
  printf '%s\n' "$@" > "$FAKE_GH_STORE/policies.$name"
}
# Betik çıkışında geçici klasöründe hiçbir şey bırakmamalı.
tmp_is_empty() {
  [[ -z "$(ls -A "$TMPDIR")" ]]
}
# Dosyadaki hiçbir satır (en az 16 karakterlik) çıktıda geçmemeli.
leaks() {
  local secret_file=$1 output_file=$2 line
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ ${#line} -ge 16 ]] && grep -Fq -- "$line" "$output_file"; then
      return 0
    fi
  done < "$secret_file"
  return 1
}
mode_is_600() {
  local mode
  mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")
  [[ "$mode" == 600 ]]
}
# Beyan dosyasındaki yük (p) çözülmüş hâliyle.
payload_of() {
  local encoded
  encoded=$(sed 's/.*"p":"\([^"]*\)".*/\1/' "$1")
  case $((${#encoded} % 4)) in
    2) encoded+="==" ;;
    3) encoded+="=" ;;
  esac
  printf '%s' "$encoded" | tr -- '-_' '+/' | openssl base64 -d -A
}
same_nonempty() {
  [[ -n "$1" && "$1" == "$2" ]]
}
# fail() çıkış yaptığı için paket betiğinin işlevleri alt kabukta denenir.
in_subshell() {
  ("$@")
}
on_windows=false
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) on_windows=true ;;
esac

# === 1. yapi-anahtari-uret.sh =================================================================
echo "== yapi-anahtari-uret.sh"
yapi="$here/yapi-anahtari-uret.sh"
if [[ -z "$ossl" ]]; then
  echo "  atlandı: Ed25519 bilen openssl yok"
else
  new_store yapi-noenv
  backup="$root/yedek-a"
  mkdir -p "$backup"
  refuse "ortam 'surum' yokken durur" bash "$yapi" --yedek "$backup" --repo "$TEST_REPO"
  check "ortam yokken sır yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_RELEASE_SIGNING_KEY"
  check "ortam yokken yedek yazılmadı" test -z "$(ls -A "$backup")"

  # Ortam var ama dal/etiket kuralı yanlış: sır yazılmaz.
  new_store yapi-policy
  make_env surum "tag:v*"
  echo false > "$FAKE_GH_STORE/env.surum"
  refuse "ortam 'All branches' iken durur" bash "$yapi" --yedek "$backup" --repo "$TEST_REPO"
  make_env surum "tag:v*" "branch:*"
  refuse "ortamda fazladan kural varken durur" bash "$yapi" --yedek "$backup" --repo "$TEST_REPO"
  make_env surum "branch:master"
  refuse "ortam kuralı v* etiketi değilken durur" bash "$yapi" --yedek "$backup" --repo "$TEST_REPO"
  check "kural yanlışken sır yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_RELEASE_SIGNING_KEY"
  check "kural yanlışken yedek yazılmadı" test -z "$(ls -A "$backup")"

  # --deneme: ayrı ortam (yalnız master), ayrı sır ve değişken.
  new_store yapi-deneme
  backup_trial="$root/yedek-d"
  mkdir -p "$backup_trial"
  make_env deneme "tag:v*"
  refuse "--deneme: ortam kuralı master değilken durur" bash "$yapi" --deneme --yedek "$backup_trial" --repo "$TEST_REPO"
  make_env deneme "branch:master"
  trial_out="$root/yapi-deneme.out"
  if bash "$yapi" --deneme --yedek "$backup_trial" --repo "$TEST_REPO" > "$trial_out" 2>&1; then ok "--deneme çalıştı"; else
    bad "--deneme çalıştı"
    cat "$trial_out"
  fi
  trial_secret="$FAKE_GH_STORE/secret.SENSE_TRIAL_RELEASE_SIGNING_KEY"
  check "--deneme: sır 'deneme' ortamına yazıldı" test "$(cat "$trial_secret.env" 2>/dev/null)" = deneme
  check "--deneme: üretim sırrı yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_RELEASE_SIGNING_KEY"
  check "--deneme: üretim değişkeni yazılmadı" test ! -e "$FAKE_GH_STORE/var.SENSE_RELEASE_KEYS"
  trial_keys=$(cat "$FAKE_GH_STORE/var.SENSE_TRIAL_RELEASE_KEYS" 2>/dev/null || true)
  check "--deneme: SENSE_TRIAL_RELEASE_KEYS = k=pub" grep -Eqx '[0-9a-f]{16}=[A-Za-z0-9_-]{43}' <<<"$trial_keys"
  check "--deneme: yedek sırla aynı" cmp -s "$trial_secret" "$backup_trial/sense-remote-deneme-yapi-anahtari.pem"
  refuse "--deneme: gizli anahtar ekranda yok" leaks "$trial_secret" "$trial_out"
  check "--deneme: geçici klasör temiz" tmp_is_empty

  new_store yapi
  make_env surum "tag:v*"
  out="$root/yapi.out"
  if bash "$yapi" --yedek "$backup" --repo "$TEST_REPO" > "$out" 2>&1; then ok "çalıştı"; else
    bad "çalıştı"
    cat "$out"
  fi
  secret="$FAKE_GH_STORE/secret.SENSE_RELEASE_SIGNING_KEY"
  check "sır 'surum' ortamına yazıldı" test "$(cat "$secret.env" 2>/dev/null)" = surum
  check "sır komut satırından verilmedi" test ! -e "$FAKE_GH_STORE/violations"
  "$ossl" pkey -in "$secret" -pubout -outform DER -out "$root/yapi.pub.der" 2>/dev/null || true
  tail -c 32 "$root/yapi.pub.der" > "$root/yapi.pub.raw" 2>/dev/null || true
  expected_k=$("$ossl" dgst -sha256 -r "$root/yapi.pub.raw" | cut -c1-16) || true
  expected_pub=$("$ossl" base64 -A -in "$root/yapi.pub.raw" | tr '+/' '-_' | tr -d '=') || true
  check "sır Ed25519 gizli anahtarı (açık anahtar 44 bayt DER)" test "$(wc -c < "$root/yapi.pub.der" | tr -d ' ')" = 44
  release_keys=$(cat "$FAKE_GH_STORE/var.SENSE_RELEASE_KEYS" 2>/dev/null || true)
  check "SENSE_RELEASE_KEYS = k=pub, sırdaki anahtarla aynı" test "$release_keys" = "$expected_k=$expected_pub"
  check "açık anahtar ekranda" grep -Fq "$expected_k=$expected_pub" "$out"
  refuse "gizli anahtar ekranda yok" leaks "$secret" "$out"
  refuse "gizli anahtar gh komut satırında yok" leaks "$secret" "$FAKE_GH_STORE/calls.log"
  check "yedek sırla aynı" cmp -s "$secret" "$backup/sense-remote-yapi-anahtari.pem"
  if $on_windows; then
    echo "  atlandı: dosya izni 600 (NTFS'te chmod etkisiz)"
  else
    check "yedek izni 600" mode_is_600 "$backup/sense-remote-yapi-anahtari.pem"
  fi
  check "geçici klasör temiz" tmp_is_empty

  backup2="$root/yedek-b"
  mkdir -p "$backup2"
  cp "$secret" "$root/yapi.first"
  refuse "anahtar zaten varken durur" bash "$yapi" --yedek "$backup2" --repo "$TEST_REPO"
  check "var olan sır değişmedi" cmp -s "$secret" "$root/yapi.first"
  check "ikinci yedek yazılmadı" test -z "$(ls -A "$backup2")"

  new_store yapi-fail
  make_env surum "tag:v*"
  touch "$FAKE_GH_STORE/fail.secret"
  refuse "sır yazılamazsa düşer" bash "$yapi" --yedek "$backup2" --repo "$TEST_REPO"
  check "yarıda kalınca yedek silindi" test -z "$(ls -A "$backup2")"
  check "yarıda kalınca değişken yazılmadı" test ! -e "$FAKE_GH_STORE/var.SENSE_RELEASE_KEYS"
  check "yarıda kalınca geçici klasör temiz" tmp_is_empty

  new_store yapi-synced
  make_env surum "tag:v*"
  mkdir -p "$root/OneDrive/yedek"
  refuse "eşitlenen klasöre yedek yazmaz" bash "$yapi" --yedek "$root/OneDrive/yedek" --repo "$TEST_REPO"
  refuse "depo içine yedek yazmaz" bash "$yapi" --yedek "$here" --repo "$TEST_REPO"
  check "reddedilince sır yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_RELEASE_SIGNING_KEY"
fi

# === 2. sense-sign-build.sh ===================================================================
echo "== sense-sign-build.sh"
if [[ -z "$ossl" || ! -e "$secret" ]] || ! openssl genpkey -algorithm ed25519 >/dev/null 2>&1; then
  echo "  atlandı: PATH'teki openssl Ed25519 bilmiyor (bu betik yalnız Linux koşucusunda çalışır)"
else
  new_store sign
  work="$root/sign"
  mkdir -p "$work"
  exe="$work/SenseRemote-Kurulum-901.exe"
  dmg="$work/SenseRemote-901.dmg"
  head -c 4096 /dev/urandom > "$exe"
  head -c 5000 /dev/urandom > "$dmg"
  commit=0123456789abcdef0123456789abcdef01234567
  signing_key=$(cat "$secret")
  out="$root/sign.out"

  sign() { SENSE_RELEASE_KEYS=$release_keys SENSE_RELEASE_SIGNING_KEY=$signing_key bash "$sign_build" sign "$@"; }
  verify() { SENSE_RELEASE_KEYS=$release_keys bash "$sign_build" verify "$@"; }

  check "check-keys geçerli listeyi kabul eder" env SENSE_RELEASE_KEYS="$release_keys" bash "$sign_build" check-keys
  refuse "check-keys boş listeyi reddeder" env SENSE_RELEASE_KEYS="" bash "$sign_build" check-keys
  refuse "check-keys k uyuşmazlığını reddeder" env SENSE_RELEASE_KEYS="0000000000000000=${release_keys#*=}" bash "$sign_build" check-keys
  refuse "check-keys bozuk anahtarı reddeder" env SENSE_RELEASE_KEYS="${release_keys%????}" bash "$sign_build" check-keys

  # --- ortak test vektörü (panel packages/shared/test-vectors/release-v1.json, SHA-256
  # e75c01decc81a7ff14f137296eb3ee7f1d03b30bc300508b46aafb72840f5e4c), vaka "build_ok".
  # Yük JCS kanonik olmalı; imzalayıcının ürettiği baytlar vektördekiyle AYNI olmalı.
  vector_keys="04d80c49ccad4b4c=NB52UaELl_a7bsngxMn3kE9w7-os1zIlo2hLdyvLgTM"
  vector_p="eyJjb21taXQiOiJjMGZmZWUwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwIiwiZmlsZSI6IlNlbnNlUmVtb3RlLUt1cnVsdW0tMy5leGUiLCJpYXQiOjE3OTk5OTY0MDAsInBsYXRmb3JtIjoid2luZG93cy14NjQiLCJydW5faWQiOjQ0OTA2ODQ4MjQ0LCJzaGEyNTYiOiJhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExYTFhMWExIiwic2l6ZSI6MjYxNDY4MTYsInR5cCI6ImJ1aWxkIiwidiI6MSwidmVyc2lvbiI6M30"
  vector_s="fW_cCugtii3jLNGBWO_de2fiiy1Kmmg4h0EdAxTfqgE47_kI64pLPvFLGrxaaE39_UCapR7oLF7CZ_1x32IoDw"
  vector_payload='{"commit":"c0ffee0000000000000000000000000000000000","file":"SenseRemote-Kurulum-3.exe","iat":1799996400,"platform":"windows-x64","run_id":44906848244,"sha256":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","size":26146816,"typ":"build","v":1,"version":3}'
  made_payload=$(bash "$sign_build" payload SenseRemote-Kurulum-3.exe 3 \
    a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 26146816 \
    c0ffee0000000000000000000000000000000000 44906848244 1799996400 2>/dev/null || true)
  check "vektör build_ok: imzalayıcının yükü bayt bayt aynı (JCS)" test "$made_payload" = "$vector_payload"
  made_p=$(printf '%s' "$made_payload" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  check "vektör build_ok: p (base64url) aynı" test "$made_p" = "$vector_p"
  printf '{"k":"04d80c49ccad4b4c","p":"%s","s":"%s"}\n' "$vector_p" "$vector_s" > "$root/vector-build-ok.json"
  check "vektör build_ok: panelin imzası bu doğrulayıcıdan geçiyor (önek + Ed25519)" \
    env SENSE_RELEASE_KEYS="$vector_keys" bash "$sign_build" verify-statement "$root/vector-build-ok.json"
  printf '{"k":"04d80c49ccad4b4c","p":"%s","s":"%s"}\n' "${vector_p}A" "$vector_s" > "$root/vector-bad.json"
  refuse "vektör: değişen yük reddedilir" \
    env SENSE_RELEASE_KEYS="$vector_keys" bash "$sign_build" verify-statement "$root/vector-bad.json"
  refuse "payload: sürüm 0 reddedilir" bash "$sign_build" payload SenseRemote-Kurulum-0.exe 0 \
    a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 1 c0ffee0000000000000000000000000000000000 1 0
  refuse "payload: run_id 2^53 reddedilir" bash "$sign_build" payload SenseRemote-Kurulum-3.exe 3 \
    a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 1 c0ffee0000000000000000000000000000000000 9007199254740992 0
  refuse "payload: büyük harfli sha256 reddedilir" bash "$sign_build" payload SenseRemote-Kurulum-3.exe 3 \
    A1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 1 c0ffee0000000000000000000000000000000000 1 0
  # İstemci kopyası (U1 ile gelir) varsa gömülü vaka onunla aynı olmalı.
  client_vector="$repo_root/src/sense/testdata/release-v1.json"
  if [[ -f "$client_vector" ]]; then
    check "gömülü vaka istemcideki vektörle aynı (p)" grep -Fq "\"p\": \"$vector_p\"" "$client_vector"
    check "gömülü vaka istemcideki vektörle aynı (s)" grep -Fq "\"s\": \"$vector_s\"" "$client_vector"
  else
    echo "  atlandı: istemcide src/sense/testdata/release-v1.json henüz yok (U1); gömülü vaka kullanıldı"
  fi

  # --- deneme anahtar kimlikleri ve liste kesişimi
  for forbidden_id in 94d01a580be13482 b0d12b9f71aebc1f 04d80c49ccad4b4c 15797e90d15b0a59; do
    forbidden_out="$root/forbidden.out"
    env SENSE_RELEASE_KEYS="$release_keys,$forbidden_id=AAAA" bash "$sign_build" check-keys > "$forbidden_out" 2>&1 || true
    check "check-keys deneme kimliğini reddeder (yapı listesi): $forbidden_id" grep -q "DENEME anahtar kimligi var ($forbidden_id)" "$forbidden_out"
    env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="$forbidden_id=AAAA" bash "$sign_build" check-keys > "$forbidden_out" 2>&1 || true
    check "check-keys deneme kimliğini reddeder (panel listesi): $forbidden_id" grep -q "SENSE_ENVELOPE_KEYS icinde DENEME anahtar kimligi var ($forbidden_id)" "$forbidden_out"
  done
  openssl genpkey -algorithm ed25519 -out "$root/panel.pem" 2>/dev/null
  openssl pkey -in "$root/panel.pem" -pubout -outform DER 2>/dev/null | tail -c 32 > "$root/panel.raw"
  panel_keys="$(openssl dgst -sha256 -r "$root/panel.raw" | cut -c1-16)=$(openssl base64 -A -in "$root/panel.raw" | tr '+/' '-_' | tr -d '=')"
  check "check-keys ayrı panel anahtarını kabul eder" \
    env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="$panel_keys" bash "$sign_build" check-keys
  overlap_out="$root/overlap.out"
  env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="$panel_keys,$release_keys" bash "$sign_build" check-keys > "$overlap_out" 2>&1 || true
  check "check-keys kesişen listeleri reddeder" grep -q "SENSE_ENVELOPE_KEYS kesisiyor" "$overlap_out"
  refuse "check-keys kesişen listelerde düşer" \
    env SENSE_RELEASE_KEYS="$panel_keys,$release_keys" SENSE_ENVELOPE_KEYS="$panel_keys" bash "$sign_build" check-keys
  refuse "check-keys bozuk panel listesini reddeder" \
    env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="${panel_keys%????}" bash "$sign_build" check-keys

  # --- satır sonlu listeler: `read` yalnız ilk satırı okur; ikinci satır denetimden kaçmamalı.
  newline_out="$root/newline.out"
  env SENSE_RELEASE_KEYS="$release_keys,"$'\n'"04d80c49ccad4b4c=AAAA" bash "$sign_build" check-keys > "$newline_out" 2>&1 || true
  check "check-keys satır sonlu listede deneme kimliğini kaçırmaz (yapı listesi)" \
    grep -q "SENSE_RELEASE_KEYS izin verilmeyen karakter" "$newline_out"
  env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="$panel_keys,"$'\n'"$release_keys" bash "$sign_build" check-keys > "$newline_out" 2>&1 || true
  check "check-keys satır sonlu listede kesişimi kaçırmaz (panel listesi)" \
    grep -q "SENSE_ENVELOPE_KEYS izin verilmeyen karakter" "$newline_out"
  refuse "check-keys CR içeren listeyi reddeder" env SENSE_RELEASE_KEYS="$release_keys"$'\r' bash "$sign_build" check-keys
  refuse "check-keys sekme içeren listeyi reddeder" env SENSE_RELEASE_KEYS="$release_keys"$'\t' bash "$sign_build" check-keys
  refuse "verify satır sonlu listeyi reddeder" env SENSE_RELEASE_KEYS="$release_keys"$'\n' \
    bash "$sign_build" verify-statement "$root/vector-build-ok.json"

  # --- deneme yapı anahtarı listesi (SENSE_TRIAL_RELEASE_KEYS)
  check "check-keys ayrı deneme listesini kabul eder" env SENSE_RELEASE_KEYS="$release_keys" \
    SENSE_ENVELOPE_KEYS="$panel_keys" SENSE_TRIAL_RELEASE_KEYS="$trial_keys" bash "$sign_build" check-keys
  check "check-keys yalnız deneme listesiyle çalışır (üretim listesi boş)" \
    env SENSE_RELEASE_KEYS="" SENSE_TRIAL_RELEASE_KEYS="$trial_keys" bash "$sign_build" check-keys
  trial_out="$root/trial-overlap.out"
  env SENSE_RELEASE_KEYS="$release_keys" SENSE_TRIAL_RELEASE_KEYS="$trial_keys,$release_keys" bash "$sign_build" check-keys > "$trial_out" 2>&1 || true
  check "check-keys deneme listesi üretim yapı listesiyle kesişince düşer" \
    grep -q "SENSE_TRIAL_RELEASE_KEYS ile SENSE_RELEASE_KEYS kesisiyor" "$trial_out"
  env SENSE_RELEASE_KEYS="$release_keys,$trial_keys" SENSE_TRIAL_RELEASE_KEYS="$trial_keys" bash "$sign_build" check-keys > "$trial_out" 2>&1 || true
  check "check-keys deneme kimliği üretim listesinde görünürse düşer" \
    grep -q "SENSE_TRIAL_RELEASE_KEYS ile SENSE_RELEASE_KEYS kesisiyor" "$trial_out"
  env SENSE_RELEASE_KEYS="$release_keys" SENSE_ENVELOPE_KEYS="$panel_keys,$trial_keys" SENSE_TRIAL_RELEASE_KEYS="$trial_keys" bash "$sign_build" check-keys > "$trial_out" 2>&1 || true
  check "check-keys deneme kimliği panel listesinde görünürse düşer" \
    grep -q "SENSE_TRIAL_RELEASE_KEYS ile SENSE_ENVELOPE_KEYS kesisiyor" "$trial_out"
  refuse "check-keys deneme listesinde test vektörü kimliğini reddeder" \
    env SENSE_TRIAL_RELEASE_KEYS="$trial_keys,15797e90d15b0a59=AAAA" bash "$sign_build" check-keys
  refuse "check-keys satır sonlu deneme listesini reddeder" \
    env SENSE_RELEASE_KEYS="$release_keys" SENSE_TRIAL_RELEASE_KEYS="$trial_keys,"$'\n'"$release_keys" bash "$sign_build" check-keys

  if sign "$exe" 901 "$commit" 42 "$exe.yapi.json" > "$out" 2>&1; then ok "Windows beyanı imzalandı"; else
    bad "Windows beyanı imzalandı"
    cat "$out"
  fi
  check "Mac beyanı imzalandı" sign "$dmg" 901 "$commit" 42 "$dmg.yapi.json"
  refuse "gizli anahtar çıktıda yok" leaks "$secret" "$out"
  check "geçici klasör temiz" tmp_is_empty
  check "Windows beyanı açık anahtarla doğrulanır" verify "$exe" "$exe.yapi.json"
  check "Mac beyanı açık anahtarla doğrulanır" verify "$dmg" "$dmg.yapi.json"

  statement=$(cat "$exe.yapi.json")
  payload=$(payload_of "$exe.yapi.json")
  mac_payload=$(payload_of "$dmg.yapi.json")
  payload_iat_mac=${mac_payload#*\"iat\":}
  payload_iat_mac=${payload_iat_mac%%,*}
  payload_iat=${payload#*\"iat\":}
  payload_iat=${payload_iat%%,*}
  expected_payload="{\"commit\":\"$commit\",\"file\":\"SenseRemote-Kurulum-901.exe\",\"iat\":$payload_iat,\"platform\":\"windows-x64\",\"run_id\":42,\"sha256\":\"$(openssl dgst -sha256 -r "$exe" | cut -c1-64)\",\"size\":4096,\"typ\":\"build\",\"v\":1,\"version\":901}"
  check "yük kanonik BuildStatement (JCS alan sırası)" test "$payload" = "$expected_payload"
  check "iat şimdiye yakın" test "$(($(date +%s) - payload_iat))" -lt 600
  check "beyanda k doğru" grep -Fq "{\"k\":\"${release_keys%%=*}\"," "$exe.yapi.json"
  check "Mac yükünde platform macos-arm64" grep -Fq '"file":"SenseRemote-901.dmg","iat":'"$payload_iat_mac"',"platform":"macos-arm64"' <<<"$mac_payload"

  refuse "başka dosyanın beyanı reddedilir (build_mismatch)" verify "$exe" "$dmg.yapi.json"
  cp "$exe" "$work/keep.exe"
  printf 'x' >> "$exe"
  refuse "değişen dosya reddedilir (build_mismatch)" verify "$exe" "$exe.yapi.json"
  cp "$work/keep.exe" "$exe"
  check "özgün dosya yeniden doğrulanır" verify "$exe" "$exe.yapi.json"

  # İmzanın ilk karakterini değiştir.
  signature=${statement##*\"s\":\"}
  signature=${signature%%\"*}
  flipped=A${signature:1}
  [[ "$flipped" != "$signature" ]] || flipped=B${signature:1}
  printf '%s\n' "${statement/$signature/$flipped}" > "$work/tampered.json"
  refuse "bozuk imza reddedilir (build_bad_signature)" verify "$exe" "$work/tampered.json"
  printf '%s\n' "${statement/\"k\":\"/\"x\":1,\"k\":\"}" > "$work/extra.json"
  refuse "fazladan alan reddedilir (malformed)" verify "$exe" "$work/extra.json"

  # Kanonik OLMAYAN yük (alan sırası farklı), GEÇERLİ imzayla bile reddedilmeli (bad_payload).
  loose='{"v":1,"typ":"build","version":901,"platform":"windows-x64","file":"SenseRemote-Kurulum-901.exe","sha256":"'"$(openssl dgst -sha256 -r "$exe" | cut -c1-64)"'","size":4096,"commit":"'"$commit"'","run_id":42,"iat":1800000000}'
  {
    printf 'sense-remote/build/v1\n'
    printf '%s' "$loose"
  } > "$work/loose.message"
  openssl pkeyutl -sign -inkey "$secret" -rawin -in "$work/loose.message" -out "$work/loose.signature" 2>/dev/null
  printf '{"k":"%s","p":"%s","s":"%s"}\n' "${release_keys%%=*}" \
    "$(printf '%s' "$loose" | openssl base64 -A | tr '+/' '-_' | tr -d '=')" \
    "$(openssl base64 -A -in "$work/loose.signature" | tr '+/' '-_' | tr -d '=')" > "$work/loose.json"
  loose_out="$root/loose.out"
  verify "$exe" "$work/loose.json" > "$loose_out" 2>&1 || true
  check "kanonik olmayan yük, geçerli imzayla da reddedilir (build_bad_payload)" grep -q 'build_bad_payload' "$loose_out"

  # İkinci (yabancı) deneme anahtarı: listede olmayan anahtar ve yanlış sır.
  openssl genpkey -algorithm ed25519 -out "$work/other.pem" 2>/dev/null
  openssl pkey -in "$work/other.pem" -pubout -outform DER 2>/dev/null | tail -c 32 > "$work/other.raw"
  other_keys="$(openssl dgst -sha256 -r "$work/other.raw" | cut -c1-16)=$(openssl base64 -A -in "$work/other.raw" | tr '+/' '-_' | tr -d '=')"
  refuse "listede olmayan anahtarın beyanı reddedilir (build_unknown_key)" \
    env SENSE_RELEASE_KEYS="$other_keys" bash "$sign_build" verify "$exe" "$exe.yapi.json"
  refuse "sır ile değişken uyuşmazsa imzalamaz" \
    env SENSE_RELEASE_KEYS="$release_keys" SENSE_RELEASE_SIGNING_KEY="$(cat "$work/other.pem")" \
    bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/wrong.json"
  check "iki anahtarlı listeyle doğrulanır (anahtar değiştirme)" \
    env SENSE_RELEASE_KEYS="$other_keys,$release_keys" bash "$sign_build" verify "$exe" "$exe.yapi.json"

  refuse "sır yokken imzalamaz" env SENSE_RELEASE_KEYS="$release_keys" SENSE_RELEASE_SIGNING_KEY="" \
    bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/none.json"
  refuse "açık anahtar listesi boşken imzalamaz" env SENSE_RELEASE_KEYS="" SENSE_RELEASE_SIGNING_KEY="$signing_key" \
    bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/nolist.json"
  check "liste boşken beyan yazılmadı" test ! -e "$work/nolist.json"

  # Deneme imzası (trial-sign işinin aynısı): deneme sırrı + deneme listesi. Üretim listesiyle
  # derlenen istemci bu beyanı tanımaz (build_unknown_key), deneme listesiyle derlenen tanır.
  check "deneme anahtarıyla beyan imzalanır" env SENSE_RELEASE_KEYS="$trial_keys" \
    SENSE_RELEASE_SIGNING_KEY="$(cat "$trial_secret")" bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/trial.json"
  check "deneme beyanı deneme listesiyle doğrulanır" \
    env SENSE_RELEASE_KEYS="$trial_keys" bash "$sign_build" verify "$exe" "$work/trial.json"
  refuse "deneme beyanı üretim listesiyle reddedilir (build_unknown_key)" \
    env SENSE_RELEASE_KEYS="$release_keys" bash "$sign_build" verify "$exe" "$work/trial.json"
  refuse "deneme sırrı üretim listesiyle imzalamaz" env SENSE_RELEASE_KEYS="$release_keys" \
    SENSE_RELEASE_SIGNING_KEY="$(cat "$trial_secret")" bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/trial2.json"
  refuse "sürüm dosya adıyla uyuşmazsa imzalamaz" sign "$exe" 902 "$commit" 42 "$work/v.json"
  cp "$exe" "$work/SenseRemote-Kurulum.exe"
  refuse "kural dışı dosya adını imzalamaz" sign "$work/SenseRemote-Kurulum.exe" 901 "$commit" 42 "$work/n.json"
  refuse "kısa commit'i imzalamaz" sign "$exe" 901 abc123 42 "$work/c.json"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/rsa.pem" 2>/dev/null
  refuse "Ed25519 olmayan anahtarla imzalamaz" env SENSE_RELEASE_SIGNING_KEY="$(cat "$work/rsa.pem")" \
    bash "$sign_build" sign "$exe" 901 "$commit" 42 "$work/r.json"
  check "testlerden sonra geçici klasör temiz" tmp_is_empty
fi

# === 3. mac-sertifika-uret.sh =================================================================
echo "== mac-sertifika-uret.sh"
mac="$here/mac-sertifika-uret.sh"
new_store mac-noenv
backup="$root/yedek-m"
mkdir -p "$backup"
refuse "ortam 'imza' yokken durur" bash "$mac" --yedek "$backup" --repo "$TEST_REPO"
check "ortam yokken sır yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_MAC_CERT_P12"
make_env imza "tag:v*"
refuse "ortam 'imza' master kuralı yokken durur" bash "$mac" --yedek "$backup" --repo "$TEST_REPO"
make_env imza "branch:master" "tag:v*" "branch:dev"
refuse "ortam 'imza' fazladan kuralla durur" bash "$mac" --yedek "$backup" --repo "$TEST_REPO"
check "kural yanlışken sır yazılmadı" test ! -e "$FAKE_GH_STORE/secret.SENSE_MAC_CERT_P12"

new_store mac
make_env imza "branch:master" "tag:v*"
out="$root/mac.out"
if bash "$mac" --yedek "$backup" --repo "$TEST_REPO" > "$out" 2>&1; then ok "çalıştı"; else
  bad "çalıştı"
  cat "$out"
fi
p12_secret="$FAKE_GH_STORE/secret.SENSE_MAC_CERT_P12"
password_secret="$FAKE_GH_STORE/secret.SENSE_MAC_CERT_PASSWORD"
check "p12 'imza' ortamına yazıldı" test "$(cat "$p12_secret.env" 2>/dev/null)" = imza
check "parola 'imza' ortamına yazıldı" test "$(cat "$password_secret.env" 2>/dev/null)" = imza
check "sırlar komut satırından verilmedi" test ! -e "$FAKE_GH_STORE/violations"
check "SENSE_MAC_SIGN = cert" test "$(cat "$FAKE_GH_STORE/var.SENSE_MAC_SIGN" 2>/dev/null)" = cert
mac_sha1=$(cat "$FAKE_GH_STORE/var.SENSE_MAC_CERT_SHA1" 2>/dev/null || true)
check "SENSE_MAC_CERT_SHA1 40 küçük hex" grep -Eqx '[0-9a-f]{40}' <<<"$mac_sha1"
check "parola 48 hex, satır sonu yok" grep -Eqx '[0-9a-f]{48}' <<<"$(cat "$password_secret")"
check "parola dosyasında satır sonu yok" test "$(wc -c < "$password_secret" | tr -d ' ')" = 48
# p12, sırdaki parolayla açılıyor mu (göreli yollar: Git Bash yol çevirisi).
(
  cd "$FAKE_GH_STORE"
  openssl base64 -d -A -in secret.SENSE_MAC_CERT_P12 -out cert.p12
  openssl pkcs12 -in cert.p12 -passin file:secret.SENSE_MAC_CERT_PASSWORD -nokeys -out cert.pem 2>/dev/null
  openssl pkcs12 -in cert.p12 -passin file:secret.SENSE_MAC_CERT_PASSWORD -nocerts -nodes -out key.pem 2>/dev/null
  openssl x509 -in cert.pem -noout -text > cert.txt
  openssl x509 -in cert.pem -noout -fingerprint -sha1 | sed 's/^.*=//' | tr -d ':\r\n' | tr 'A-F' 'a-f' > cert.sha1
  openssl x509 -in cert.pem -noout -subject > cert.subject
  openssl x509 -in cert.pem -noout -checkend $((7299 * 86400)) > cert.valid 2>&1 || true
) || true
check "p12 sırdaki parolayla açıldı" test -s "$FAKE_GH_STORE/cert.pem"
check "p12 gizli anahtarı içeriyor" grep -q 'PRIVATE KEY' "$FAKE_GH_STORE/key.pem"
check "parmak izi değişkenle aynı" test "$(cat "$FAKE_GH_STORE/cert.sha1")" = "$mac_sha1"
check "konu adı Sense Remote Code Signing" grep -q 'Sense Remote Code Signing' "$FAKE_GH_STORE/cert.subject"
check "uzantı: kod imzalama" grep -q 'Code Signing' "$FAKE_GH_STORE/cert.txt"
check "uzantı: dijital imza" grep -q 'Digital Signature' "$FAKE_GH_STORE/cert.txt"
check "uzantı: CA değil" grep -q 'CA:FALSE' "$FAKE_GH_STORE/cert.txt"
check "anahtar RSA 3072" grep -Eq '3072 bit' "$FAKE_GH_STORE/cert.txt"
check "süre en az 7299 gün" grep -q 'will not expire' "$FAKE_GH_STORE/cert.valid"
refuse "parola ekranda yok" leaks "$password_secret" "$out"
refuse "parola gh komut satırında yok" leaks "$password_secret" "$FAKE_GH_STORE/calls.log"
refuse "p12 ekranda yok" grep -Fq "$(cut -c1-64 "$p12_secret")" "$out"
check "parmak izi ekranda" grep -Fq "$mac_sha1" "$out"
backup_file="$backup/sense-remote-mac-sertifika-yedek.txt"
check "yedek p12'yi içeriyor" grep -Fqx "$(cat "$p12_secret")" "$backup_file"
check "yedek parolayı içeriyor" grep -Fqx "parola: $(cat "$password_secret")" "$backup_file"
if $on_windows; then
  echo "  atlandı: dosya izni 600 (NTFS'te chmod etkisiz)"
else
  check "yedek izni 600" mode_is_600 "$backup_file"
fi
check "geçici klasör temiz" tmp_is_empty
backup2="$root/yedek-n"
mkdir -p "$backup2"
refuse "sertifika zaten varken durur" bash "$mac" --yedek "$backup2" --repo "$TEST_REPO"
check "ikinci yedek yazılmadı" test -z "$(ls -A "$backup2")"

# === 4. macOS: sertifika imza yolu (deneme paketi) ============================================
# shellcheck disable=SC2154  # sign_mode ve sign_keychain kaynak alınan paket betiğinden gelir
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "== sense-macos-package.sh (sertifika yolu, deneme paketi)"
  # shellcheck source=/dev/null
  source "$package_script"
  set +e
  app="$root/Deneme.app"
  mkdir -p "$app/Contents/MacOS"
  printf 'int main(void) { return 0; }\n' > "$root/main.c"
  cc -o "$app/Contents/MacOS/Deneme" "$root/main.c"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Deneme</string>
<key>CFBundleIdentifier</key><string>com.example.sense-deneme</string>
<key>CFBundleName</key><string>Deneme</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  cat > "$root/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST

  # resolve_sign_mode: sırlar yokken dal derlemesi ad-hoc, etiket derlemesi düşer.
  mode_of() { (
    resolve_sign_mode >/dev/null
    echo "$sign_mode"
  ); }
  check "SENSE_MAC_SIGN boş → adhoc" test "$(SENSE_MAC_SIGN='' mode_of)" = adhoc
  check "cert + sır yok (dal) → adhoc" test "$(SENSE_MAC_SIGN=cert SENSE_MAC_CERT_SHA1="$mac_sha1" SENSE_MAC_CERT_P12='' SENSE_MAC_CERT_PASSWORD='' GITHUB_REF_TYPE=branch mode_of)" = adhoc
  refuse "cert + sır yok (etiket) → düşer" env SENSE_MAC_SIGN=cert SENSE_MAC_CERT_SHA1="$mac_sha1" GITHUB_REF_TYPE=tag bash -c "source '$package_script'; resolve_sign_mode"
  refuse "geçersiz değer (etiket) → düşer" env SENSE_MAC_SIGN=evet GITHUB_REF_TYPE=tag bash -c "source '$package_script'; resolve_sign_mode"

  export SENSE_MAC_SIGN=cert
  export SENSE_MAC_CERT_SHA1="$mac_sha1"
  SENSE_MAC_CERT_P12=$(cat "$p12_secret")
  SENSE_MAC_CERT_PASSWORD=$(cat "$password_secret")
  export SENSE_MAC_CERT_P12 SENSE_MAC_CERT_PASSWORD
  export RUNNER_TEMP="${RUNNER_TEMP:-$root}"
  resolve_sign_mode
  check "cert + sırlar → cert" test "$sign_mode" = cert

  # Yanlış parmak izi: zincirdeki sertifika değişkenle uyuşmuyorsa içeri alma düşer.
  refuse "yanlış parmak iziyle içeri alma düşer" env SENSE_MAC_CERT_SHA1=0000000000000000000000000000000000000000 \
    bash -c "source '$package_script'; trap remove_signing_keychain EXIT; import_signing_cert"
  refuse "yanlış parolayla içeri alma düşer" env SENSE_MAC_CERT_PASSWORD=yanlis \
    bash -c "source '$package_script'; trap remove_signing_keychain EXIT; import_signing_cert"

  # Ana kabukta çalışır (zincir durumu sonraki adımlara lazım); düşerse çıktı cleanup'ta görünür.
  import_out="$root/import.out"
  last_log=$import_out
  if import_signing_cert > "$import_out" 2>&1; then ok "p12 geçici anahtar zincirine alındı (security import)"; else
    bad "p12 geçici anahtar zincirine alındı (security import)"
    cat "$import_out"
  fi
  last_log=""
  refuse "parola içeri alma çıktısında yok" leaks "$password_secret" "$import_out"
  sign_out="$root/codesign.out"
  if sign_bundle "$app" "$root/entitlements.plist" Deneme com.example.sense-deneme > "$sign_out" 2>&1; then
    ok "deneme paketi sertifikayla imzalandı"
  else
    bad "deneme paketi sertifikayla imzalandı"
    cat "$sign_out"
  fi
  kept_keychain=$sign_keychain
  remove_signing_keychain
  check "anahtar zinciri silindi" test ! -e "$kept_keychain"
  refuse "anahtar zinciri arama listesinden çıktı" grep -Fq "$kept_keychain" <(security list-keychains -d user)

  echo "--- codesign -dv (bilgi)"
  codesign -dv --verbose=4 "$app" 2>&1 | sed 's/^/    /'
  echo "--- codesign --verify (bilgi; kendinden imzalı sertifikada CSSMERR_TP_NOT_TRUSTED beklenebilir)"
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /'
  echo "    çıkış kodu: ${PIPESTATUS[0]}"
  check "verify_code kabul ediyor" in_subshell verify_code "$app"
  check "imza ad-hoc değil" bash -c "! codesign -dv '$app' 2>&1 | grep -q '^Signature=adhoc'"
  check "imzalayan: Sense Remote Code Signing" bash -c "codesign -dv --verbose=4 '$app' 2>&1 | grep -Fxq 'Authority=Sense Remote Code Signing'"
  check "hardened runtime bayrağı" bash -c "codesign -dv '$app' 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\\([a-z,-]*runtime'"
  dr_out="$root/dr.out"
  if (check_designated_requirement "$app" com.example.sense-deneme "$mac_sha1") > "$dr_out" 2>&1; then
    ok "DR paket kimliğini ve sertifika özetini içeriyor"
  else
    bad "DR paket kimliğini ve sertifika özetini içeriyor"
  fi
  sed 's/^/    /' "$dr_out"
  refuse "DR başka parmak iziyle tutmuyor" bash -c "source '$package_script'; check_designated_requirement '$app' com.example.sense-deneme 0000000000000000000000000000000000000000"
  refuse "DR başka paket kimliğiyle tutmuyor" bash -c "source '$package_script'; check_designated_requirement '$app' com.example.baska '$mac_sha1'"
  check "imzalı ikili çalışıyor (hardened runtime + kendinden imzalı)" "$app/Contents/MacOS/Deneme"
  # Yeniden imzalanan (yeni "sürüm") paket aynı DR'yi taşımalı: izinlerin korunmasının koşulu.
  dr_first=$(codesign -d -r- "$app" 2>&1 | grep 'designated =>')
  printf 'int main(void) { return 0 * 2; }\n' > "$root/main.c"
  cc -o "$app/Contents/MacOS/Deneme" "$root/main.c"
  import_signing_cert >/dev/null 2>&1
  sign_bundle "$app" "$root/entitlements.plist" Deneme com.example.sense-deneme >/dev/null 2>&1
  remove_signing_keychain
  dr_second=$(codesign -d -r- "$app" 2>&1 | grep 'designated =>')
  check "değişen ikili yeniden imzalanınca DR aynı" same_nonempty "$dr_first" "$dr_second"
  # Karşılaştırma: ad-hoc imzada DR ikiliye (cdhash) bağlıdır.
  codesign --force --options runtime --sign - "$app" >/dev/null 2>&1
  echo "--- ad-hoc DR (bilgi): $(codesign -d -r- "$app" 2>&1 | grep 'designated =>')"
  set -e
fi

echo
echo "Sonuç: $passed geçti, $failed düştü"
[[ "$failed" -eq 0 ]]
