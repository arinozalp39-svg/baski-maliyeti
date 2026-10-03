# =============================================================================
#  Baski Maliyeti - Bambu Studio koprusu (Windows)                     surum 1.0
#
#  NE YAPAR
#    Bambu Studio her dilimlemeden sonra bu dosyayi calistirir. Dosya, G-code'un
#    basindaki ozet satirlarindan baski suresini ve filament gramini okur ve
#    sana ozel kanala gonderir. Baski Maliyeti sitesi o kanali dinler.
#
#  NE GONDERIR
#    Sure, gram, katman sayisi, yazici / nozul / islem / filament adi.
#    Model dosyasi ve G-code GONDERILMEZ. G-code'a DOKUNULMAZ (yalnizca okunur).
#
#  NEREYE GONDERIR
#    https://ntfy.sh/<kanal-kodun>   (ucretsiz, acik kaynak bildirim servisi)
#
#  KURULUM
#    Kolay:  dosyaya sag tikla > "PowerShell ile calistir" > E
#    Elle:   Bambu Studio > Islem > Diger > Islem sonrasi betikler kutusuna
#            sitenin verdigi satiri yapistir (bu dosya hicbir seyi degistirmez)
#  KALDIRMA
#    Ayni sekilde calistir > K
#
#  Kaynak ve aciklama: sitedeki "Kopru ne yapiyor?" sayfasi ve GitHub deposu.
# =============================================================================
param(
  [Parameter(Position = 0)][string]$GcodeYolu,   # Bambu Studio bunu kendisi verir
  [string]$Kanal,                                 # sana ozel kanal kodu (sitede yazar)
  [string]$Sunucu = $(if ($env:BASKI_SUNUCU) { $env:BASKI_SUNUCU } else { "https://ntfy.sh" }),  # aktarim servisi
  [switch]$Kaldir,
  [switch]$Sessiz
)
$ErrorActionPreference = "Stop"
# Dilimleme sirasinda ne olursa olsun Bambu Studio'ya "tamam" don: dilimleme asla durmasin
trap { if ($GcodeYolu) { exit 0 } else { Write-Host $_ -ForegroundColor Red; break } }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Klasorler (BASKI_* degiskenleri yalnizca test icindir) ---
$yerel  = if ($env:BASKI_LOCALAPPDATA) { $env:BASKI_LOCALAPPDATA } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
$roam   = if ($env:BASKI_APPDATA) { $env:BASKI_APPDATA } else { $env:APPDATA }
$winDir = if ($env:SystemRoot) { $env:SystemRoot } else { "C:\Windows" }
$psExe  = if ($env:BASKI_PSEXE) { $env:BASKI_PSEXE } else { $winDir + "\System32\WindowsPowerShell\v1.0\powershell.exe" }
$klasor = [IO.Path]::Combine($yerel, "BaskiKopru")
$hedef  = [IO.Path]::Combine($klasor, "baski-kopru.ps1")
$kanalDosyasi = [IO.Path]::Combine($klasor, "kanal.txt")

function KanalGecerli([string]$k) { return ($k -match '^baski-[a-z0-9]{16,40}$') }

# =============================================================================
# 1) DILIMLEME: Bambu Studio bu dosyayi G-code yoluyla cagirdi
# =============================================================================
if ($GcodeYolu) {
  try {
    if (-not $Kanal -and (Test-Path $kanalDosyasi)) { $Kanal = ([IO.File]::ReadAllText($kanalDosyasi)).Trim() }
    if (-not (KanalGecerli $Kanal)) { exit 0 }

    # G-code'un yalnizca ilk 64 KB'ini oku (ozet orada); dosyayi kilitleme, degistirme
    $fs = [IO.File]::Open($GcodeYolu, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $buf = New-Object byte[] 65536; $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
    $bas = [Text.Encoding]::UTF8.GetString($buf, 0, $n)

    # Ornek satirlar:  "; model printing time: 17m 6s; total estimated time: 22m 14s"
    #                  "; total filament weight [g] : 7.21"   (cok renkte: 3.20,4.01)
    $sure    = [regex]::Match($bas, "total estimated time:\s*([^\r\n;]+)")
    $model   = [regex]::Match($bas, "model printing time:\s*([^\r\n;]+)")
    $agirlik = [regex]::Match($bas, "total filament weight \[g\]\s*:\s*([0-9.,]+)")
    $katman  = [regex]::Match($bas, "total layer number:\s*(\d+)")
    if (-not ($sure.Success -and $agirlik.Success)) { exit 0 }

    function Saniye([string]$s) {           # "1d 2h 3m 4s" -> saniye
      $t = 0
      foreach ($p in @(@("d", 86400), @("h", 3600), @("m", 60), @("s", 1))) {
        $m = [regex]::Match($s, "(\d+)" + $p[0] + "\b")
        if ($m.Success) { $t += [int]$m.Groups[1].Value * $p[1] }
      }
      return $t
    }
    function Ozet([string]$metin) {         # dosya yolunun kisa ozeti (yolun kendisi gonderilmez)
      $h = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($metin.ToLowerInvariant()))
      return ([BitConverter]::ToString($h, 0, 6)).Replace("-", "").ToLowerInvariant()
    }

    $ic = [Globalization.CultureInfo]::InvariantCulture
    $gramlar = @($agirlik.Groups[1].Value.Split(",") | Where-Object { $_ -ne "" } | ForEach-Object { [double]::Parse($_, $ic) })
    $toplam = 0.0; foreach ($x in $gramlar) { $toplam += $x }
    $yol = [IO.Path]::GetFullPath($GcodeYolu)

    # Bambu Studio ayarlari ortam degiskeni olarak verir (SLIC3R_...)
    $veri = @{
      v        = 1
      sn       = (Saniye $sure.Groups[1].Value)
      model_sn = $(if ($model.Success) { Saniye $model.Groups[1].Value } else { 0 })
      g        = [math]::Round($toplam, 2)
      gramlar  = $gramlar
      katman   = $(if ($katman.Success) { [int]$katman.Groups[1].Value } else { 0 })
      yazici   = "$env:SLIC3R_PRINTER_MODEL"
      makine   = "$env:SLIC3R_PRINTER_SETTINGS_ID"
      nozul    = "$env:SLIC3R_NOZZLE_DIAMETER"
      islem    = "$env:SLIC3R_PRINT_SETTINGS_ID"
      filament = "$env:SLIC3R_FILAMENT_SETTINGS_ID"
      ftur     = "$env:SLIC3R_FILAMENT_TYPE"
      plaka    = (Ozet $yol)                                     # ayni plaka yeniden dilimlenince ust uste yazilsin
      proje    = (Ozet ([IO.Path]::GetDirectoryName($yol)))      # baska projeye gecince liste sifirlansin
      zaman    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    $json = $veri | ConvertTo-Json -Compress -Depth 4
    Invoke-RestMethod -Method Post -Uri ($Sunucu.TrimEnd("/") + "/" + $Kanal) -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
      -ContentType "text/plain; charset=utf-8" -TimeoutSec 5 | Out-Null
  } catch {
    try { Add-Content -Path ([IO.Path]::Combine($klasor, "hata.log")) -Value ((Get-Date).ToString("s") + " " + $_.Exception.Message) -Encoding UTF8 } catch {}
  }
  exit 0
}

# =============================================================================
# 2) KOLAY KURULUM / KALDIRMA (dosya elle calistirildiginda)
#    Bambu Studio'nun her markadaki islem ayarlarinin kok dosyasina
#    (system\<marka>\process\fdm_process_common.json) "post_process" satiri ekler.
#    Boylece butun yazicilarda ve butun islem ayarlarinda calisir.
# =============================================================================
function Yaz($t, $renk = "Gray") { if (-not $Sessiz) { Write-Host $t -ForegroundColor $renk } }
$isaret = "baski-kopru.ps1"   # kurulan satiri tanimak icin

function Satir([string]$k) { return "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hedef`" -Kanal $k" }

function ProfilleriDuzenle([bool]$ekle, [string]$k) {
  $kok = [IO.Path]::Combine($roam, "BambuStudio", "system")
  if (-not (Test-Path $kok)) { return -1 }
  $sayi = 0
  $desen = '"post_process"\s*:\s*\[[^\]]*' + [regex]::Escape($isaret) + '[^\]]*\]\s*,?\s*'
  foreach ($f in Get-ChildItem -Path $kok -Recurse -Filter "fdm_process_common.json" -ErrorAction SilentlyContinue) {
    if ($f.FullName -notmatch "[\\/]process[\\/]fdm_process_common\.json$") { continue }
    $metin = [IO.File]::ReadAllText($f.FullName)
    $yeni = [regex]::Replace($metin, $desen, "")                 # eski kopru satirini cikar
    if ($ekle) {
      if ($yeni -match '"post_process"\s*:') { continue }        # baska bir betik varsa dokunma
      $i = $yeni.IndexOf("{"); if ($i -lt 0) { continue }
      $kacis = (Satir $k).Replace("\", "\\").Replace('"', '\"')
      $yeni = $yeni.Substring(0, $i + 1) + "`n    `"post_process`": [`"$kacis`"]," + $yeni.Substring($i + 1)
    }
    if ($yeni -ne $metin) { [IO.File]::WriteAllText($f.FullName, $yeni, (New-Object Text.UTF8Encoding $false)) }
    $sayi++
  }
  return $sayi
}

$bk = [Environment]::GetFolderPath("Startup")
$baslangic = if ($bk) { [IO.Path]::Combine($bk, "BaskiKopru.lnk") } else { $null }

# Kanal kodu: parametre > dosya adi (baski-kopru-<kod>.ps1) > daha once kaydedilen > sor
if (-not $Kanal -and $PSCommandPath) {
  $m = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($PSCommandPath), "(baski-[a-z0-9]{16,40})")
  if ($m.Success) { $Kanal = $m.Groups[1].Value }
}
if (-not $Kanal -and (Test-Path $kanalDosyasi)) { $Kanal = ([IO.File]::ReadAllText($kanalDosyasi)).Trim() }

if (-not $Kaldir -and -not $Sessiz) {
  Yaz "`n=== Baski Maliyeti - Bambu Studio koprusu ===`n" Cyan
  Yaz "Kurulunca Bambu Studio'da her dilimlemede sure ve gram siteye kendiliginden gelir."
  Yaz "Gonderilen: sure, gram, yazici, nozul, islem, filament adi. Model dosyasi gonderilmez.`n"
  $c = Read-Host "Kurulsun mu? (E = kur, K = kaldir)"
  if ($c -match "^[kK]") { $Kaldir = $true } elseif ($c -notmatch "^[eEyY]") { exit 0 }
}

if ($Kaldir) {
  $n = ProfilleriDuzenle $false ""
  if ($baslangic) { Remove-Item $baslangic -Force -ErrorAction SilentlyContinue }
  Remove-Item $klasor -Recurse -Force -ErrorAction SilentlyContinue
  Yaz "Kopru kaldirildi. Bambu Studio'yu kapatip ac." Green
  if (-not $Sessiz) { Read-Host "Kapatmak icin Enter" | Out-Null }
  exit 0
}

while (-not (KanalGecerli $Kanal)) {
  if ($Sessiz) { exit 1 }
  $Kanal = (Read-Host "Sitedeki kanal kodunu yapistir (baski- ile baslar)").Trim()
}

# Kendini sabit bir yere kopyala (Indirilenler temizlense de calissin)
New-Item -ItemType Directory -Force -Path $klasor | Out-Null
if ($PSCommandPath -and ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($hedef))) { Copy-Item -LiteralPath $PSCommandPath -Destination $hedef -Force }
[IO.File]::WriteAllText($kanalDosyasi, $Kanal)

$n = ProfilleriDuzenle $true $Kanal
if ($n -lt 0) {
  Yaz "Bambu Studio ayar klasoru bulunamadi. Bambu Studio'yu bir kez acip kapat, sonra tekrar calistir." Red
  if (-not $Sessiz) { Read-Host "Kapatmak icin Enter" | Out-Null }
  exit 1
}

# Bambu Studio profillerini guncellerse satir silinebilir: oturum acilisinda sessizce yeniden ekle
if (-not $Sessiz -and $baslangic) {
  try {
    $k = (New-Object -ComObject WScript.Shell).CreateShortcut($baslangic)
    $k.TargetPath = $psExe
    $k.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$hedef`" -Sessiz"
    $k.WindowStyle = 7
    $k.Save()
  } catch { Yaz "Baslangic kisayolu olusturulamadi (onemli degil)." DarkYellow }
}
if ($Sessiz) { exit 0 }

try {
  $j = @{ v = 1; kurulum = $true; zaman = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri ($Sunucu.TrimEnd("/") + "/" + $Kanal) -Body ([Text.Encoding]::UTF8.GetBytes($j)) -ContentType "text/plain; charset=utf-8" -TimeoutSec 5 | Out-Null
  Yaz "Siteye baglanti denemesi gonderildi." Green
} catch { Yaz "Siteye ulasilamadi: $($_.Exception.Message)" Red }

Yaz "`nKuruldu ($n ayar dosyasi). Bambu Studio'yu kapatip ac ve bir plakayi dilimle." Green
Read-Host "Kapatmak icin Enter" | Out-Null
