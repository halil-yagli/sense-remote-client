# Sense Remote: acilis duman testi (Windows). Paketlenmis SenseRemote.exe'yi kurmadan baslatir,
# ana pencerenin cizildigini dogrular. Sebep: Surum 4'te ana pencere govdesi siyah kaldi ama
# butun testler gecti (golden'lar ekranlari gercek sarmalayici olmadan ciziyor).
# Sense kabugu (rol ekranlari) YALNIZ kurulu rol varken acilir (src/sense.rs: HKLM\SOFTWARE\SenseRemote\Role
# -> sert ayarlar -> senseHomeRole). Rolsuz (tasinabilir) calisma stok RustDesk ekranini gosterir ve siyah
# govde hatasini gormez. Bu yuzden -Rol verilirse betik o kayit degerini yazar, sonda siler.
# DIKKAT: HKLM'ye yazar; yalniz CI runner'inda calistirilir (GITHUB_ACTIONS yoksa -Zorla ister).
# Kullanim: powershell -File tools/smoke/acilis-dumani.ps1 -Exe rustdesk\SenseRemote.exe -Rol both
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$OutDir = "smoke-out",
  [int]$BeklemeSn = 25,
  [double]$Esik = 0.02,       # basligin altindaki piksellerin en az bu orani koyu olmamali
  [int]$KoyuLimit = 60,       # parlaklik (0-255) bunun altindaysa piksel "koyu"
  [ValidateSet('', 'host', 'controller', 'both')][string]$Rol = '',
  [switch]$Zorla
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class Pnc {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<string> Bul(string baslik, uint[] pidler) {
    var sonuc = new List<string>();
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowTextW(h, sb, 256);
      uint pid; GetWindowThreadProcessId(h, out pid);
      bool pidTamam = Array.IndexOf(pidler, pid) >= 0;
      if (sb.ToString().Contains(baslik) || (pidTamam && sb.Length > 0)) sonuc.Add(h.ToInt64() + "|" + pid + "|" + sb);
      return true; }, IntPtr.Zero);
    return sonuc;
  }
}
'@

function Olc([System.Drawing.Bitmap]$bmp, [int]$ustAtla) {
  # Basligin altindaki alanda koyu olmayan piksel orani (ornekleme: her 2. piksel).
  $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
  $d = $bmp.LockBits($rect, 'ReadOnly', 'Format32bppArgb')
  $stride = $d.Stride
  $bayt = New-Object byte[] ($stride * $bmp.Height)
  [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $bayt, 0, $bayt.Length)
  $bmp.UnlockBits($d)
  $toplam = 0; $acik = 0
  for ($y = $ustAtla; $y -lt $bmp.Height; $y += 2) {
    $satir = $y * $stride
    for ($x = 0; $x -lt $bmp.Width; $x += 2) {
      $i = $satir + $x * 4
      $l = 0.114 * $bayt[$i] + 0.587 * $bayt[$i + 1] + 0.299 * $bayt[$i + 2]
      $toplam++
      if ($l -gt $KoyuLimit) { $acik++ }
    }
  }
  if ($toplam -eq 0) { return 0.0 }
  return [double]$acik / $toplam
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exeTam = (Resolve-Path $Exe).Path
$out = Join-Path $OutDir 'stdout.txt'
$err = Join-Path $OutDir 'stderr.txt'
$ozet = Join-Path $OutDir 'ozet.txt'
$log = New-Object System.Collections.Generic.List[string]
function Yaz($m) { Write-Host $m; $log.Add($m) }

$sess = (Get-Process -Id $PID).SessionId
Yaz "Oturum kimligi: $sess (0 = servis, GUI yok; >0 = etkilesimli masaustu)"
$ek = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize
Yaz ("Ekran: {0}x{1}" -f $ek.Width, $ek.Height)

$kayit = 'HKLM:\SOFTWARE\SenseRemote'
$kayitYazildi = $false
if ($Rol) {
  if ($env:GITHUB_ACTIONS -ne 'true' -and -not $Zorla) { throw "-Rol HKLM'ye yazar; yalniz CI'da ya da -Zorla ile" }
  New-Item -Path $kayit -Force | Out-Null
  New-ItemProperty -Path $kayit -Name Role -Value $Rol -PropertyType String -Force | Out-Null
  $kayitYazildi = $true
  Yaz "Kurulu rol yazildi (test): $Rol"
}

$p = Start-Process -FilePath $exeTam -WorkingDirectory (Split-Path $exeTam) -PassThru `
  -RedirectStandardOutput $out -RedirectStandardError $err
Yaz "Baslatildi: pid $($p.Id)"
$basarisiz = $null
$ad = [IO.Path]::GetFileNameWithoutExtension($exeTam)
try {
  Start-Sleep -Seconds $BeklemeSn
  if ($p.HasExited) { $basarisiz = "Uygulama $BeklemeSn sn dolmadan kapandi (cikis kodu $($p.ExitCode))" }

  # Ayni adli butun surecler (ana surec yardimci surec acabilir).
  $pidler = [uint32[]]@(Get-Process -Name $ad -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $pencereler = [Pnc]::Bul('Sense Remote', $pidler)
  Yaz ("Gorunur pencereler: " + ($pencereler -join ' ; '))
  $secili = $null
  foreach ($s in $pencereler) {
    $a = $s.Split('|', 3)
    if ($a[2] -like '*Sense Remote*') { $secili = [IntPtr][int64]$a[0]; break }
  }
  if (-not $secili -and -not $p.HasExited) {
    $p.Refresh()
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $secili = $p.MainWindowHandle }
  }
  if (-not $basarisiz -and -not $secili) { $basarisiz = "Ana pencere ('Sense Remote') bulunamadi" }

  if (-not $basarisiz) {
    [void][Pnc]::ShowWindow($secili, 9)   # SW_RESTORE
    [void][Pnc]::SetForegroundWindow($secili)
    Start-Sleep -Seconds 2
    $wr = New-Object Pnc+RECT
    $cr = New-Object Pnc+RECT
    [void][Pnc]::GetWindowRect($secili, [ref]$wr)
    [void][Pnc]::GetClientRect($secili, [ref]$cr)
    $w = $wr.R - $wr.L
    $h = $wr.B - $wr.T
    Yaz "Pencere: ${w}x${h}, istemci alani: $($cr.R)x$($cr.B)"
    if ($w -lt 100 -or $h -lt 100) { $basarisiz = "Pencere boyutu gecersiz (${w}x${h})" }
    else {
      # Baslik cubugunu atla: en az 40 px (ya da pencere-istemci yukseklik farki).
      $ustAtla = [Math]::Max(40, $h - $cr.B)
      $bmp = New-Object System.Drawing.Bitmap($w, $h)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $dc = $g.GetHdc()
      $ok = [Pnc]::PrintWindow($secili, $dc, 2)   # PW_RENDERFULLCONTENT
      $g.ReleaseHdc($dc)
      $g.Dispose()
      $oran = Olc $bmp $ustAtla
      $bmp.Save((Join-Path $OutDir 'pencere-printwindow.png'))
      Yaz ("PrintWindow ok={0}, koyu olmayan oran={1:P2}" -f $ok, $oran)
      $enIyi = $oran
      if ($oran -le $Esik) {
        # Yedek: ekrandan kopya (pencere on planda).
        try {
          [void][Pnc]::SetForegroundWindow($secili)
          Start-Sleep -Seconds 1
          $bmp2 = New-Object System.Drawing.Bitmap($w, $h)
          $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
          $g2.CopyFromScreen($wr.L, $wr.T, 0, 0, (New-Object System.Drawing.Size($w, $h)))
          $g2.Dispose()
          $oran2 = Olc $bmp2 $ustAtla
          $bmp2.Save((Join-Path $OutDir 'pencere-ekran.png'))
          Yaz ("CopyFromScreen koyu olmayan oran={0:P2}" -f $oran2)
          if ($oran2 -gt $enIyi) { $enIyi = $oran2 }
        } catch { Yaz "CopyFromScreen basarisiz: $($_.Exception.Message)" }
      }
      if ($enIyi -le $Esik) {
        $basarisiz = ("Acilis duman testi: ana pencere bos (en iyi oran {0:P2}, esik {1:P0})" -f $enIyi, $Esik)
      }

      # Sense kabugu denetimi: pencere erisilebilirlik agacindaki metinler (UI Automation; Flutter
      # anlamsal agaci istemci isteyince acar). Stok RustDesk metni varsa ya da hic Sense metni yoksa basarisiz.
      $adlar = @()
      try {
        $kok = [System.Windows.Automation.AutomationElement]::FromHandle($secili)
        for ($deneme = 0; $deneme -lt 5 -and $adlar.Count -lt 3; $deneme++) {
          $adlar = @($kok.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
            ForEach-Object { $_.Current.Name } | Where-Object { $_ -and $_ -ne 'FLUTTERVIEW' })
          if ($adlar.Count -lt 3) { Start-Sleep -Seconds 3 }
        }
      } catch { Yaz "UI Automation hatasi: $($_.Exception.Message)" }
      Yaz ("UIA metinleri ({0}): {1}" -f $adlar.Count, (($adlar | Select-Object -First 40) -join ' | '))
      $adlar | Set-Content -Encoding utf8 (Join-Path $OutDir 'uia-metinler.txt')
      $stok = @($adlar | Where-Object { $_ -match 'Control Remote Desktop|Enter remote ID|Your Desktop|One-time password' })
      $sense = @($adlar | Where-Object { $_ -match 'Bilgisayarlar|Bu bilgisayar|hesab.nla gir|Hakk.nda|Ayarlar' })
      if ($Rol -and $stok.Count -gt 0) {
        $basarisiz = (@($basarisiz, "Acilis duman testi: stok RustDesk ana sayfasi gorunuyor (Sense kabugu acilmadi): $($stok -join ', ')") | Where-Object { $_ }) -join ' | '
      } elseif ($Rol -and $adlar.Count -gt 0 -and $sense.Count -eq 0) {
        $basarisiz = (@($basarisiz, "Acilis duman testi: pencerede Sense metni yok") | Where-Object { $_ }) -join ' | '
      } elseif ($Rol -and $adlar.Count -eq 0) {
        Yaz "UYARI: erisilebilirlik agaci bos; yalniz piksel olcumu gecerli"
      }
    }
  }
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Get-Process -Name $ad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  if ($kayitYazildi) { Remove-Item -Path $kayit -Recurse -Force -ErrorAction SilentlyContinue }
}

# stdout/stderr hata isaretleri
$metin = ''
foreach ($f in @($out, $err)) {
  if (Test-Path $f) { $metin += [string](Get-Content -Raw -ErrorAction SilentlyContinue $f) }
}
Yaz ("stdout+stderr boyutu: {0} karakter" -f $metin.Length)
foreach ($desen in @('EXCEPTION CAUGHT', 'Unhandled')) {
  if ($metin -match [regex]::Escape($desen)) {
    $basarisiz = (@($basarisiz, "Cikti '$desen' iceriyor") | Where-Object { $_ }) -join ' | '
  }
}

if ($basarisiz) { Yaz "BASARISIZ: $basarisiz" } else { Yaz "BASARILI: ana pencere cizildi" }
$log | Set-Content -Encoding utf8 $ozet
if ($basarisiz) {
  Write-Output "::error title=Acilis duman testi::$basarisiz"
  exit 1
}
