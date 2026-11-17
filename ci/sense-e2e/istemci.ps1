# Sense Remote uctan uca testi (E4): Windows koşucusunda istemcinin kurulumu ve yönetimi.
# Yalnız GitHub Actions'taki tek kullanımlık Windows koşucusunda çalışır (yönetici yetkisi var).
# Hiçbir gizli değer yazmaz: cihazın GIZLI anahtarı yapılandırma dosyasında kalır, dışarı yalnız
# AÇIK anahtar (device_pk) çıkar; yapılandırma dosyası kanıt klasörüne kopyalanmaz.
#
# Islemler:
#   kur      -Uygulama <klasör> -Rol host|controller|host_controller
#            HKLM rol + kurulum bilgisi (kurulum sihirbazının yazdığıyla aynı biçim) -> --silent-install
#            -> servis çalışıyor mu.
#   kimlik   Servisin yapılandırmasından açık anahtar + MachineGuid'den uuid (istemcinin
#            encode64(get_uuid()) hesabı). JSON tek satır: {"uuid","pk"}.
#   durdur   Servisi durdur, kalan SenseRemote süreçlerini kapat.
#   baslat   Servisi başlat, çalışana dek bekle.
#   rol      -Rol <rol>: HKLM rolünü değiştir (servis yeniden başlatılınca uygulanır).
#   topla    -Hedef <klasör>: istemci logları + servis ve süreç bilgisi (anahtar dosyası YOK).
param(
  [Parameter(Mandatory = $true)][ValidateSet("kur", "kimlik", "durdur", "baslat", "rol", "topla")][string]$Islem,
  [string]$Uygulama = "",
  [ValidateSet("", "host", "controller", "host_controller")][string]$Rol = "",
  [string]$Hedef = ""
)

$ErrorActionPreference = "Stop"
$Servis = "SenseRemote"
$RegYol = "HKLM:\SOFTWARE\SenseRemote"
# Servis LocalSystem olarak çalışır; RustDesk yapılandırmasını LocalService profiline yazar.
$ServisVeri = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\SenseRemote"
$ServisToml = Join-Path $ServisVeri "config\SenseRemote.toml"

function Bekle([scriptblock]$Kosul, [int]$Saniye, [string]$Ne) {
  $son = (Get-Date).AddSeconds($Saniye)
  while ((Get-Date) -lt $son) {
    if (& $Kosul) { return }
    Start-Sleep -Seconds 2
  }
  throw "Zaman aşımı ($Saniye sn): $Ne"
}

# Kurulum sihirbazının rolü (sense.rs: SenseRole) HKLM'deki adıyla.
function RegRol([string]$r) {
  switch ($r) {
    "host" { "host" }
    "controller" { "controller" }
    "host_controller" { "both" }
    default { throw "rol gerekli" }
  }
}

function Yaz-Rol([string]$r) {
  if (-not (Test-Path $RegYol)) { New-Item -Path $RegYol -Force | Out-Null }
  New-ItemProperty -Path $RegYol -Name "Role" -Value (RegRol $r) -PropertyType String -Force | Out-Null
}

switch ($Islem) {
  "kur" {
    $exe = Join-Path $Uygulama "SenseRemote.exe"
    if (-not (Test-Path $exe)) { throw "$exe yok" }
    # sense.rs install_commands ile aynı: Role + Setup (SetupInfo JSON'unun hex'i; yalnız ad/konum).
    Yaz-Rol $Rol
    $bilgi = '{"name":"Sense CI","location":"GitHub Actions"}'
    $hex = -join ([Text.Encoding]::UTF8.GetBytes($bilgi) | ForEach-Object { $_.ToString("x2") })
    New-ItemProperty -Path $RegYol -Name "Setup" -Value $hex -PropertyType String -Force | Out-Null
    # --silent-install: sihirbazsız kurulum; HKLM'deki rolü korur (sense.rs pending_install_commands).
    $p = Start-Process -FilePath $exe -ArgumentList "--silent-install" -PassThru
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw "--silent-install 5 dakikada bitmedi" }
    $kurulu = "C:\Program Files\SenseRemote\SenseRemote.exe"
    Bekle { Test-Path $kurulu } 120 "kurulu program ($kurulu)"
    Bekle { (Get-Service -Name $Servis -ErrorAction SilentlyContinue).Status -eq "Running" } 180 "servis çalışıyor"
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Servis'"
    [pscustomobject]@{
      kuruldu = $true; servis = $svc.State; baslangic = $svc.StartMode
      rol = (Get-ItemProperty $RegYol).Role
    } | ConvertTo-Json -Compress
  }
  "kimlik" {
    # Anahtar çifti servis ilk açılışta üretir (Config::get_key_pair); dosyaya yazılana dek bekle.
    $desen = 'key_pair\s*=\s*\[\s*\[[\d\s,]*\]\s*,\s*\[([\d\s,]+)\]'
    Bekle { (Test-Path $ServisToml) -and ((Get-Content -Raw $ServisToml) -match $desen) } 300 "servis anahtar çifti"
    $null = (Get-Content -Raw $ServisToml) -match $desen
    [byte[]]$pk = $Matches[1].Split(",") | Where-Object { $_.Trim() -ne "" } | ForEach-Object { [byte]$_.Trim() }
    if ($pk.Length -ne 32) { throw "açık anahtar 32 bayt değil ($($pk.Length))" }
    $pkB64 = [Convert]::ToBase64String($pk).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    # hbb_common::get_uuid = machine-uid (Windows: MachineGuid); istemci base64 (dolgulu) gönderir.
    $guid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography").MachineGuid
    $uuid = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($guid))
    [pscustomobject]@{ uuid = $uuid; pk = $pkB64 } | ConvertTo-Json -Compress
  }
  "durdur" {
    Stop-Service -Name $Servis -Force -ErrorAction SilentlyContinue
    Bekle { (Get-Service -Name $Servis).Status -eq "Stopped" } 120 "servis durdu"
    Get-Process -Name "SenseRemote" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Bekle { -not (Get-Process -Name "SenseRemote" -ErrorAction SilentlyContinue) } 60 "SenseRemote süreçleri kapandı"
    '{"durdu":true}'
  }
  "baslat" {
    Start-Service -Name $Servis
    Bekle { (Get-Service -Name $Servis).Status -eq "Running" } 120 "servis çalışıyor"
    '{"basladi":true}'
  }
  "rol" {
    Yaz-Rol $Rol
    [pscustomobject]@{ rol = (Get-ItemProperty $RegYol).Role } | ConvertTo-Json -Compress
  }
  "topla" {
    New-Item -ItemType Directory -Force -Path $Hedef | Out-Null
    $kaynaklar = @(
      @{ ad = "servis-log"; yol = Join-Path $ServisVeri "log" },
      @{ ad = "kullanici-log"; yol = Join-Path $env:APPDATA "SenseRemote\log" }
    )
    foreach ($k in $kaynaklar) {
      if (Test-Path $k.yol) { Copy-Item -Recurse -Force $k.yol (Join-Path $Hedef $k.ad) }
    }
    # Süreçler (oturum numarası: sunucu sürecinin konsol oturumunda açılıp açılmadığı görünür).
    Get-CimInstance Win32_Process -Filter "Name='SenseRemote.exe'" |
      Select-Object ProcessId, SessionId, CreationDate, CommandLine |
      Format-List | Out-File -Encoding utf8 (Join-Path $Hedef "surecler.txt")
    Get-CimInstance Win32_Service -Filter "Name='$Servis'" |
      Select-Object Name, State, StartMode, PathName, StartName |
      Format-List | Out-File -Encoding utf8 (Join-Path $Hedef "servis.txt")
    if (Test-Path $RegYol) {
      Get-ItemProperty $RegYol | Select-Object Role, EnvelopeSeq |
        Format-List | Out-File -Encoding utf8 (Join-Path $Hedef "hklm.txt")
    }
    '{"toplandi":true}'
  }
}
