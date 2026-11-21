#!/usr/bin/env bash
# Sense Remote: macOS (Apple Silicon) kurulum paketi. Ucretsiz kural: Apple Developer ID ve
# notarization yok; dmg imzalanmaz. Uygulama iki yoldan biriyle imzalanir (hardened runtime
# ikisinde de acik):
#   adhoc (varsayilan): kimlik "-", sir kullanmaz. Belirlenmis gereksinim (DR) her surumde
#     degisir; macOS gizlilik izinleri (Ekran Kaydi, Erisilebilirlik) guncellemede duser.
#   cert (SENSE_MAC_SIGN=cert): kalici, kendinden imzali kod imzalama sertifikasi. DR = paket
#     kimligi + sertifika ozeti, surumden surume ayni kalir (Apple TN3127, TN2206).
#
# Iki adim, iki ayri cagri: sirlar YALNIZ imza adiminin ortamindadir. Paket adimi derlenen
# uygulamayi calistirir (--version) ve create-dmg'yi kullanir; o adimda sir yoktur, gecici anahtar
# zinciri de imzadan sonra silinmistir.
#
#   sense-macos-package.sh sign <SenseRemote.app> <entitlements.plist> <sense surumu>
#       marka denetimi, Info.plist (ad, SenseRemoteVersion), imza. Ortam:
#         SENSE_MAC_SIGN            cert | adhoc (yoksa adhoc)
#         SENSE_MAC_CERT_SHA1       sertifikanin SHA-1 parmak izi, 40 hex (acik bilgi)
#         SENSE_MAC_CERT_P12        p12, base64 (SIR; GitHub ortami "imza")
#         SENSE_MAC_CERT_PASSWORD   p12 parolasi (SIR; GitHub ortami "imza")
#       cert istenip sirlar yoksa: etiket (yayin) derlemesi DUSER; diger derlemeler uyariyla
#       adhoc surer (dal derlemeleri "imza" ortamina erisemez).
#   sense-macos-package.sh package <SenseRemote.app> <sense surumu> <cikti klasoru>
#       dmg + dmg iceriginin dogrulanmasi. Imza yolu uygulamanin imzasindan okunur; sertifikaliysa
#       DR, SENSE_MAC_CERT_SHA1 (acik bilgi) ile denetlenir. Ortam: SENSE_MAC_SIGN,
#       SENSE_MAC_CERT_SHA1, EXPECTED_BASE_VERSION. Bu adima SIR VERILMEZ.
#
# Uretir: <cikti>/SenseRemote-<n>.dmg (icinde uygulama + Applications kisayolu), sonra dmg'yi
# baglayip icerigi dogrular. Uygulama klasoru SenseRemote.app kalir: kurulum, servis ve
# guncelleme kodu /Applications/<APP_NAME>.app yolunu bekler (src/platform/macos.rs). Finder'da
# gorunen ad "Sense Remote" yerellestirilmis addan (InfoPlist.strings) gelir.
set -euo pipefail
set +x

readonly BUNDLE_NAME="SenseRemote"
readonly DISPLAY_NAME="Sense Remote"
readonly PLIST_BUDDY=/usr/libexec/PlistBuddy
readonly LIBRARY_VALIDATION_KEY="com.apple.security.cs.disable-library-validation"
readonly DYLD_ENV_KEY="com.apple.security.cs.allow-dyld-environment-variables"
readonly CERT_COMMON_NAME="Sense Remote Code Signing"

# Imza durumu (resolve_sign_mode ve import_signing_cert doldurur).
sign_mode="adhoc"
sign_keychain=""
sign_identity="-"
original_keychains=()

fail() {
  echo "::error title=macOS paketi::$*" >&2
  exit 1
}

plist_get() {
  "$PLIST_BUDDY" -c "Print :$2" "$1/Contents/Info.plist"
}

lower() {
  tr 'A-F' 'a-f' <<<"$1"
}

# SENSE_MAC_SIGN ve sirlara gore sign_mode'u secer.
resolve_sign_mode() {
  local requested=${SENSE_MAC_SIGN:-adhoc} is_tag=false missing=""
  if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    is_tag=true
  fi
  case "$requested" in
    adhoc)
      sign_mode="adhoc"
      return 0
      ;;
    cert) ;;
    *)
      if $is_tag; then
        fail "SENSE_MAC_SIGN '$requested' gecersiz (cert ya da adhoc olmali)"
      fi
      echo "::warning title=SENSE_MAC_SIGN gecersiz::'$requested' taninmiyor; bu derleme ad-hoc imzalanir."
      sign_mode="adhoc"
      return 0
      ;;
  esac
  [[ "${SENSE_MAC_CERT_SHA1:-}" =~ ^[0-9A-Fa-f]{40}$ ]] || missing+=" SENSE_MAC_CERT_SHA1(40 hex)"
  [[ -n "${SENSE_MAC_CERT_P12:-}" ]] || missing+=" SENSE_MAC_CERT_P12"
  [[ -n "${SENSE_MAC_CERT_PASSWORD:-}" ]] || missing+=" SENSE_MAC_CERT_PASSWORD"
  if [[ -z "$missing" ]]; then
    sign_mode="cert"
    return 0
  fi
  if $is_tag; then
    fail "SENSE_MAC_SIGN=cert ama eksik:$missing. Yayin (etiket) derlemesi sertifikasiz cikmaz."
  fi
  echo "::warning title=Mac sertifikasi yok::SENSE_MAC_SIGN=cert ama eksik:$missing (dal derlemesi 'imza' ortamina erisemez). Bu derleme ad-hoc imzalanir; izinler guncellemede korunmaz."
  sign_mode="adhoc"
}

remove_signing_keychain() {
  [[ -n "$sign_keychain" ]] || return 0
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$sign_keychain" >/dev/null 2>&1 || true
  rm -f "$sign_keychain"
  sign_keychain=""
}

# Sertifikayi (SENSE_MAC_CERT_P12 + parola) gecici, rastgele parolali bir anahtar zincirine alir
# ve sign_identity'yi ayarlar. p12 dosyasi iceri alinir alinmaz silinir; zincir imzadan sonra
# remove_signing_keychain ile silinir. Sir degerleri yazdirilmaz.
import_signing_cert() {
  local expected_sha1 keychain_password p12_file imported line
  expected_sha1=$(lower "$SENSE_MAC_CERT_SHA1")
  sign_keychain="$(mktemp -u "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sense-sign.XXXXXXXX").keychain-db"
  keychain_password=$(openssl rand -hex 24)

  original_keychains=()
  while IFS= read -r line; do
    line=${line#*\"}
    line=${line%\"*}
    if [[ -n "$line" ]]; then
      original_keychains+=("$line")
    fi
  done < <(security list-keychains -d user)

  security create-keychain -p "$keychain_password" "$sign_keychain"
  security set-keychain-settings -lut 21600 "$sign_keychain"
  security unlock-keychain -p "$keychain_password" "$sign_keychain"

  p12_file=$(umask 077 && mktemp -t sense-cert)
  if ! printf '%s' "$SENSE_MAC_CERT_P12" | base64 -D > "$p12_file" 2>/dev/null; then
    rm -f "$p12_file"
    fail "SENSE_MAC_CERT_P12 base64 olarak cozulemedi"
  fi
  if ! security import "$p12_file" -f pkcs12 -k "$sign_keychain" -P "$SENSE_MAC_CERT_PASSWORD" \
    -T /usr/bin/codesign >/dev/null 2>&1; then
    rm -f "$p12_file"
    fail "Sertifika anahtar zincirine alinamadi (p12 ya da parola yanlis)"
  fi
  rm -f "$p12_file"
  # codesign'in ozel anahtari parola sormadan kullanabilmesi icin.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
    "$sign_keychain" >/dev/null
  if [[ ${#original_keychains[@]} -gt 0 ]]; then
    security list-keychains -d user -s "$sign_keychain" "${original_keychains[@]}" >/dev/null
  else
    security list-keychains -d user -s "$sign_keychain" >/dev/null
  fi

  # Sir (p12) ile degisken (parmak izi) ayni sertifikayi gostermeli.
  imported=$(security find-certificate -a -Z "$sign_keychain" | awk '/^SHA-1 hash:/ {print $3}')
  [[ "$(lower "$imported")" == "$expected_sha1" ]] \
    || fail "Zincirdeki sertifika SENSE_MAC_CERT_SHA1 ile ayni degil (gelen: $(lower "$imported" | tr '\n' ' '))"
  sign_identity=$(tr 'a-f' 'A-F' <<<"$expected_sha1")
  echo "Imza sertifikasi gecici anahtar zincirine alindi (sha1 $expected_sha1)"
}

# Belirlenmis gereksinim (DR) paket kimligini ve sertifika ozetini icermeli: macOS izinleri
# (TCC) yeni surumun bu DR'yi saglamasina bakar.
check_designated_requirement() {
  local app=$1 bundle_id=$2 sha1 requirement
  sha1=$(lower "$3")
  requirement=$(codesign -d -r- "$app" 2>&1 | grep -E '^(# )?designated => ' || true)
  echo "DR: ${requirement:-okunamadi}"
  grep -Fq "identifier \"$bundle_id\"" <<<"$requirement" \
    || fail "DR paket kimligini icermiyor: identifier \"$bundle_id\""
  lower "$requirement" | grep -Fq "certificate leaf = H\"$sha1\"" \
    || fail "DR sertifika ozetini icermiyor: certificate leaf = H\"$sha1\""
  # Metin yetmez: imza bu gereksinimi kriptografik olarak da saglamali (codesign -R).
  codesign --verify --strict -R="identifier \"$bundle_id\" and certificate leaf = H\"$sha1\"" "$app" \
    || fail "Imza gereksinimi saglamiyor: identifier \"$bundle_id\" and certificate leaf = H\"$sha1\""
}

# Icten disa imza: once cerceveler ve yardimci ikililer, en son entitlements ile uygulama.
#   sign_bundle <uygulama> <imza entitlements dosyasi> <ana ikili adi> <paket kimligi>
sign_bundle() {
  local app=$1 signing_entitlements=$2 executable=$3 bundle_id=$4
  local sign_args=(--force --options runtime --sign "$sign_identity")
  local app_args=()
  local frameworks_path="$app/Contents/Frameworks" code framework helper
  if [[ "$sign_mode" == "cert" ]]; then
    # Zaman damgasi yok: Apple'in sunucusu yalniz Apple sertifikalarina hizmet verir.
    sign_args+=(--timestamp=none --keychain "$sign_keychain")
    # DR acikca yazilir: codesign'in kendi sectigi bicime (leaf / root) bagli kalmasin.
    app_args+=(--requirements "=designated => identifier \"$bundle_id\" and certificate leaf = H\"$(lower "$sign_identity")\"")
  fi

  if [[ -d "$frameworks_path" ]]; then
    while IFS= read -r -d '' code; do
      if file -b "$code" | grep -q 'Mach-O'; then
        codesign "${sign_args[@]}" "$code"
      fi
    done < <(find "$frameworks_path" -type f -print0)
    while IFS= read -r -d '' framework; do
      codesign "${sign_args[@]}" "$framework"
    done < <(find "$frameworks_path" -depth -type d -name '*.framework' -print0)
  fi

  while IFS= read -r -d '' helper; do
    [[ "$(basename "$helper")" == "$executable" ]] && continue
    if file -b "$helper" | grep -q 'Mach-O'; then
      codesign "${sign_args[@]}" "$helper"
    fi
  done < <(find "$app/Contents/MacOS" -type f -print0)

  codesign "${sign_args[@]}" ${app_args[@]+"${app_args[@]}"} --generate-entitlement-der \
    --entitlements "$signing_entitlements" "$app"
}

# codesign --verify; her hata durdurur. Kendinden imzali sertifikada da cikis 0 (olculdu: kosu
# 44928861832, macos-26: "valid on disk" + "satisfies its Designated Requirement"); bu yuzden
# CSSMERR_TP_NOT_TRUSTED icin istisna YOK.
verify_code() {
  local app=$1 output status=0
  output=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1) || status=$?
  echo "$output"
  [[ "$status" -eq 0 ]] || fail "codesign --verify dustu (cikis $status)"
}

# Ortak giris denetimi: uygulama klasoru ve surum.
check_inputs() {
  [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] || fail "Surum duz sayi olmali, gelen: '$2'"
  [[ -d "$1" ]] || fail "Uygulama bulunamadi: $1"
  [[ "$(basename "$1")" == "$BUNDLE_NAME.app" ]] \
    || fail "Uygulama klasoru $BUNDLE_NAME.app olmali, gelen: $(basename "$1")"
}

# Paket adimi: imza yolu uygulamanin kendi imzasindan okunur (sir gerekmez).
detect_sign_mode() {
  local app=$1 signature
  signature=$(codesign -dv --verbose=4 "$app" 2>&1) || fail "Uygulama imzali degil"
  if grep -q '^Signature=adhoc$' <<<"$signature"; then
    sign_mode="adhoc"
    if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${SENSE_MAC_SIGN:-adhoc}" != "adhoc" ]]; then
      fail "SENSE_MAC_SIGN=${SENSE_MAC_SIGN:-} ama uygulama ad-hoc imzali; yayin (etiket) derlemesi sertifikasiz cikmaz"
    fi
  else
    sign_mode="cert"
    [[ "${SENSE_MAC_CERT_SHA1:-}" =~ ^[0-9A-Fa-f]{40}$ ]] \
      || fail "Uygulama sertifikayla imzali ama SENSE_MAC_CERT_SHA1 40 hex degil"
  fi
}

cmd_sign() {
local app_path=${1:?uygulama yolu}
local entitlements=${2:?entitlements dosyasi}
local sense_version=${3:?Sense surum numarasi}
local executable bundle_id locale signing_entitlements

check_inputs "$app_path" "$sense_version"
[[ -f "$entitlements" ]] || fail "Entitlements bulunamadi: $entitlements"

# --- 1. Marka denetimi -----------------------------------------------------------------------
executable=$(plist_get "$app_path" CFBundleExecutable)
[[ "$executable" == "$BUNDLE_NAME" ]] || fail "CFBundleExecutable '$executable', beklenen '$BUNDLE_NAME'"
[[ "$(plist_get "$app_path" CFBundleName)" == "$DISPLAY_NAME" ]] \
  || fail "CFBundleName '$(plist_get "$app_path" CFBundleName)', beklenen '$DISPLAY_NAME'"

# --- 2. Finder'da gorunen ad -----------------------------------------------------------------
# Finder yerellestirilmis adi yalniz Info.plist'teki CFBundleDisplayName dosya sistemi adiyla
# ayni ise gosterir (Apple: CFBundleDisplayName). Bu yuzden duz deger klasor adi olur, gorunen
# "Sense Remote" InfoPlist.strings'ten gelir.
"$PLIST_BUDDY" -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$app_path/Contents/Info.plist"
"$PLIST_BUDDY" -c "Delete :LSHasLocalizedDisplayName" "$app_path/Contents/Info.plist" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :LSHasLocalizedDisplayName bool true" "$app_path/Contents/Info.plist"
# Sense surum numarasi (duz sayi): guncelleme kodu kurulu paketin surumunu buradan okur
# (CFBundleShortVersionString RustDesk taban surumudur).
"$PLIST_BUDDY" -c "Delete :SenseRemoteVersion" "$app_path/Contents/Info.plist" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :SenseRemoteVersion string $sense_version" "$app_path/Contents/Info.plist"
for locale in en tr; do
  mkdir -p "$app_path/Contents/Resources/$locale.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$DISPLAY_NAME" "$DISPLAY_NAME" \
    > "$app_path/Contents/Resources/$locale.lproj/InfoPlist.strings"
done

# --- 3. Imza (ad-hoc ya da sertifika) ----------------------------------------------------------
# build.py 'service' ikilisini derlemeden sonra kopyaladigi icin Xcode'un imzasi zaten gecersiz.
# Hardened runtime ACIK (G4-3): kod enjeksiyonu (DYLD_INSERT_LIBRARIES, task_for_pid) kapanir.
# Iki yolda da Team ID olmadigi icin kitaplik dogrulamasi uygulamanin kendi cercevelerini de
# reddeder; bu yuzden imzaya YALNIZ disable-library-validation eklenir (depodaki entitlements
# dosyasi degismez). allow-dyld-environment-variables bilerek eklenmez.
bundle_id=$(plist_get "$app_path" CFBundleIdentifier)
resolve_sign_mode
echo "== imza yolu: $sign_mode"
if [[ "$sign_mode" == "cert" ]]; then
  trap remove_signing_keychain EXIT
  import_signing_cert
fi

signing_entitlements=$(mktemp -t sense-entitlements)
cp "$entitlements" "$signing_entitlements"
"$PLIST_BUDDY" -c "Delete :$LIBRARY_VALIDATION_KEY" "$signing_entitlements" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :$LIBRARY_VALIDATION_KEY bool true" "$signing_entitlements"
if grep -q "$DYLD_ENV_KEY" "$signing_entitlements"; then
  fail "Entitlements $DYLD_ENV_KEY iceriyor; hardened runtime'i deler"
fi

sign_bundle "$app_path" "$signing_entitlements" "$executable" "$bundle_id"
rm -f "$signing_entitlements"
# Imza bitti: ozel anahtar bu noktadan sonra kosucuda durmaz.
remove_signing_keychain
trap - EXIT
echo "Imza tamam ($sign_mode). Paket ve dogrulama ayri, sirsiz adimda (package)."
}

cmd_package() {
local app_path=${1:?uygulama yolu}
local sense_version=${2:?Sense surum numarasi}
local out_dir=${3:?cikti klasoru}
local executable bundle_id dmg_path create_dmg mounted_app
local key finder_name signature nested actual_entitlements audio_input library_validation
local spctl_status spctl_output reported_version dmg_size dmg_sha256 sign_label

check_inputs "$app_path" "$sense_version"
executable=$(plist_get "$app_path" CFBundleExecutable)
bundle_id=$(plist_get "$app_path" CFBundleIdentifier)
detect_sign_mode "$app_path"
echo "== imza yolu (imzadan okundu): $sign_mode"
[[ "$(plist_get "$app_path" SenseRemoteVersion)" == "$sense_version" ]] \
  || fail "Info.plist SenseRemoteVersion '$sense_version' degil (imza adimi baska surumle calismis)"

# --- 4. dmg ----------------------------------------------------------------------------------
mkdir -p "$out_dir"
dmg_path="$out_dir/$BUNDLE_NAME-$sense_version.dmg"
rm -f "$dmg_path"

# create-dmg'nin ayirma denemesi CI'da yetmeyebiliyor (RustDesk'in is akisindaki ayni yama).
create_dmg=$(readlink -f "$(command -v create-dmg)")
sed -i -e 's/MAXIMUM_UNMOUNTING_ATTEMPTS=3/MAXIMUM_UNMOUNTING_ATTEMPTS=7/' "$create_dmg"

create-dmg \
  --volname "$DISPLAY_NAME" \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "$BUNDLE_NAME.app" 200 190 \
  --hide-extension "$BUNDLE_NAME.app" \
  --app-drop-link 600 185 \
  "$dmg_path" "$app_path"

# --- 5. dmg icerigini dogrula ----------------------------------------------------------------
# mount_point bilerek yerel degil: detach, main bittikten sonra (EXIT) da calisabilir.
mount_point=$(mktemp -d)
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
# shellcheck disable=SC2317  # trap ile cagrilir
detach() { hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; }
trap detach EXIT

mounted_app="$mount_point/$BUNDLE_NAME.app"
echo "== dmg icerigi"
ls -la "$mount_point"
[[ -d "$mounted_app" ]] || fail "dmg icinde $BUNDLE_NAME.app yok"
[[ -L "$mount_point/Applications" && "$(readlink "$mount_point/Applications")" == "/Applications" ]] \
  || fail "dmg icinde Applications kisayolu yok"
if find "$mount_point" -maxdepth 1 -iname '*rustdesk*' | grep -q .; then
  fail "dmg kokunde RustDesk adli dosya var"
fi

echo "== uygulama adi ve kimligi"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable CFBundleIdentifier \
  CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion SenseRemoteVersion; do
  echo "$key=$(plist_get "$mounted_app" "$key")"
done
[[ "$(plist_get "$mounted_app" SenseRemoteVersion)" == "$sense_version" ]] \
  || fail "Info.plist SenseRemoteVersion '$sense_version' degil"
# Finder'in gosterecegi ad; denetim bilgi amaclidir (yerellestirme kosucunun diline bagli).
finder_name=$(SENSE_APP_PATH="$mounted_app" swift -e \
  'import Foundation; print(FileManager.default.displayName(atPath: ProcessInfo.processInfo.environment["SENSE_APP_PATH"]!))' \
  2>/dev/null || true)
echo "Finder adi: ${finder_name:-okunamadi}"
if [[ "$finder_name" != "$DISPLAY_NAME" ]]; then
  echo "::warning title=Finder adi::Beklenen '$DISPLAY_NAME', gorunen '${finder_name:-okunamadi}'"
fi

echo "== codesign"
verify_code "$mounted_app"
signature=$(codesign -dv --verbose=4 "$mounted_app" 2>&1)
echo "$signature"
if [[ "$sign_mode" == "cert" ]]; then
  if grep -q '^Signature=adhoc$' <<<"$signature"; then
    fail "Imza ad-hoc; sertifika imzasi bekleniyordu"
  fi
  grep -Fxq "Authority=$CERT_COMMON_NAME" <<<"$signature" \
    || fail "Imza '$CERT_COMMON_NAME' sertifikasiyla atilmamis"
  check_designated_requirement "$mounted_app" "$bundle_id" "$SENSE_MAC_CERT_SHA1"
else
  grep -q '^Signature=adhoc$' <<<"$signature" || fail "Imza ad-hoc degil"
fi
grep -q '^TeamIdentifier=not set$' <<<"$signature" || fail "TeamIdentifier olmamali (Apple Developer ID yok)"
# G4-3: hardened runtime bayragi, or. "flags=0x10002(adhoc,runtime)".
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([a-z,-]*runtime[a-z,-]*\)' <<<"$signature"   || fail "Hardened runtime bayragi yok (codesign flags)"
# Yardimci ikili ve Rust kitapligi da runtime ile imzali olmali.
for nested in "Contents/MacOS/service" "Contents/Frameworks/liblibrustdesk.dylib"; do
  if [[ -e "$mounted_app/$nested" ]]; then
    codesign -dv "$mounted_app/$nested" 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\([a-z,-]*runtime'       || fail "$nested hardened runtime ile imzali degil"
  fi
done
actual_entitlements=$(codesign -d --entitlements :- "$mounted_app" 2>/dev/null)
audio_input=$(plutil -extract 'com\.apple\.security\.device\.audio-input' raw - <<<"$actual_entitlements")
[[ "$audio_input" == "true" ]] || fail "audio-input entitlement eksik"
library_validation=$(plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw -   <<<"$actual_entitlements")
[[ "$library_validation" == "true" ]] || fail "disable-library-validation entitlement eksik"
if grep -q "$DYLD_ENV_KEY" <<<"$actual_entitlements"; then
  fail "Imzada $DYLD_ENV_KEY var"
fi
echo "entitlements:"
echo "$actual_entitlements"
file -b "$mounted_app/Contents/MacOS/$executable"
lipo -archs "$mounted_app/Contents/MacOS/$executable" | grep -qx 'arm64' \
  || fail "Uygulama yalniz arm64 olmali"

# Gatekeeper: Developer ID / notarization olmadigi icin RET beklenir. Kabul edilirse (kosucuda
# degerlendirme kapali olabilir) durdurmaz, ama Developer ID kaynagi gorulurse hata.
echo "== spctl (ret beklenir)"
spctl --status 2>&1 || true
spctl_status=0
spctl_output=$(spctl --assess --type execute -vv "$mounted_app" 2>&1) || spctl_status=$?
echo "$spctl_output"
echo "spctl cikis kodu: $spctl_status"
if grep -Eqi 'Developer ID|Notarized' <<<"$spctl_output"; then
  fail "spctl Developer ID / notarization bildirdi; bu derlemede Apple sertifikasi olmamali"
fi
if [[ "$spctl_status" -eq 0 ]]; then
  echo "::warning title=spctl::Notarization'siz uygulama kabul edildi (beklenen: rejected)"
fi

# Ikili gercekten calisiyor mu (cerceveler bu imza + hardened runtime ile yukleniyor mu):
# dyld cerceveleri acilista yukler, yuklenemezse bu adim duser. Cikti RustDesk taban surumu.
echo "== --version"
reported_version=$(perl -e 'alarm 120; exec @ARGV' "$mounted_app/Contents/MacOS/$executable" --version)
echo "--version: $reported_version"
[[ "$reported_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "--version beklenmeyen cikti: '$reported_version'"
if [[ -n "${EXPECTED_BASE_VERSION:-}" && "$reported_version" != "$EXPECTED_BASE_VERSION" ]]; then
  fail "--version '$reported_version', beklenen '$EXPECTED_BASE_VERSION'"
fi

detach
trap - EXIT

echo "== paket"
dmg_size=$(stat -f %z "$dmg_path")
dmg_sha256=$(shasum -a 256 "$dmg_path" | cut -d' ' -f1)
echo "dosya: $(basename "$dmg_path")"
echo "boyut: $dmg_size bayt"
echo "sha256: $dmg_sha256"
if [[ "$sign_mode" == "cert" ]]; then
  sign_label="kalici sertifika (kendinden imzali, sha1 $(lower "$SENSE_MAC_CERT_SHA1"))"
else
  sign_label="ad-hoc"
fi
echo "imza: $sign_label"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### macOS paketi ($sign_label; notarization yok)"
    echo "- Dosya: \`$(basename "$dmg_path")\`"
    echo "- Boyut: $dmg_size bayt"
    echo "- SHA-256: \`$dmg_sha256\`"
    echo "- Imza: $sign_label + hardened runtime; Gatekeeper ilk acilista uyarir (Sistem Ayarlari > Gizlilik ve Guvenlik > Yine de Ac)"
  } >> "$GITHUB_STEP_SUMMARY"
fi
}

# Dogrudan calistirilinca alt komutu calistirir; kaynak olarak alininca (tools/sense-keys/test.sh)
# yalniz islevleri tanimlar.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    sign)
      shift
      cmd_sign "$@"
      ;;
    package)
      shift
      cmd_package "$@"
      ;;
    *)
      echo "Kullanim: $0 sign <app> <entitlements> <surum> | package <app> <surum> <cikti>" >&2
      exit 2
      ;;
  esac
fi
