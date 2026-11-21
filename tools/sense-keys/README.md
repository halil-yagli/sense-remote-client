# Sense Remote — imza anahtarları (bir kerelik kurulum)

Bu klasördeki betikler **yerelde, bir kez, depo yöneticisi tarafından** çalıştırılır. Depoda sır
yoktur: betikler gizli değeri üretir, doğrudan GitHub'a yazar ve yedeğini sizin verdiğiniz yerel
klasöre bırakır. Gizli değer ekrana, komut satırına ya da kabuk geçmişine yazılmaz.

| Betik | Ne üretir | Zorunlu mu |
| --- | --- | --- |
| `yapi-anahtari-uret.sh` | **Yapı anahtarı** (Ed25519). Her sürümde kurulum dosyalarının "yapı beyanı" bununla imzalanır; bilgisayarlar bu imza olmadan güncelleme kurmaz. | Evet (güncelleme için) |
| `yapi-anahtari-uret.sh --deneme` | **Deneme yapı anahtarı** (ayrı Ed25519). Yalnız `deneme_surumu` (900–999) derlemeleri için. | Deneme düzeni için |
| `mac-sertifika-uret.sh` | **Mac imza sertifikası** (kendinden imzalı, 20 yıl, ücretsiz). Mac paketleri hep aynı kimlikle imzalanır; amaç güncellemede Ekran Kaydı / Erişilebilirlik izinlerinin düşmemesi. | Ekip kararı (K-MAC-İMZA) |
| `test.sh` | Betiklerin testi: sahte `gh`, geçici deneme anahtarı. Gerçek hiçbir şeye dokunmaz. | — |
| `ortam-denetimi.sh` | Ortak işlev (betikler kaynak olarak alır): ortamın dal/etiket kuralını doğrular. | — |

## Gerekenler

- **Git Bash** (Windows) ya da **Terminal** (macOS).
- `gh` (GitHub CLI), depoda yönetici hesabıyla girişli: `gh auth status`.
- `openssl`. Yapı anahtarı için Ed25519 desteği gerekir: Git Bash'teki openssl yeterli; macOS'ta
  `brew install openssl@3` (betik Homebrew'daki sürümü kendisi bulur).

## 1. GitHub ortamlarını açın (tıklamayla, bir kez)

`github.com/<sahip>/sense-remote-client` › **Settings** › **Environments** › **New environment**

| Ortam | Deployment branches and tags › *Selected branches and tags* › Add deployment branch or tag rule |
| --- | --- |
| `surum` | Ref type **Tag**, ad deseni `v*` |
| `imza` | Ref type **Branch**, ad `master` — ve ayrıca Ref type **Tag**, ad deseni `v*` |
| `deneme` | Ref type **Branch**, ad `master` (yalnız deneme düzeni kurulacaksa) |

Betik sırrı yazmadan önce ortamı denetler ve şu durumlarda durur: ortam yok; *Selected branches
and tags* seçili değil (ör. *All branches*); kural listesi tablodakinden farklı (fazladan ya da
eksik kural). (Ortam önce açılmazsa GitHub onu korumasız oluştururdu; sır her daldan
okunabilirdi.)

**Öneri — `surum` ortamına onay:** aynı sayfada *Required reviewers* işaretleyin ve kendinizi
(ya da ikinci bir yöneticiyi) ekleyin. Etiket derlemesinin imza işi, biri **Approve** demeden
yapı anahtarına erişemez; ele geçirilmiş bir hesapla atılan etiket tek başına imzalı sürüm
üretemez. (Ücretsiz: herkese açık depoda ortam onayı ücretsizdir.)

## 2. Yapı anahtarı

Depo klasöründe:

```bash
bash tools/sense-keys/yapi-anahtari-uret.sh
```

1. Yedek için **eşitlenmeyen** yerel bir klasör sorar (Drive / OneDrive / Dropbox / depo klasörü
   kabul edilmez). Örnek: `C:/Users/<ad>/sense-yedek`.
2. Biter bitmez ekranda **açık anahtar** görünür: `SENSE_RELEASE_KEYS = <k>=<açık anahtar>`.
   Bu değer gizli değildir.
3. Yedek dosyasını (`sense-remote-yapi-anahtari.pem`) şirket şifre yöneticisine ekleyin
   (ad: `Sense Remote — yapı anahtarı`), sonra yerel kopyayı silin.
4. Aynı açık anahtar dizesini panelde `SR_RELEASE_KEYS` olarak girin
   (cPanel › Setup Node.js App › Environment variables › Save).

GitHub'da oluşanlar: ortam `surum` sırrı `SENSE_RELEASE_SIGNING_KEY`, depo değişkeni
`SENSE_RELEASE_KEYS`.

## 2a. Deneme yapı anahtarı (deneme düzeni için, isteğe bağlı)

Önce `deneme` ortamını açın (tablo: yalnız `master` dalı). Sonra:

```bash
bash tools/sense-keys/yapi-anahtari-uret.sh --deneme
```

Aynı düzen; yedek dosyası `sense-remote-deneme-yapi-anahtari.pem` (şifre yöneticisinde ad:
`Sense Remote — deneme yapı anahtarı`). GitHub'da oluşanlar: ortam `deneme` sırrı
`SENSE_TRIAL_RELEASE_SIGNING_KEY`, depo değişkeni `SENSE_TRIAL_RELEASE_KEYS`. Açık anahtarı
**yalnız deneme düzenindeki yerel panelde** `SR_RELEASE_KEYS` olarak kullanın; gerçek panele
girmeyin.

## 3. Mac imza sertifikası (ekip "evet" dediyse)

```bash
bash tools/sense-keys/mac-sertifika-uret.sh
```

Aynı düzen: yedek klasörü sorar; yedek dosyasını (`sense-remote-mac-sertifika-yedek.txt`, içinde
p12 + parola) şifre yöneticisine ekleyin (ad: `Sense Remote — Mac imza sertifikası`), yerel kopyayı
silin.

GitHub'da oluşanlar: ortam `imza` sırları `SENSE_MAC_CERT_P12` ve `SENSE_MAC_CERT_PASSWORD`, depo
değişkenleri `SENSE_MAC_CERT_SHA1` (parmak izi) ve `SENSE_MAC_SIGN=cert`.

Sonraki `master` ve `v*` derlemeleri Mac paketini bu sertifikayla imzalar. Vazgeçmek için
`SENSE_MAC_SIGN` değişkenini `adhoc` yapmak yeter (Settings › Secrets and variables › Actions ›
Variables).

Bilinmesi gerekenler:
- Gatekeeper ilk kurulumda yine uyarır ("Yine de Aç"); bu sertifika Apple onayı değildir.
- İzinlerin güncellemede korunması **cihazda sınanmadan kesin sayılmaz** (plan §7.2, M-U5).
- Ad-hoc imzadan sertifikaya geçiş izinleri bir kez düşürür.

## Derleme bu değerleri nasıl kullanır

| Durum | Dal / `master` / elle derleme | `v*` etiketi |
| --- | --- | --- |
| `SENSE_RELEASE_KEYS` boş | uyarı, derleme sürer | **düşer** (verify-tag) |
| `SENSE_RELEASE_SIGNING_KEY` yok | kullanılmaz | **düşer** (draft release) |
| `SENSE_MAC_SIGN` boş / `adhoc` | ad-hoc imza | ad-hoc imza (uyarı) |
| `SENSE_MAC_SIGN=cert`, sırlar yok | uyarı, ad-hoc imza | **düşer** |
| `SENSE_MAC_SIGN=cert`, sırlar var | sertifika imzası (yalnız `master`; başka dal `imza` ortamına erişemez → uyarı, ad-hoc) | sertifika imzası + DR denetimi |

Derleme ayrıca şunlarda durur (etikette her zaman; anahtar listelerinden biri tanımlıysa her
derlemede): yapı anahtarı ile panel anahtarı (`SENSE_ENVELOPE_KEYS`) aynıysa — iki imza kuralı
tek imzaya düşerdi —; deneme listesi (`SENSE_TRIAL_RELEASE_KEYS`) üretim yapı listesiyle ya da
panel listesiyle kesişiyorsa; listelerden birinde ortak test vektörünün deneme anahtar kimliği
varsa; bir listede satır sonu, CR, sekme ya da `[0-9A-Za-z_=, -]` dışı karakter varsa. Yapı beyanının yükü JCS (RFC 8785) kanonik JSON'dur; test, imzalayıcının çıktısını ortak
vektördeki `build_ok` vakasıyla bayt bayt karşılaştırır.

Etiket derlemesi taslak sürüme iki kurulum dosyası, `SHA256SUMS.txt` ve iki yapı beyanı ekler:
`SenseRemote-Kurulum-<n>.exe.yapi.json`, `SenseRemote-<n>.dmg.yapi.json`. Beyan biçimi `{k,p,s}`
(`.github/scripts/sense-sign-build.sh` başındaki açıklama). İş, imzayı gizli anahtar olmadan,
`SENSE_RELEASE_KEYS` ile yeniden doğrular.

Mac imzası ayrı bir işte atılır (`macos-sign`): derleme işi (`macos`) sırsız çalışır ve imzasız
uygulamayı yükler; imza işi yalnız depodaki betikleri ve sistem araçlarını kullanır, sırlar
yalnız imza adımına verilir, dmg ve doğrulama (uygulamanın `--version` ile çalıştırılması dahil)
sırsız sonraki adımdadır.

Deneme derlemesi: Actions › *Sense Remote build* › Run workflow › dal **master** ›
`deneme_surumu` = 900–999. Yalnız `master`'da ve `SENSE_TRIAL_RELEASE_KEYS` tanımlıyken çalışır.
İstemciye **yalnız deneme listesi** gömülür (üretim listesi girmez); `trial-sign` işi (`deneme`
ortamı) beyanları deneme anahtarıyla imzalar, doğrular ve `sense-remote-trial-statements`
artifact'ı olarak ekler. Sonuç: deneme sürümü kurulan cihaz gerçek sürümleri (ör. v3)
**doğrulayamaz**; gerçek sürüme elle yeniden kurulumla geçer.

## Anahtar değiştirme ve kayıp

- **Yapı anahtarı değiştirme** (planlı): istemci birden çok açık anahtar kabul eder.
  (1) Yeni anahtarı ayrı üretin, açık anahtarını `SENSE_RELEASE_KEYS` listesine **ekleyin**
  (`eski,yeni`; panelde `SR_RELEASE_KEYS` de aynı). (2) Bu listeyle bir sürüm yayınlayın (hâlâ eski
  anahtarla imzalı). (3) Bilgisayarlar o sürüme geçince `surum` ortamındaki sırrı yeni anahtarla
  değiştirin; sonraki sürüm yeni anahtarla imzalanır. Betik var olan anahtarın üzerine yazmaz;
  bilerek sıfırlamak için `SENSE_KEYS_FORCE=1` (kurulu bilgisayarlar eski anahtarı tanımaya devam
  eder, yenisini tanımaz).
- **Yapı anahtarı kaybolursa** (GitHub sırrı da silinmişse): kurulu bilgisayarlar yeni sürümü
  doğrulayamaz; her birinde elle kurulum gerekir. Yedek bu yüzden şart.
- **Mac sertifikası kaybolursa:** yeni sertifika yeni imza kimliğidir; bütün Mac'lerde izinler bir
  kez yerinde yeniden verilir.
- **Sızıntı şüphesi:** GitHub'da sırrı silin, yukarıdaki değiştirme adımlarını izleyin, ana
  oturuma bildirin.

## Test

```bash
bash tools/sense-keys/test.sh
```

GitHub yerine geçici bir sahte `gh` kullanır; her koşuda yeni deneme anahtarı üretir ve siler.
Linux / Git Bash'te üretim betikleri + yapı beyanı imzası; macOS'ta ek olarak sertifika imza yolu
(geçici anahtar zinciri, deneme paketi, DR denetimi). CI çalıştırır: her derlemede
(`sense-build.yml`: `signing scripts and inputs` ve `macos-sign`) ve bu betikleri değiştiren
her PR'da (`sense-pr.yml`: `signing scripts (linux)`; shellcheck + test, sırsız).

Windows notu: NTFS'te `chmod 600` etkisizdir; yedek dosyası klasörün Windows izinlerini alır.
Yedeği kullanıcı profilinizin içindeki bir klasöre yazın ve şifre yöneticisine ekler eklemez silin.
