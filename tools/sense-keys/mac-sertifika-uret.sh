#!/usr/bin/env bash
# Sense Remote: Mac için KALICI, kendinden imzalı kod imzalama sertifikası üretir ve GitHub'a
# yazar. Bir kez, yerelde çalıştırılır (ücretsiz; Apple Developer ID değildir).
#
#   bash tools/sense-keys/mac-sertifika-uret.sh [--yedek <klasör>] [--repo <sahip/depo>]
#
# Ne yapar:
#   1. Sertifikayı (RSA 3072, 20 yıl) ve rastgele p12 parolasını geçici klasörde üretir.
#   2. Yedeğini (p12 + parola, tek dosya) verdiğiniz yerel klasöre yazar.
#   3. GitHub "imza" ortamına SENSE_MAC_CERT_P12 ve SENSE_MAC_CERT_PASSWORD sırlarını yazar.
#   4. SENSE_MAC_CERT_SHA1 (parmak izi) ve SENSE_MAC_SIGN=cert depo değişkenlerini yazar.
# Gizli anahtar ve parola ekrana, komut satırına ya da kabuk geçmişine yazılmaz. Ayrıntı: README.md.
set -euo pipefail
set +x
umask 077

# shellcheck source=tools/sense-keys/ortam-denetimi.sh
source "$(dirname "${BASH_SOURCE[0]}")/ortam-denetimi.sh"

readonly ENVIRONMENT="imza"
readonly P12_SECRET="SENSE_MAC_CERT_P12"
readonly PASSWORD_SECRET="SENSE_MAC_CERT_PASSWORD"
readonly SHA1_VARIABLE="SENSE_MAC_CERT_SHA1"
readonly MODE_VARIABLE="SENSE_MAC_SIGN"
readonly BACKUP_NAME="sense-remote-mac-sertifika-yedek.txt"
# Derleme betiği (.github/scripts/sense-macos-package.sh) imzada bu adı arar.
readonly COMMON_NAME="Sense Remote Code Signing"
readonly VALID_DAYS=7300

die() {
  echo "HATA: $*" >&2
  exit 1
}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

backup_dir=""
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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

openssl_bin=${OPENSSL:-openssl}
command -v "$openssl_bin" >/dev/null 2>&1 || die "openssl bulunamadı"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) bulunamadı"
gh auth status >/dev/null 2>&1 || die "gh girişli değil: önce 'gh auth login'"
if [[ -z "$repo" ]]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "Depo belirlenemedi; depo klasöründe çalıştırın ya da --repo sahip/depo verin"
fi
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "Depo adı sahip/depo biçiminde olmalı: $repo"

# Ortam önce elle açılmış ve yalnız master dalı + v* etiketiyle sınırlı olmalı.
check_environment "$repo" "$ENVIRONMENT" "branch:master" "tag:v*"

existing=$(gh variable list --repo "$repo" --json name --jq '.[].name') \
  || die "Depo değişkenleri okunamadı (gh yetkisi?)"
if grep -qx "$SHA1_VARIABLE" <<<"$existing" && [[ "${SENSE_KEYS_FORCE:-}" != "1" ]]; then
  die "$SHA1_VARIABLE zaten tanımlı: Mac sertifikası daha önce üretilmiş.
  Yeni sertifika yeni imza kimliği demektir: bütün Mac'lerde izinler bir kez yerinde yeniden
  verilir. Bilerek yenilemek için SENSE_KEYS_FORCE=1."
fi

if [[ -z "$backup_dir" ]]; then
  echo "Sertifika yedeği için EŞİTLENMEYEN yerel bir klasör yazın"
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
  # Yarıda kalırsa yedek de silinir: GitHub'a yazılmamış bir sertifikanın yedeği yanıltır.
  if $backup_written && ! $finished; then
    rm -f "$backup_file"
    echo "Yarıda kaldı: yedek dosyası silindi, betiği yeniden çalıştırın." >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# Göreli yollarla çalışılır (Git Bash'in yol çevirisi openssl bağımsız değişkenlerini bozmasın).
cd "$work"

# Konu ve uzantılar yapılandırma dosyasından (-subj Git Bash'te yol sanılıp bozuluyor).
cat > request.cnf <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $COMMON_NAME
O = Sense Department

[extensions]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

"$openssl_bin" req -x509 -newkey rsa:3072 -nodes -sha256 -days "$VALID_DAYS" -config request.cnf \
  -keyout key.pem -out cert.pem >/dev/null 2>&1 || die "Sertifika üretilemedi"

"$openssl_bin" rand -hex 24 | tr -d '\r\n' > password
[[ "$(wc -c < password | tr -d ' ')" == 48 ]] || die "Parola üretilemedi"

# macOS 'security import' yalnız eski p12 şifrelemesini okur (3DES + SHA-1 MAC). Bu seçenekler
# OpenSSL 3, 1.1 ve LibreSSL'de aynı dosya biçimini verir (-legacy sağlayıcısı gerekmez).
"$openssl_bin" pkcs12 -export -inkey key.pem -in cert.pem -name "$COMMON_NAME" -out cert.p12 \
  -passout file:password -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  >/dev/null 2>&1 || die "p12 üretilemedi"
rm -f key.pem

fingerprint=$("$openssl_bin" x509 -in cert.pem -noout -fingerprint -sha1 | sed 's/^.*=//' \
  | tr -d ':\r\n' | tr 'A-F' 'a-f')
[[ "$fingerprint" =~ ^[0-9a-f]{40}$ ]] || die "Parmak izi okunamadı"

"$openssl_bin" base64 -A -in cert.p12 > cert.p12.b64

{
  echo "Sense Remote — Mac kod imzalama sertifikası (yedek)"
  echo "ad: $COMMON_NAME"
  echo "sha1: $fingerprint"
  echo "GitHub: $P12_SECRET = aşağıdaki base64 metin, $PASSWORD_SECRET = aşağıdaki parola (ortam: $ENVIRONMENT)"
  printf 'parola: '
  cat password
  printf '\np12 (base64):\n'
  cat cert.p12.b64
  printf '\n'
} > "$backup_file"
chmod 600 "$backup_file"
backup_written=true

gh secret set "$P12_SECRET" --env "$ENVIRONMENT" --repo "$repo" < cert.p12.b64 >/dev/null \
  || die "Sır yazılamadı ($P12_SECRET, ortam $ENVIRONMENT)"
gh secret set "$PASSWORD_SECRET" --env "$ENVIRONMENT" --repo "$repo" < password >/dev/null \
  || die "Sır yazılamadı ($PASSWORD_SECRET, ortam $ENVIRONMENT)"
gh variable set "$SHA1_VARIABLE" --repo "$repo" --body "$fingerprint" >/dev/null \
  || die "Değişken yazılamadı ($SHA1_VARIABLE)"
gh variable set "$MODE_VARIABLE" --repo "$repo" --body "cert" >/dev/null \
  || die "Değişken yazılamadı ($MODE_VARIABLE)"
finished=true

cat <<EOF

Tamam. Mac imza sertifikası üretildi ve GitHub'a yazıldı ($repo).

  Parmak izi (gizli değil):
    $SHA1_VARIABLE = $fingerprint
    $MODE_VARIABLE = cert

Şimdi siz:
  1. Yedek dosyasını şirket şifre yöneticisine ekleyin (ad: "Sense Remote — Mac imza sertifikası"):
       $backup_file
  2. Ekledikten sonra yerel kopyayı silin.

Bundan sonraki master ve v* derlemeleri Mac paketini bu sertifikayla imzalar.
Sertifika kaybolursa yenisi yeni imza kimliği demektir: bütün Mac'lerde izinler yeniden verilir.
EOF
