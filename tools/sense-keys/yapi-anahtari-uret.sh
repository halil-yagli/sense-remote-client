#!/usr/bin/env bash
# Sense Remote: YAPI ANAHTARI (Ed25519) üretir ve GitHub'a yazar. Bir kez, yerelde çalıştırılır.
#
#   bash tools/sense-keys/yapi-anahtari-uret.sh [--deneme] [--yedek <klasör>] [--repo <sahip/depo>]
#
# Ne yapar:
#   1. Gizli anahtarı geçici klasörde üretir (çıkışta silinir).
#   2. Yedeğini verdiğiniz yerel klasöre yazar (şirket şifre yöneticisine eklemeniz için).
#   3. Gizli anahtarı GitHub "surum" ortamına SENSE_RELEASE_SIGNING_KEY sırrı olarak yazar.
#   4. Açık anahtarı SENSE_RELEASE_KEYS depo değişkenine yazar ve ekranda gösterir.
# --deneme: AYRI bir deneme yapı anahtarı (deneme_surumu 900-999 derlemeleri için): ortam
#   "deneme" (yalnız master), sır SENSE_TRIAL_RELEASE_SIGNING_KEY, değişken
#   SENSE_TRIAL_RELEASE_KEYS. Üretim anahtarıyla hiçbir ilgisi yoktur.
# Gizli anahtar ekrana, komut satırına ya da kabuk geçmişine yazılmaz. Ayrıntı: README.md.
set -euo pipefail
set +x
umask 077

# shellcheck source=tools/sense-keys/ortam-denetimi.sh
source "$(dirname "${BASH_SOURCE[0]}")/ortam-denetimi.sh"

die() {
  echo "HATA: $*" >&2
  exit 1
}

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

backup_dir=""
repo=""
trial=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deneme)
      trial=true
      shift
      ;;
    --yedek)
      backup_dir=${2:-}
      shift 2 || die "--yedek bir klasör ister"
      ;;
    --repo)
      repo=${2:-}
      shift 2 || die "--repo sahip/depo ister"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Bilinmeyen seçenek: $1" ;;
  esac
done

if $trial; then
  readonly ENVIRONMENT="deneme"
  readonly ENVIRONMENT_RULES=("branch:master")
  readonly SECRET_NAME="SENSE_TRIAL_RELEASE_SIGNING_KEY"
  readonly VARIABLE_NAME="SENSE_TRIAL_RELEASE_KEYS"
  readonly BACKUP_NAME="sense-remote-deneme-yapi-anahtari.pem"
  readonly KEY_LABEL="deneme yapı anahtarı"
else
  readonly ENVIRONMENT="surum"
  readonly ENVIRONMENT_RULES=("tag:v*")
  readonly SECRET_NAME="SENSE_RELEASE_SIGNING_KEY"
  readonly VARIABLE_NAME="SENSE_RELEASE_KEYS"
  readonly BACKUP_NAME="sense-remote-yapi-anahtari.pem"
  readonly KEY_LABEL="yapı anahtarı"
fi

# Ed25519 üretebilen openssl (macOS'un kendi openssl'i LibreSSL olabilir; Homebrew'unki denenir).
find_openssl() {
  local candidate
  for candidate in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl; do
    if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" genpkey -algorithm ed25519 >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Yedek klasörü bulutla eşitlenen ya da depoya giren bir yer olmamalı.
check_backup_dir() {
  local dir=$1 lowered
  [[ -d "$dir" ]] || die "Yedek klasörü yok: $dir"
  [[ -w "$dir" ]] || die "Yedek klasörüne yazılamıyor: $dir"
  lowered=$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *drive* | *dropbox* | *icloud* | *"mobile documents"* | *cloudstorage*)
      die "Yedek klasörü bulutla eşitlenen bir yer gibi görünüyor: $dir (eşitlenmeyen yerel bir klasör verin)"
      ;;
  esac
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Yedek klasörü bir git deposunun içinde: $dir"
  fi
  [[ ! -e "$dir/$BACKUP_NAME" ]] || die "Yedek dosyası zaten var: $dir/$BACKUP_NAME (önce onu kaldırın)"
}

openssl_bin=$(find_openssl) || die "Ed25519 destekleyen openssl bulunamadı (macOS: brew install openssl@3)"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) bulunamadı"
gh auth status >/dev/null 2>&1 || die "gh girişli değil: önce 'gh auth login'"
if [[ -z "$repo" ]]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "Depo belirlenemedi; depo klasöründe çalıştırın ya da --repo sahip/depo verin"
fi
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "Depo adı sahip/depo biçiminde olmalı: $repo"

# Ortam önce elle açılmış ve yalnız beklenen dal/etiket kuralıyla sınırlı olmalı.
check_environment "$repo" "$ENVIRONMENT" "${ENVIRONMENT_RULES[@]}"

existing=$(gh variable list --repo "$repo" --json name --jq '.[].name') \
  || die "Depo değişkenleri okunamadı (gh yetkisi?)"
if grep -qx "$VARIABLE_NAME" <<<"$existing" && [[ "${SENSE_KEYS_FORCE:-}" != "1" ]]; then
  die "$VARIABLE_NAME zaten tanımlı: $KEY_LABEL daha önce üretilmiş.
  Yeni anahtar, kurulu bilgisayarların tanımadığı bir anahtardır (güncelleme alamazlar).
  Anahtar değiştirme adımları README.md'de; bilerek sıfırlamak için SENSE_KEYS_FORCE=1."
fi

if [[ -z "$backup_dir" ]]; then
  echo "Gizli anahtarın yedeği için EŞİTLENMEYEN yerel bir klasör yazın"
  echo "(Drive / OneDrive / Dropbox / depo klasörü olmaz; örnek: C:/Users/<ad>/sense-yedek):"
  read -r backup_dir
fi
[[ -n "$backup_dir" ]] || die "Yedek klasörü verilmedi"
check_backup_dir "$backup_dir"
backup_dir=$(cd "$backup_dir" && pwd)
backup_file="$backup_dir/$BACKUP_NAME"

work=$(mktemp -d)
backup_written=false
finished=false
# shellcheck disable=SC2317  # trap ile çağrılır
cleanup() {
  cd /
  rm -rf "$work"
  # Yarıda kalırsa yedek de silinir: GitHub'a yazılmamış bir anahtarın yedeği yanıltır.
  if $backup_written && ! $finished; then
    rm -f "$backup_file"
    echo "Yarıda kaldı: yedek dosyası silindi, betiği yeniden çalıştırın." >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# Göreli yollarla çalışılır (Git Bash'in yol çevirisi openssl bağımsız değişkenlerini bozmasın).
cd "$work"

"$openssl_bin" genpkey -algorithm ed25519 -out key.pem 2>/dev/null || die "Anahtar üretilemedi"
"$openssl_bin" pkey -in key.pem -pubout -outform DER -out public.der 2>/dev/null \
  || die "Açık anahtar çıkarılamadı"
[[ "$(wc -c < public.der | tr -d ' ')" == 44 ]] || die "Beklenmeyen açık anahtar boyutu"
tail -c 32 public.der > public.raw
key_id=$("$openssl_bin" dgst -sha256 -r public.raw | cut -c1-16)
public_key=$("$openssl_bin" base64 -A -in public.raw | tr '+/' '-_' | tr -d '=')
[[ "$key_id" =~ ^[0-9a-f]{16}$ && "${#public_key}" == 43 ]] || die "Açık anahtar biçimi beklenmedik"

cp key.pem "$backup_file"
chmod 600 "$backup_file"
backup_written=true

gh secret set "$SECRET_NAME" --env "$ENVIRONMENT" --repo "$repo" < key.pem >/dev/null \
  || die "Sır yazılamadı ($SECRET_NAME, ortam $ENVIRONMENT)"
gh variable set "$VARIABLE_NAME" --repo "$repo" --body "$key_id=$public_key" >/dev/null \
  || die "Değişken yazılamadı ($VARIABLE_NAME)"
finished=true

if $trial; then
  cat <<EOF

Tamam. DENEME yapı anahtarı üretildi ve GitHub'a yazıldı ($repo, ortam $ENVIRONMENT).

  Açık anahtar (gizli değil):
    $VARIABLE_NAME = $key_id=$public_key

Şimdi siz:
  1. Yedek dosyasını şirket şifre yöneticisine ekleyin (ad: "Sense Remote — deneme yapı anahtarı"):
       $backup_file
  2. Ekledikten sonra yerel kopyayı silin.
  3. Bu değeri YALNIZ deneme düzenindeki yerel panelde SR_RELEASE_KEYS olarak kullanın;
     gerçek panele (cPanel) GİRMEYİN.

deneme_surumu ile derlenen istemci yalnız bu anahtarı tanır: deneme sürümü kurulan cihaz gerçek
sürüme (v3) elle yeniden kurulumla geçer.
EOF
  exit 0
fi

cat <<EOF

Tamam. Yapı anahtarı üretildi ve GitHub'a yazıldı ($repo).

  Açık anahtar (gizli değil):
    $VARIABLE_NAME = $key_id=$public_key

Şimdi siz:
  1. Yedek dosyasını şirket şifre yöneticisine ekleyin (ad: "Sense Remote — yapı anahtarı"):
       $backup_file
  2. Ekledikten sonra yerel kopyayı silin.
  3. Yukarıdaki açık anahtar satırını panelde SR_RELEASE_KEYS olarak girin
     (cPanel › Setup Node.js App › Environment variables); değer aynı dize: $key_id=$public_key

Yedek kaybolursa kurulu bilgisayarlar yeni sürümü doğrulayamaz; her birinde elle kurulum gerekir.
EOF
