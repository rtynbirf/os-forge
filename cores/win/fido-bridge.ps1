# ============================================================
# OS-FORGE ядро: fido-bridge.ps1 (v0.1)
# Роль: запуск Fido по хэш-пину из каталога пунктов и возврат пути к ISO.
# Канон: Fido скачивает батник (curl по АКТИВНОМУ пункту каталога 00).
# ============================================================
param(
  [string]$OutDir,
  [string]$Rel,      # редакция: 26H2 / 25H2 / 24H2 (см. каталог 00-OS-SOURCES)
  [string]$Ed,       # выпуск:   Pro / Home
  [string]$Lang,     # язык:     Russian (имя; Fido матчит по шаблону)
  [string]$Arch      # x64
)
$ErrorActionPreference = 'Stop'

$fido = Join-Path $OutDir 'Fido.ps1'
if (-not (Test-Path $fido)) {
  throw 'ОТКАЗ: Fido.ps1 не найден в OutDir. Почему: батник обязан скачать его по активному пункту каталога 00-OS-SOURCES (хэш-пин). По-другому нет: запуск чужого кода без фиксации хэша запрещён законом пунктов.'
}

Write-Host "[ЯДРО/FIDO] редакция=$Rel выпуск=$Ed язык=$Lang арх=$Arch"
Write-Host '[ЯДРО/FIDO] Резолвим актуальную официальную ссылку Microsoft и качаем (это долго: образ ~5-6 ГБ)...'

Push-Location $OutDir
try {
  & $fido -Win '11' -Rel $Rel -Arch $Arch -Ed $Ed -Lang $Lang
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw ("Fido вернул код {0}. По-другому нет: проверь WIN_REL/WIN_ED/WIN_LANG в КОНФИГЕ — допустимые значения перечислены в каталоге 00-OS-SOURCES (если редакция свежее поддерживаемой Fido — понизь на одну)." -f $LASTEXITCODE)
  }
} finally { Pop-Location }

Start-Sleep -Seconds 2
$iso = Get-ChildItem -Path $OutDir -Filter '*.iso' -File |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $iso) {
  throw 'ОТКАЗ: ISO не появился. Смотри сообщения Fido выше: сеть/сервер/параметры редакции.'
}

Write-Host ("[ЯДРО/FIDO] Образ получен: {0} ({1} ГБ)" -f $iso.FullName, [math]::Round($iso.Length/1GB,2))
# Протокол возврата: ТОЛЬКО помеченная строка. Батник парсит "ISO=" —
# какой бы мусор Fido ни напечатал выше, путь определяется детерминированно.
Write-Output ("ISO=" + $iso.FullName)
