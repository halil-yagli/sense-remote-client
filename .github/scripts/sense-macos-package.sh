#!/usr/bin/env bash
# Sense Remote: macOS (Apple Silicon) kurulum paketi. Ucretsiz kural: Apple Developer ID ve
# notarization yok; uygulama AD-HOC imzalanir (kimlik "-", hardened runtime acik), dmg
# imzalanmaz. Sir kullanmaz.
#
#   sense-macos-package.sh <SenseRemote.app> <entitlements.plist> <sense surumu> <cikti klasoru>
#
# Uretir: <cikti>/SenseRemote-<n>.dmg (icinde uygulama + Applications kisayolu), sonra dmg'yi
# baglayip icerigi dogrular. Uygulama klasoru SenseRemote.app kalir: kurulum, servis ve
# guncelleme kodu /Applications/<APP_NAME>.app yolunu bekler (src/platform/macos.rs). Finder'da
# gorunen ad "Sense Remote" yerellestirilmis addan (InfoPlist.strings) gelir.
set -euo pipefail

app_path=${1:?uygulama yolu}
entitlements=${2:?entitlements dosyasi}
sense_version=${3:?Sense surum numarasi}
out_dir=${4:?cikti klasoru}

readonly BUNDLE_NAME="SenseRemote"
readonly DISPLAY_NAME="Sense Remote"
readonly PLIST_BUDDY=/usr/libexec/PlistBuddy
readonly LIBRARY_VALIDATION_KEY="com.apple.security.cs.disable-library-validation"
readonly DYLD_ENV_KEY="com.apple.security.cs.allow-dyld-environment-variables"

fail() {
  echo "::error title=macOS paketi::$*" >&2
  exit 1
}

plist_get() {
  "$PLIST_BUDDY" -c "Print :$2" "$1/Contents/Info.plist"
}

[[ "$sense_version" =~ ^[1-9][0-9]{0,5}$ ]] || fail "Surum duz sayi olmali, gelen: '$sense_version'"
[[ -d "$app_path" ]] || fail "Uygulama bulunamadi: $app_path"
[[ -f "$entitlements" ]] || fail "Entitlements bulunamadi: $entitlements"
[[ "$(basename "$app_path")" == "$BUNDLE_NAME.app" ]] \
  || fail "Uygulama klasoru $BUNDLE_NAME.app olmali, gelen: $(basename "$app_path")"

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
for locale in en tr; do
  mkdir -p "$app_path/Contents/Resources/$locale.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$DISPLAY_NAME" "$DISPLAY_NAME" \
    > "$app_path/Contents/Resources/$locale.lproj/InfoPlist.strings"
done

# --- 3. Ad-hoc imza --------------------------------------------------------------------------
# Icten disa: once cerceveler ve yardimci ikililer, en son entitlements ile uygulama. build.py
# 'service' ikilisini derlemeden sonra kopyaladigi icin Xcode'un imzasi zaten gecersiz.
# Hardened runtime ACIK (G4-3): kod enjeksiyonu (DYLD_INSERT_LIBRARIES, task_for_pid) kapanir.
# Ad-hoc imzada Team ID olmadigi icin kitaplik dogrulamasi uygulamanin kendi cercevelerini de
# reddeder; bu yuzden imzaya YALNIZ disable-library-validation eklenir (depodaki entitlements
# dosyasi degismez). allow-dyld-environment-variables bilerek eklenmez.
sign_args=(--force --options runtime --sign -)

signing_entitlements=$(mktemp -t sense-entitlements)
cp "$entitlements" "$signing_entitlements"
"$PLIST_BUDDY" -c "Delete :$LIBRARY_VALIDATION_KEY" "$signing_entitlements" 2>/dev/null || true
"$PLIST_BUDDY" -c "Add :$LIBRARY_VALIDATION_KEY bool true" "$signing_entitlements"
if grep -q "$DYLD_ENV_KEY" "$signing_entitlements"; then
  fail "Entitlements $DYLD_ENV_KEY iceriyor; hardened runtime'i deler"
fi

frameworks_path="$app_path/Contents/Frameworks"
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
done < <(find "$app_path/Contents/MacOS" -type f -print0)

codesign "${sign_args[@]}" --generate-entitlement-der --entitlements "$signing_entitlements" "$app_path"
rm -f "$signing_entitlements"

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
mount_point=$(mktemp -d)
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
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
  CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  echo "$key=$(plist_get "$mounted_app" "$key")"
done
# Finder'in gosterecegi ad; denetim bilgi amaclidir (yerellestirme kosucunun diline bagli).
finder_name=$(SENSE_APP_PATH="$mounted_app" swift -e \
  'import Foundation; print(FileManager.default.displayName(atPath: ProcessInfo.processInfo.environment["SENSE_APP_PATH"]!))' \
  2>/dev/null || true)
echo "Finder adi: ${finder_name:-okunamadi}"
if [[ "$finder_name" != "$DISPLAY_NAME" ]]; then
  echo "::warning title=Finder adi::Beklenen '$DISPLAY_NAME', gorunen '${finder_name:-okunamadi}'"
fi

echo "== codesign"
codesign --verify --deep --strict --verbose=2 "$mounted_app"
signature=$(codesign -dv --verbose=4 "$mounted_app" 2>&1)
echo "$signature"
grep -q '^Signature=adhoc$' <<<"$signature" || fail "Imza ad-hoc degil"
grep -q '^TeamIdentifier=not set$' <<<"$signature" || fail "Ad-hoc imzada TeamIdentifier olmamali"
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
  fail "spctl Developer ID / notarization bildirdi; bu derleme ad-hoc olmali"
fi
if [[ "$spctl_status" -eq 0 ]]; then
  echo "::warning title=spctl::Ad-hoc imzali uygulama kabul edildi (beklenen: rejected)"
fi

# Ikili gercekten calisiyor mu (cerceveler ad-hoc imza + hardened runtime ile yukleniyor mu):
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
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### macOS paketi (ad-hoc imzali, notarization yok)"
    echo "- Dosya: \`$(basename "$dmg_path")\`"
    echo "- Boyut: $dmg_size bayt"
    echo "- SHA-256: \`$dmg_sha256\`"
    echo "- Imza: ad-hoc + hardened runtime; Gatekeeper ilk acilista uyarir (Sistem Ayarlari > Gizlilik ve Guvenlik > Yine de Ac)"
  } >> "$GITHUB_STEP_SUMMARY"
fi
