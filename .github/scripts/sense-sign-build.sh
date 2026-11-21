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
#       acik anahtar(lar): SENSE_RELEASE_KEYS (k=pub[,k=pub]).
#   sense-sign-build.sh check-keys
#       SENSE_RELEASE_KEYS bicimini denetler, k kimliklerini yazar.
#
# Tasima bicimi zarfla ayni: {"k","p","s"}. k = SHA-256(ham acik anahtar) ilk 8 bayt, hex.
# p = yuk baytlari, dolgusuz base64url. s = 64 baytlik imza, base64url. Imzalanan veri =
# "sense-remote/build/v1\n" + yuk baytlari. Yuk semasi: packages/shared/src/release.ts
# (panel deposu) BuildStatement; alan sirasi sabit, dogrulama birebir karsilastirir.
set -euo pipefail
set +x
umask 077

readonly MAX_INSTALLER_BYTES=536870912
readonly MAX_SIGNED_P_CHARS=8192
# Ed25519 SubjectPublicKeyInfo basligi (RFC 8410); ardindan 32 baytlik ham anahtar gelir.
readonly SPKI_PREFIX_HEX="302a300506032b6570032100"

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

# SENSE_RELEASE_KEYS -> "$work/keys/<k>" (ham acik anahtar). Bozuk tek giris tum listeyi dusurur
# (istemcideki parse_keys ile ayni kural).
load_keys() {
  local list=${SENSE_RELEASE_KEYS:-} entry k encoded index=0
  local -a entries
  [[ -n "${list// /}" ]] || fail "SENSE_RELEASE_KEYS bos"
  mkdir -p "$work/keys"
  IFS=',' read -r -a entries <<<"$list"
  for entry in "${entries[@]}"; do
    index=$((index + 1))
    entry=${entry// /}
    k=${entry%%=*}
    encoded=${entry#*=}
    [[ "$entry" == *=* && "$k" =~ ^[0-9a-f]{16}$ ]] \
      || fail "SENSE_RELEASE_KEYS giris $index: <k>=<acik anahtar> bekleniyor (k 16 kucuk hex)"
    b64url_decode "$encoded" "$work/keys/$k.tmp" \
      || fail "SENSE_RELEASE_KEYS giris $index: acik anahtar dolgusuz base64url degil"
    [[ "$(byte_count "$work/keys/$k.tmp")" == 32 ]] \
      || fail "SENSE_RELEASE_KEYS giris $index: acik anahtar 32 bayt olmali"
    [[ "$(key_id "$work/keys/$k.tmp")" == "$k" ]] \
      || fail "SENSE_RELEASE_KEYS giris $index: k acik anahtarla uyusmuyor"
    [[ ! -e "$work/keys/$k" ]] || fail "SENSE_RELEASE_KEYS giris $index: yinelenen k"
    mv "$work/keys/$k.tmp" "$work/keys/$k"
  done
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

cmd_check_keys() {
  load_keys
  local ids=()
  local path
  for path in "$work"/keys/*; do
    ids+=("$(basename "$path")")
  done
  echo "SENSE_RELEASE_KEYS: ${#ids[@]} anahtar"
  echo "k: ${ids[*]}"
}

cmd_sign() {
  local installer=${1:?kurulum dosyasi} version=${2:?surum} commit=${3:?commit} run_id=${4:?run_id}
  local out=${5:?cikti dosyasi}
  local name platform size sha256 payload k

  [[ -f "$installer" ]] || fail "Kurulum dosyasi yok: $installer"
  [[ "$version" =~ ^[1-9][0-9]{0,5}$ ]] || fail "Surum duz sayi olmali, gelen: '$version'"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "commit 40 hex olmali"
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || fail "run_id pozitif tam sayi olmali"
  name=$(basename "$installer")
  platform=$(platform_of "$name") || fail "Dosya adi kurala uymuyor: $name"
  [[ "$name" == "$(installer_name "$version" "$platform")" ]] \
    || fail "Dosya adi '$name' surum $version ile uyusmuyor"
  size=$(byte_count "$installer")
  [[ "$size" -gt 0 && "$size" -le "$MAX_INSTALLER_BYTES" ]] || fail "Dosya boyutu sinir disi: $size"
  sha256=$(sha256_hex "$installer")

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

  # Sir ile degisken ayni anahtari gostermeli; yoksa istemciler bu imzayi tanimaz.
  if [[ -n "${SENSE_RELEASE_KEYS:-}" ]]; then
    load_keys
    if [[ ! -f "$work/keys/$k" ]] || ! cmp -s "$work/keys/$k" "$work/public.raw"; then
      fail "Gizli anahtarin k degeri ($k) SENSE_RELEASE_KEYS icinde yok"
    fi
  fi

  payload=$(printf '{"v":1,"typ":"build","version":%s,"platform":"%s","file":"%s","sha256":"%s","size":%s,"commit":"%s","run_id":%s,"iat":%s}' \
    "$version" "$platform" "$name" "$sha256" "$size" "$commit" "$run_id" "$(date +%s)")
  printf '%s' "$payload" > "$work/payload"
  write_signed_message "$work/payload" "$work/message"
  openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$work/message" -out "$work/signature" \
    2>/dev/null || fail "Imzalama basarisiz (openssl pkeyutl)"
  rm -f "$work/key.pem"
  [[ "$(byte_count "$work/signature")" == 64 ]] || fail "Imza 64 bayt degil"

  printf '{"k":"%s","p":"%s","s":"%s"}\n' "$k" "$(b64url_encode < "$work/payload")" \
    "$(b64url_encode < "$work/signature")" > "$work/statement"
  mkdir -p "$(dirname "$out")"
  (umask 022 && cat "$work/statement" > "$out")
  echo "Yapi beyani yazildi: $(basename "$out") (k=$k, $platform, surum $version, $size bayt)"
  echo "sha256: $sha256"
}

cmd_verify() {
  local installer=${1:?kurulum dosyasi} statement=${2:?beyan dosyasi}
  local content k p s name platform version size sha256 payload expected

  [[ -f "$installer" ]] || fail "Kurulum dosyasi yok: $installer"
  [[ -f "$statement" ]] || fail "Beyan dosyasi yok: $statement"
  load_keys
  content=$(cat "$statement")
  [[ "$content" =~ ^\{\"k\":\"([0-9a-f]{16})\",\"p\":\"([A-Za-z0-9_-]+)\",\"s\":\"([A-Za-z0-9_-]{86})\"\}$ ]] \
    || fail "Beyan bicimi {k,p,s} degil (malformed)"
  k=${BASH_REMATCH[1]}
  p=${BASH_REMATCH[2]}
  s=${BASH_REMATCH[3]}
  [[ "${#p}" -le "$MAX_SIGNED_P_CHARS" ]] || fail "p $MAX_SIGNED_P_CHARS karakteri asiyor (malformed)"
  [[ -f "$work/keys/$k" ]] || fail "k=$k SENSE_RELEASE_KEYS icinde yok (build_unknown_key)"
  b64url_decode "$p" "$work/payload" || fail "p cozulemedi (malformed)"
  b64url_decode "$s" "$work/signature" || fail "s cozulemedi (malformed)"
  [[ "$(byte_count "$work/signature")" == 64 ]] || fail "Imza 64 bayt degil (malformed)"

  raw_public_to_pem "$work/keys/$k" "$work/public.pem" || fail "Acik anahtar okunamadi"
  write_signed_message "$work/payload" "$work/message"
  verify_signature "$work/public.pem" "$work/message" "$work/signature" \
    || fail "Imza tutmuyor (build_bad_signature)"

  name=$(basename "$installer")
  platform=$(platform_of "$name") || fail "Dosya adi kurala uymuyor: $name"
  version=${name//[!0-9]/}
  size=$(byte_count "$installer")
  sha256=$(sha256_hex "$installer")
  payload=$(cat "$work/payload")
  expected="^\{\"v\":1,\"typ\":\"build\",\"version\":$version,\"platform\":\"$platform\",\"file\":\"${name//./\\.}\",\"sha256\":\"$sha256\",\"size\":$size,\"commit\":\"[0-9a-f]{40}\",\"run_id\":[1-9][0-9]*,\"iat\":[0-9]+\}$"
  [[ "$payload" =~ $expected ]] \
    || fail "Beyan dosyayla uyusmuyor (build_mismatch): $name sha256=$sha256 boyut=$size"
  echo "Yapi beyani dogrulandi: $name (k=$k, $platform, surum $version, $size bayt)"
}

command=${1:-}
[[ $# -gt 0 ]] && shift
case "$command" in
  sign) cmd_sign "$@" ;;
  verify) cmd_verify "$@" ;;
  check-keys) cmd_check_keys ;;
  *)
    echo "Kullanim: $0 sign|verify|check-keys ..." >&2
    exit 2
    ;;
esac
