# ============================================================
# OS-FORGE ядро: inject.ps1 (v0.1)
# Роль: монтирование ISO -> вживление autounattend + драйверов ->
#       пересборка через встроенный IMAPI2 -> артефакт с SHA256.
# Законы: ноль админа; ISO9660+Joliet+UDF (install.wim > 4 ГБ);
#         одна El Torito запись — EFI (IMAPI2 умеет только одну);
#         журнал в момент такта.
# ============================================================
param(
  [string]$IsoPath,
  [string]$WorkDir,
  [string]$OutIso,
  [string]$TmplPath,
  [string]$CatalogDir,
  [string]$DriversDir,
  [string]$LocalUser,
  [string]$LocalPass,
  [string]$ImageName
)
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Host ("[ЯДРО/INJECT] " + $m) }

if (-not (Test-Path $IsoPath)) { throw "ОТКАЗ: нет образа $IsoPath" }
if (-not (Test-Path $TmplPath)) { throw "ОТКАЗ: нет шаблона ответов $TmplPath" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$media = Join-Path $WorkDir 'media'
if (Test-Path $media) { Remove-Item $media -Recurse -Force }
New-Item -ItemType Directory -Force -Path $media | Out-Null

# --- 1. Монтирование и извлечение -----------------------------------
Log 'Монтирую оригинальный ISO (встроенный Mount-DiskImage)...'
$img = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
  $drive = ($img | Get-Volume).DriveLetter
  $src = ($drive + ':\')
  Log ("Копирую содержимое {0} -> {1} (robocopy, это несколько минут)..." -f $src, $media)
  robocopy $src $media /E /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy вернул код $LASTEXITCODE — копия образа не полна, продолжать нельзя (карта не равна территории)" }
} finally {
  Dismount-DiskImage -ImagePath $IsoPath | Out-Null
  Log 'Образ размонтирован.'
}

# --- 2. Пункты тюнинга из каталога -> FirstLogonCommands ------------
Log 'Читаю АКТИВНЫЕ пункты тюнинга из каталога...'
$cmdsXml = New-Object System.Collections.Generic.List[string]
$order = 1
Get-ChildItem -Path $CatalogDir -Filter '*.txt' -ErrorAction SilentlyContinue |
  ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Encoding UTF8 |
      Where-Object { $_ -like 'ACTIVE|*tuning-win*' } |
      ForEach-Object {
        $p = $_.Split('|')
        if ($p.Count -ge 5 -and $p[3].Trim().Length -gt 0) {
          $c = '<SynchronousCommand wcm:action="add"><Order>{0}</Order><Description>OSFORGE:{1}</Description><CommandLine>cmd /c {2}</CommandLine></SynchronousCommand>' -f $order, $p[1], $p[3]
          $cmdsXml.Add($c); $order++
          Log ("  пункт ACTIVE: {0} -> {1}" -f $p[1], $p[3])
        }
      }
  }

# --- 3. autounattend.xml из шаблона ---------------------------------
Log 'Генерирую autounattend.xml (ответы установщика)...'
$t = Get-Content -LiteralPath $TmplPath -Raw -Encoding UTF8
$t = $t.Replace('{{LOCALE}}',     (Get-WinSystemLocale).Name)
$t = $t.Replace('{{IMAGE_NAME}}', $ImageName)
$t = $t.Replace('{{LOCAL_USER}}', $LocalUser)
$t = $t.Replace('{{LOCAL_PASS}}', $LocalPass)
$t = $t.Replace('<!--TUNING-->', ($cmdsXml -join "`r`n      "))
if ($t -match '\{\{') { throw "ОТКАЗ: в шаблоне остались незамещённые {{...}} — грамматика шаблона нарушена, продолжать нельзя" }
$ans = Join-Path $media 'autounattend.xml'
Set-Content -LiteralPath $ans -Value $t -Encoding UTF8
Log ("autounattend.xml записан: {0} (пользователь: {1})" -f $ans, $LocalUser)

# --- 4. Драйверы (встроенная механика DriverPaths) ------------------
if ($DriversDir -and (Test-Path $DriversDir)) {
  $dst = Join-Path $media 'Драйверы'
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  Copy-Item (Join-Path $DriversDir '*') $dst -Recurse -Force
  Log ("Драйверы уложены в ISO: {0} -> \Драйверы" -f $DriversDir)
} else {
  Log 'Папка "Драйверы" пуста/отсутствует — остаёмся на инбокс-драйверах установщика (это нормально: их в Windows 11 большинство).'
}

# --- 5. Пересборка ISO: IMAPI2 (встроенный COM) ---------------------
$bootFile = Join-Path $media 'efi\microsoft\boot\efisys.bin'
if (-not (Test-Path $bootFile)) {
  throw "ОТКАЗ: в образе нет $bootFile — это не стандартный Windows 10/11 ISO; сборка неопределённа, продолжать запрещено."
}
Log 'Собираю новый ISO через IMAPI2 (ISO9660+Joliet+UDF rev102, загрузка EFI)...'
$fsi = New-Object -ComObject IMAPI2FS.MsFileSystemImage
$fsi.VolumeName = 'OSFORGE'
$fsi.FileSystemsToCreate = 7        # 1 ISO9660 | 2 Joliet | 4 UDF — UDF обязателен: install.wim > 4 ГБ
$fsi.UDFRevision = 0x102            # rev 102 — то же, что oscdimg -udfver102
$fsi.Root.AddTree($media, $false)

$bootStream = New-Object -ComObject ADODB.Stream
$bootStream.Open(); $bootStream.Type = 1
$bootStream.LoadFromFile($bootFile)
$boot = New-Object -ComObject IMAPI2FS.BootOptions
$boot.Emulation = 0                 # без эмуляции дискеты
$boot.Platform = 0xEF               # EFI; IMAPI2 умеет РОВНО ОДНУ запись — см. docs/ПОЧЕМУ-ТОЛЬКО-ТАК.md
$boot.AssignDriveLetter = $false
$boot.ImageStream = $bootStream
$fsi.BootOptions = $boot

$result = $fsi.CreateResultImage()
Log ("Пересборка идёт ({0} блоков источника), выгружаю в файл..." -f $result.BlockCount)

$com = $result.ImageStream -as [System.Runtime.InteropServices.ComTypes.IStream]
$fs = [System.IO.File]::Create($OutIso)
$buf = New-Object 'byte[]' 4194304
$ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
try {
  while ($true) {
    $com.Read($buf, $buf.Length, $ptr)
    $read = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr)
    if ($read -le 0) { break }
    $fs.Write($buf, 0, $read)
  }
} finally {
  [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
  $fs.Close()
}

# --- 6. Артефакт: проверка + хэш ------------------------------------
$out = Get-Item $OutIso
if ($out.Length -lt 1GB) { throw ("Артефакт подозрителен ({0} байт < 1 ГБ) — сборка сломана, артефактом назвать нельзя." -f $out.Length) }
Log ("АРТЕФАКТ: {0} ({1} ГБ)" -f $out.FullName, [math]::Round($out.Length/1GB, 2))
Log 'Считаю SHA256 артефакта (закон: артефакт отдаётся с хэшем)...'
$h = (Get-FileHash -Path $OutIso -Algorithm SHA256).Hash
Log ("SHA256: {0}" -f $h)

# --- 7. МАНИФЕСТ.json (донор практики: H-PE11-PHOENIX, MANIFEST.json/VERIFICATION.txt)
#     Артефакт отдаётся не файлом, а файлом+манифестом: SHA256, размер, дата-UTC,
#     карта хоста, параметры сборки. Ключи ASCII (закон машины-слова), значения — факты.
Log 'Пишу МАНИФЕСТ.json (практика донора H-PE11-PHOENIX)...'
$firm = 'UNKNOWN'
try { $firm = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType } catch { $firm = 'UNKNOWN' }
$hostOs = ''
try { $osCim = Get-CimInstance Win32_OperatingSystem; $hostOs = $osCim.Caption + ' ' + $osCim.Version } catch { $hostOs = 'UNKNOWN' }
$manifest = [ordered]@{
  artifact            = (Get-Item $OutIso).Name
  sha256              = $h
  size_bytes          = $out.Length
  built_utc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  toolchain           = 'Mount-DiskImage + robocopy + IMAPI2 (ISO9660+Joliet+UDF102, EFI El Torito)'
  image_name          = $ImageName
  local_user          = $LocalUser
  drivers_dir_present = [bool]($DriversDir -and (Test-Path $DriversDir))
  host_os             = $hostOs
  host_firmware       = $firm
  osforge_version     = 'v0.1.1'
  manifest_practice   = 'donor: H-PE11-PHOENIX (MANIFEST.json / VERIFICATION.txt, Task 40)'
}
$maniPath = "$OutIso.МАНИФЕСТ.json"
$manifest | ConvertTo-Json | Set-Content -LiteralPath $maniPath -Encoding UTF8
Log ("МАНИФЕСТ записан: {0}" -f $maniPath)

Log 'Убираю рабочую копию (media), ISO остаётся.'
Remove-Item $media -Recurse -Force
Write-Output $OutIso
