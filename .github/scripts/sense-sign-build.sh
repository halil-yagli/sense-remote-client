#!/usr/bin/env bash
# Sense Remote: yapi beyani (BuildStatement) imzasi ve dogrulamasi.
#
# Guncelleme iki imza ister: panelin surum bildirimi + bu derlemenin yapi beyani. Yapi beyani
# kurulum dosyasinin adini, SHA-256'sini ve boyutunu YAPI ANAHTARIYLA (Ed25519) baglar; panel
# sunucusunu ele geciren biri bu imzayi uretemez.
#
#   sense-sign-build.sh sign <kurulum dosyasi> <surum> <commit> <run_id> <cikti.yapi.json>
#       gizli anahtar: SENSE_RELEASE_SIGNING_KEY ortam degiskeni (PKCS#8 PEM). Gecici dosyada
#       (umask 077) durur, cikista silinir, hicbir yere yazdirilmaz.
#   sense-sign-build.sh verify <kurulum dosyasi> <beyan.yapi.json>
#       acik anahtar(lar): SENSE_RELEASE_KEYS (k=pub[,k=pub]). Imza + kanonik yuk + dosya.
#   sense-sign-build.sh verify-statement <beyan.yapi.json>
#       yalniz imza + kanonik yuk (dosya olmadan; ortak test vektoru icin).
#   sense-sign-build.sh payload <dosya adi> <surum> <sha256> <boyut> <commit> <run_id> <iat>
#       imzalanacak yuk baytlarini yazar (sign ayni islevi kullanir; test vektoruyle
#       bayt bayt karsilastirma icin).
#   sense-sign-build.sh check-keys
#       SENSE_RELEASE_KEYS, SENSE_ENVELOPE_KEYS ve SENSE_TRIAL_RELEASE_KEYS (deneme yapi
#       anahtari) listelerinden tanimli olanlarin bicimini denetler, k kimliklerini yazar.
#       Listelerden ikisi kesisiyorsa (ayni k ya da ayni acik anahtar) ya da birinde ortak test
#       vektorunun DENEME anahtar kimliklerinden biri varsa duser. SENSE_RELEASE_KEYS ile
#       SENSE_TRIAL_RELEASE_KEYS'ten en az biri dolu olmali.
# Listeler bolunmeden once karakter kumesiyle sinirlanir (yalniz [0-9A-Za-z_=, -]): satir sonu,
# CR ya da sekme iceren liste reddedilir (yoksa "A,<LF>B" gibi bir listenin ikinci satiri
# denetimden kacardi).
#
# Tasima bicimi zarfla ayni: {"k","p","s"}. k = SHA-256(ham acik anahtar) ilk 8 bayt, hex.
# p = yuk baytlari, dolgusuz base64url. s = 64 baytlik imza, base64url. Imzalanan veri =
# "sense-remote/build/v1\n" + yuk baytlari.
# Yuk (BuildStatement; panel deposu packages/shared/src/release.ts) JCS (RFC 8785) KANONIK
# JSON olmali: anahtarlar sirali (commit, file, iat, platform, run_id, sha256, size, typ, v,
# version), bosluk yok, sayilar yalin tamsayi, dizelerde kacis yok (hepsi duz ASCII). Panel
# ve istemci kanonik olmayan yuku bad_payload ile reddeder. Ortak vektor:
# packages/shared/test-vectors/release-v1.json (istemcide src/sense/testdata/).
set -euo pipefail
set +x
umask 077

readonly MAX_INSTALLER_BYTES=536870912
readonly MAX_SIGNED_P_CHARS=8192
readonly MAX_SAFE_INTEGER=9007199254740991
# Ortak test vektorunun deneme anahtarlari (panel release.ts TEST_VECTOR_KEY_IDS): gizli
# anahtarlari herkese acik oldugu icin hicbir derlemenin guvendigi listede olamazlar.
readonly TEST_VECTOR_KEY_IDS=(94d01a580be13482 b0d12b9f71aebc1f 04d80c49ccad4b4c 15797e90d15b0a59)
# Ed25519 SubjectPublicKeyInfo basligi (RFC 8410); ardindan 32 baytlik ham anahtar gelir.
readonly SPKI_PREFIX_HEX="302a300506032b6570032100"
# Anahtar listesinde izinli karakterler (k hex, base64url, '=', ',', bosluk).
readonly KEY_LIST_PATTERN='^[0-9A-Za-z_=, -]*$'

fail() {
  echo "::error title=Yapi beyani::$*" >&2
  exit 1
}

work=$(mktemp -d)
# shellcheck disable=SC2317  # trap ile cagrilir
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

b64url_encode() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# $1 = dolgusuz base64url metni, $2 = cikti dosyasi.
b64url_decode() {
  local text=$1
  [[ "$text" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  case $((${#text} % 4)) in
    2) text+="==" ;;
    3) text+="=" ;;
    1) return 1 ;;
  esac
  printf '%s' "$text" | tr -- '-_' '+/' | openssl base64 -d -A > "$2" 2>/dev/null
}

file_hex() {
  od -An -v -tx1 "$1" | tr -d ' \n'
}

sha256_hex() {
  openssl dgst -sha256 -r "$1" | cut -c1-64
}

byte_count() {
  wc -c < "$1" | tr -d ' '
}

# Ham 32 baytlik acik anahtar dosyasi -> k (16 hex).
key_id() {
  sha256_hex "$1" | cut -c1-16
}

# Ham acik anahtar ($1) -> PEM ($2).
raw_public_to_pem() {
  {
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
    cat "$1"
  } > "$2.der"
  openssl pkey -pubin -inform DER -in "$2.der" -out "$2" 2>/dev/null
}

# Dosya adindan platform; ad kurali InstallerFile ile ayni.
platform_of() {
  local name=$1
  if [[ "$name" =~ ^SenseRemote-Kurulum-[1-9][0-9]{0,5}\.exe$ ]]; then
    echo "windows-x64"
  elif [[ "$name" =~ ^SenseRemote-[1-9][0-9]{0,5}\.dmg$ ]]; then
    echo "macos-arm64"
  else
    return 1
  fi
}

installer_name() {
  case "$2" in
    windows-x64) echo "SenseRemote-Kurulum-$1.exe" ;;
    macos-arm64) echo "SenseRemote-$1.dmg" ;;
  esac
}

# Anahtar listesi (k=pub[,k=pub]) -> "<klasor>/<k>" (ham acik anahtar). Bozuk tek giris tum
# listeyi dusurur (istemcideki parse_keys ile ayni kural).
#   load_key_list <liste> <degisken adi (iletiler icin)> <klasor>
load_key_list() {
  local list=$1 label=$2 dir=$3 entry k encoded index=0
  local -a entries
  check_list_chars "$list" "$label"
  [[ -n "${list// /}" ]] || fail "$label bos"
  mkdir -p "$dir"
  IFS=',' read -r -a entries <<<"$list"
  for entry in ${entries[@]+"${entries[@]}"}; do
    index=$((index + 1))
    entry=${entry// /}
    k=${entry%%=*}
    encoded=${entry#*=}
    [[ "$entry" == *=* && "$k" =~ ^[0-9a-f]{16}$ ]] \
      || fail "$label giris $index: <k>=<acik anahtar> bekleniyor (k 16 kucuk hex)"
    b64url_decode "$encoded" "$dir/$k.tmp" \
      || fail "$label giris $index: acik anahtar dolgusuz base64url degil"
    [[ "$(byte_count "$dir/$k.tmp")" == 32 ]] \
      || fail "$label giris $index: acik anahtar 32 bayt olmali"
    [[ "$(key_id "$dir/$k.tmp")" == "$k" ]] \
      || fail "$label giris $index: k acik anahtarla uyusmuyor"
    [[ ! -e "$dir/$k" ]] || fail "$label giris $index: yinelenen k"
    mv "$dir/$k.tmp" "$dir/$k"
  done
}

# Liste yalniz izinli karakterlerden olusmali (satir sonu / CR / sekme yok). `read` yalniz ilk
# satiri okudugu icin bu denetim her bolmeden ONCE yapilir.
check_list_chars() {
  local list=$1 label=$2
  [[ "$list" =~ $KEY_LIST_PATTERN ]] \
    || fail "$label izin verilmeyen karakter iceriyor (satir sonu, CR, sekme ya da [0-9A-Za-z_=, -] disi)"
}

load_keys() {
  load_key_list "${SENSE_RELEASE_KEYS:-}" SENSE_RELEASE_KEYS "$work/keys"
}

# Listede deneme anahtar kimligi var mi (bicim denetiminden ONCE, yalniz k'ye bakar).
reject_test_vector_keys() {
  local list=$1 label=$2 entry k forbidden
  local -a entries
  check_list_chars "$list" "$label"
  # Bos liste: denetlenecek giris yok. (macOS /bin/bash 3.2'de bos dizi set -u altinda
  # "unbound variable" verir; bu yuzden erken donulur ve acilim korumalidir.)
  [[ -n "${list// /}" ]] || return 0
  IFS=',' read -r -a entries <<<"$list"
  for entry in ${entries[@]+"${entries[@]}"}; do
    entry=${entry// /}
    k=${entry%%=*}
    for forbidden in "${TEST_VECTOR_KEY_IDS[@]}"; do
      if [[ "$k" == "$forbidden" ]]; then
        fail "$label icinde DENEME anahtar kimligi var ($k): test vektoru anahtarlari hicbir derlemede kullanilmaz"
      fi
    done
  done
}

# BuildStatement yuku, JCS kanonik. Her alan burada denetlenir: degerler duz ASCII ve yalin
# tamsayi oldugu icin sabit sirali printf kanonik bicimi verir.
#   canonical_payload <dosya adi> <surum> <sha256> <boyut> <commit> <run_id> <iat>
canonical_payload() {
  local name=$1 version=$2 sha256=$3 size=$4 commit=$5 run_id=$6 iat=$7 platform
  [[ "$version" =~ ^[1-9][0-9]{0,5}$ ]] || fail "Surum duz sayi olmali (1-999999), gelen: '$version'"
  platform=$(platform_of "$name") || fail "Dosya adi kurala uymuyor: $name"
  [[ "$name" == "$(installer_name "$version" "$platform")" ]] \
    || fail "Dosya adi '$name' surum $version ile uyusmuyor"
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "sha256 64 kucuk hex olmali"
  [[ "$size" =~ ^[1-9][0-9]{0,8}$ && "$size" -le "$MAX_INSTALLER_BYTES" ]] \
    || fail "Dosya boyutu sinir disi: $size"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "commit 40 kucuk hex olmali"
  [[ "$run_id" =~ ^[1-9][0-9]{0,15}$ && "$run_id" -le "$MAX_SAFE_INTEGER" ]] \
    || fail "run_id 1..2^53-1 arasinda tam sayi olmali"
  [[ "$iat" =~ ^(0|[1-9][0-9]{0,9})$ ]] || fail "iat 0..9999999999 arasinda tam sayi olmali"
  printf '{"commit":"%s","file":"%s","iat":%s,"platform":"%s","run_id":%s,"sha256":"%s","size":%s,"typ":"build","v":1,"version":%s}' \
    "$commit" "$name" "$iat" "$platform" "$run_id" "$sha256" "$size" "$version"
}

# Imzalanan veri: onek + yuk baytlari.
write_signed_message() {
  {
    printf 'sense-remote/build/v1\n'
    cat "$1"
  } > "$2"
}

verify_signature() {
  local public_pem=$1 message=$2 signature=$3
  openssl pkeyutl -verify -pubin -inkey "$public_pem" -rawin -in "$message" \
    -sigfile "$signature" >/dev/null 2>&1
}

# Iki yuklu liste ayni k'yi ya da ayni acik anahtari iceriyorsa duser.
#   check_disjoint <klasor a> <ad a> <klasor b> <ad b> <neden>
check_disjoint() {
  local dir_a=$1 label_a=$2 dir_b=$3 label_b=$4 reason=$5 path other k
  for path in "$dir_a"/*; do
    k=$(basename "$path")
    [[ ! -e "$dir_b/$k" ]] || fail "$label_a ile $label_b kesisiyor (ayni k: $k); $reason"
    for other in "$dir_b"/*; do
      if cmp -s "$path" "$other"; then
        fail "$label_a ile $label_b kesisiyor (ayni acik anahtar: $k); $reason"
      fi
    done
  done
  echo "$label_a ile $label_b kesisim yok"
}

# Yuklu listenin ozeti: anahtar sayisi ve k kimlikleri (acik bilgi).
print_key_ids() {
  local dir=$1 label=$2 path ids=()
  for path in "$dir"/*; do
    ids+=("$(basename "$path")")
  done
  echo "$label: ${#ids[@]} anahtar"
  echo "k: ${ids[*]}"
}

cmd_check_keys() {
  local release_list=${SENSE_RELEASE_KEYS:-} envelope_list=${SENSE_ENVELOPE_KEYS:-}
  local trial_list=${SENSE_TRIAL_RELEASE_KEYS:-}
  local has_release=false has_envelope=false has_trial=false
  reject_test_vector_keys "$release_list" SENSE_RELEASE_KEYS
  reject_test_vector_keys "$envelope_list" SENSE_ENVELOPE_KEYS
  reject_test_vector_keys "$trial_list" SENSE_TRIAL_RELEASE_KEYS
  if [[ -n "${release_list// /}" ]]; then has_release=true; fi
  if [[ -n "${envelope_list// /}" ]]; then has_envelope=true; fi
  if [[ -n "${trial_list// /}" ]]; then has_trial=true; fi
  $has_release || $has_trial || fail "SENSE_RELEASE_KEYS bos"

  if $has_release; then
    load_keys
    print_key_ids "$work/keys" SENSE_RELEASE_KEYS
  fi
  if $has_envelope; then
    load_key_list "$envelope_list" SENSE_ENVELOPE_KEYS "$work/envelope-keys"
  fi
  if $has_trial; then
    load_key_list "$trial_list" SENSE_TRIAL_RELEASE_KEYS "$work/trial-keys"
    print_key_ids "$work/trial-keys" SENSE_TRIAL_RELEASE_KEYS
  fi
  # Iki imza kurali: panel anahtari ile yapi anahtari ayni olursa tek imzaya duser (panel
  # sunucusunu ele geciren, yapi beyanini da imzalayabilirdi). Istemci: keys_overlap.
  if $has_release && $has_envelope; then
    check_disjoint "$work/keys" SENSE_RELEASE_KEYS "$work/envelope-keys" SENSE_ENVELOPE_KEYS \
      "yapi anahtari panel anahtarindan AYRI olmali"
  fi
  # Deneme yapi anahtari (deneme ortami, yalniz master) hicbir uretim listesinde olamaz: aksi
  # halde deneme sirrina erisen, uretim istemcilerinin kabul edecegi bir beyan imzalayabilirdi.
  if $has_trial && $has_release; then
    check_disjoint "$work/trial-keys" SENSE_TRIAL_RELEASE_KEYS "$work/keys" SENSE_RELEASE_KEYS \
      "deneme anahtari uretim yapi anahtarindan AYRI olmali"
  fi
  if $has_trial && $has_envelope; then
    check_disjoint "$work/trial-keys" SENSE_TRIAL_RELEASE_KEYS "$work/envelope-keys" SENSE_ENVELOPE_KEYS \
      "deneme anahtari panel anahtarindan AYRI olmali"
  fi
}

cmd_payload() {
  [[ $# -eq 7 ]] || fail "payload: <dosya adi> <surum> <sha256> <boyut> <commit> <run_id> <iat>"
  canonical_payload "$@"
}

cmd_sign() {
  local installer=${1:?kurulum dosyasi} version=${2:?surum} commit=${3:?commit} run_id=${4:?run_id}
  local out=${5:?cikti dosyasi}
  local name size sha256 k forbidden

  [[ -f "$installer" ]] || fail "Kurulum dosyasi yok: $installer"
  name=$(basename "$installer")
  size=$(byte_count "$installer")
  sha256=$(sha256_hex "$installer")
  canonical_payload "$name" "$version" "$sha256" "$size" "$commit" "$run_id" "$(date +%s)" \
    > "$work/payload"

  [[ -n "${SENSE_RELEASE_SIGNING_KEY:-}" ]] || fail "SENSE_RELEASE_SIGNING_KEY bos (ortam 'surum' sirri)"
  printf '%s\n' "$SENSE_RELEASE_SIGNING_KEY" > "$work/key.pem"
  # Anahtar turu acik anahtarin DER basligindan anlasilir; anahtar metni hicbir yere yazdirilmaz.
  openssl pkey -in "$work/key.pem" -pubout -outform DER -out "$work/public.der" 2>/dev/null \
    || fail "SENSE_RELEASE_SIGNING_KEY okunamadi (PKCS#8 PEM bekleniyor)"
  [[ "$(file_hex "$work/public.der" | cut -c1-24)" == "$SPKI_PREFIX_HEX" \
    && "$(byte_count "$work/public.der")" == 44 ]] \
    || fail "SENSE_RELEASE_SIGNING_KEY Ed25519 degil"
  tail -c 32 "$work/public.der" > "$work/public.raw"
  k=$(key_id "$work/public.raw")
  for forbidden in "${TEST_VECTOR_KEY_IDS[@]}"; do
    [[ "$k" != "$forbidden" ]] || fail "Gizli anahtar bir DENEME anahtari ($k); imzalanmaz"
  done

  # Sir ile degisken ayni anahtari gostermeli; yoksa istemciler bu imzayi tanimaz. Liste bossa
  # imzalanmaz: dogrulanamayan bir beyan yayina girmesin.
  [[ -n "${SENSE_RELEASE_KEYS:-}" ]] || fail "SENSE_RELEASE_KEYS bos; imza acik anahtar listesiyle eslestirilemez"
  load_keys
  if [[ ! -f "$work/keys/$k" ]] || ! cmp -s "$work/keys/$k" "$work/public.raw"; then
    fail "Gizli anahtarin k degeri ($k) SENSE_RELEASE_KEYS icinde yok"
  fi

  write_signed_message "$work/payload" "$work/message"
  openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$work/message" -out "$work/signature" \
    2>/dev/null || fail "Imzalama basarisiz (openssl pkeyutl)"
  rm -f "$work/key.pem"
  [[ "$(byte_count "$work/signature")" == 64 ]] || fail "Imza 64 bayt degil"

  printf '{"k":"%s","p":"%s","s":"%s"}\n' "$k" "$(b64url_encode < "$work/payload")" \
    "$(b64url_encode < "$work/signature")" > "$work/statement"
  mkdir -p "$(dirname "$out")"
  (umask 022 && cat "$work/statement" > "$out")
  echo "Yapi beyani yazildi: $(basename "$out") (k=$k, surum $version, $size bayt)"
  echo "sha256: $sha256"
}

# Beyani okur: bicim, anahtar, imza, kanonik yuk. Basarida statement_k ve "$work/payload" dolu.
statement_k=""
read_statement() {
  local statement=$1 content p s payload
  [[ -f "$statement" ]] || fail "Beyan dosyasi yok: $statement"
  load_keys
  content=$(cat "$statement")
  [[ "$content" =~ ^\{\"k\":\"([0-9a-f]{16})\",\"p\":\"([A-Za-z0-9_-]+)\",\"s\":\"([A-Za-z0-9_-]{86})\"\}$ ]] \
    || fail "Beyan bicimi {k,p,s} degil (malformed)"
  statement_k=${BASH_REMATCH[1]}
  p=${BASH_REMATCH[2]}
  s=${BASH_REMATCH[3]}
  [[ "${#p}" -le "$MAX_SIGNED_P_CHARS" ]] || fail "p $MAX_SIGNED_P_CHARS karakteri asiyor (malformed)"
  [[ -f "$work/keys/$statement_k" ]] || fail "k=$statement_k SENSE_RELEASE_KEYS icinde yok (build_unknown_key)"
  b64url_decode "$p" "$work/payload" || fail "p cozulemedi (malformed)"
  b64url_decode "$s" "$work/signature" || fail "s cozulemedi (malformed)"
  [[ "$(byte_count "$work/signature")" == 64 ]] || fail "Imza 64 bayt degil (malformed)"

  raw_public_to_pem "$work/keys/$statement_k" "$work/public.pem" || fail "Acik anahtar okunamadi"
  write_signed_message "$work/payload" "$work/message"
  verify_signature "$work/public.pem" "$work/message" "$work/signature" \
    || fail "Imza tutmuyor (build_bad_signature)"

  # Kanonik bicim: alanlar ayristirilir, ayni islevle yeniden uretilir, baytlar ayni olmali.
  payload=$(cat "$work/payload")
  [[ "$payload" =~ ^\{\"commit\":\"([0-9a-f]+)\",\"file\":\"([A-Za-z0-9.-]+)\",\"iat\":([0-9]+),\"platform\":\"([a-z0-9-]+)\",\"run_id\":([0-9]+),\"sha256\":\"([0-9a-f]+)\",\"size\":([0-9]+),\"typ\":\"build\",\"v\":1,\"version\":([0-9]+)\}$ ]] \
    || fail "Yuk kanonik BuildStatement degil (build_bad_payload)"
  local commit=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} iat=${BASH_REMATCH[3]}
  local platform=${BASH_REMATCH[4]} run_id=${BASH_REMATCH[5]} sha256=${BASH_REMATCH[6]}
  local size=${BASH_REMATCH[7]} version=${BASH_REMATCH[8]}
  # Alt kabukta: icerideki fail yalniz alt kabugu bitirir, neden burada yazilir.
  (canonical_payload "$name" "$version" "$sha256" "$size" "$commit" "$run_id" "$iat") \
    > "$work/payload.again" 2>/dev/null || fail "Yuk semaya uymuyor (build_bad_payload)"
  cmp -s "$work/payload" "$work/payload.again" || fail "Yuk kanonik degil (build_bad_payload)"
  [[ "$(platform_of "$name")" == "$platform" ]] || fail "platform dosya adiyla uyusmuyor (build_bad_payload)"
}

cmd_verify_statement() {
  read_statement "${1:?beyan dosyasi}"
  echo "Yapi beyani dogrulandi (imza + kanonik yuk): k=$statement_k"
}

cmd_verify() {
  local installer=${1:?kurulum dosyasi} statement=${2:?beyan dosyasi}
  local name size sha256 payload expected

  [[ -f "$installer" ]] || fail "Kurulum dosyasi yok: $installer"
  read_statement "$statement"
  name=$(basename "$installer")
  size=$(byte_count "$installer")
  sha256=$(sha256_hex "$installer")
  payload=$(cat "$work/payload")
  expected="^\{\"commit\":\"[0-9a-f]{40}\",\"file\":\"${name//./\\.}\",\"iat\":[0-9]+,\"platform\":\"[a-z0-9-]+\",\"run_id\":[0-9]+,\"sha256\":\"$sha256\",\"size\":$size,"
  [[ "$payload" =~ $expected ]] \
    || fail "Beyan dosyayla uyusmuyor (build_mismatch): $name sha256=$sha256 boyut=$size"
  echo "Yapi beyani dogrulandi: $name (k=$statement_k, $size bayt)"
}

command=${1:-}
[[ $# -gt 0 ]] && shift
case "$command" in
  sign) cmd_sign "$@" ;;
  verify) cmd_verify "$@" ;;
  verify-statement) cmd_verify_statement "$@" ;;
  payload) cmd_payload "$@" ;;
  check-keys) cmd_check_keys ;;
  *)
    echo "Kullanim: $0 sign|verify|verify-statement|payload|check-keys ..." >&2
    exit 2
    ;;
esac
