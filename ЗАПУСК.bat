@echo off
REM ================================================================
REM  OS-FORGE v0.1 -- БАТНИК: самодостаточный автономный алгоритм
REM  Стадии: АКТИВАЦИЯ - КАРТА - РЕШЕНИЕ - СЕТЬ - СБОРКА - АРТЕФАКТ - ЖУРНАЛ
REM  Канон: карта=территория | пункт фиксируется с "почему только так" |
REM         опасное пассивно | честные русские отказы | журнал в момент такта
REM  Запускающий правит ТОЛЬКО блок КОНФИГ ниже. Остальное - ядро, не трогать.
REM  Прав администратора НЕ требует: всё живёт в папке ВЫХОД.
REM ================================================================
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
title OS-FORGE v0.1

REM ==================== КОНФИГ (правь только здесь) ================
REM Куда положить готовый ISO (папка создастся сама):
set "VYHOD=%USERPROFILE%\Desktop\OS-FORGE"
REM Целевая ОС: auto | win11 | win10 | debian
set "CEL_OSI=auto"
REM Редакция Windows для Fido: 26H2 | 25H2 | 24H2 (допустимые - в каталоге 00)
set "WIN_REL=26H2"
REM Выпуск Windows: Pro | Home
set "WIN_ED=Pro"
REM Язык Windows: Russian
set "WIN_LANG=Russian"
REM Учётная запись автоустановки (создастся администратором):
set "LOCAL_USER=user"
REM Пароль учётной записи. ПУСТО = вход без пароля (риск - твой выбор):
set "LOCAL_PASS="
REM Папка с .inf-паками драйверов (необязательно; уложатся в ISO \Драйверы):
set "DRIVERS_DIR=%~dp0Драйверы"
REM Сухой прогон: 1 = показать план и выйти, ничего не качая:
set "DRY=0"
REM ==================== КОНЕЦ КОНФИГ ===============================

set "PS=powershell -NoProfile -ExecutionPolicy Bypass"
set "REPO_RAW=https://raw.githubusercontent.com/rtynbirf/os-forge/v0.1.1"
set "STAGE=0-АКТИВАЦИЯ"
if not exist "%VYHOD%" mkdir "%VYHOD%"
set "LOG=%VYHOD%\ЖУРНАЛ.txt"
set "KARTA=%VYHOD%\КАРТА.txt"
set "CATDIR=%VYHOD%\catalog"

echo.
echo  ============================================================
echo   OS-FORGE v0.1  --  БАТНИК: карта среды + сборка актуального ISO
echo  ============================================================
call :log "СТАДИЯ 0-АКТИВАЦИЯ: самопроверка окружения запуска"

REM -- Самопроверка хозяина: сеть и PS встроены в чистый Windows 10+ --
where curl >nul 2>nul
if errorlevel 1 (
  echo  [ОТКАЗ] curl.exe не найден.
  echo  ПОЧЕМУ ТОЛЬКО ТАК: curl - единственная сеть, встроенная в чистый
  echo  Windows 10 1803+. По-другому нет: ставить wget/PS-модули = терять
  echo  самодостаточность батника.
  call :log "ОТКАЗ: curl.exe не найден - нужен Windows 10 1803+"
  exit /b 3
)
where powershell >nul 2>nul
if errorlevel 1 (
  echo  [ОТКАЗ] powershell не найден. По-другому нет: CIM-карта и IMAPI2
  echo  живут только в PowerShell.
  call :log "ОТКАЗ: powershell не найден"
  exit /b 3
)
call :log "Активация чистая: curl и powershell на месте. Выход: %VYHOD%"

REM ============================ СТАДИЯ 1: КАРТА ====================
echo.
echo  [1/5] КАРТА: распознавание среды по фактам, ноль догадок...
call :log "СТАДИЯ 1-КАРТА: сбор фактов устройства через CIM/WMI"
%PS% -Command "$cs=Get-CimInstance Win32_ComputerSystem;$os=Get-CimInstance Win32_OperatingSystem;$cpu=@(Get-CimInstance Win32_Processor)[0];$gpu=@(Get-CimInstance Win32_VideoController)[0];$bb=Get-CimInstance Win32_BaseBoard;$dd=@(Get-CimInstance Win32_DiskDrive|Sort-Object Size -Descending)[0];$net=@(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=true'|Where-Object {$_.NetEnabled})[0];try{$fw=(Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType}catch{$fw='HE-IZVESTNO'};$loc=(Get-WinSystemLocale).Name;$L=@('ARCH='+$env:PROCESSOR_ARCHITECTURE,'CPU='+$cpu.Name,'CORES='+$cpu.NumberOfCores,'RAM_GB='+[math]::Round($cs.TotalPhysicalMemory/1GB),'OS_HOST='+$os.Caption+' '+$os.Version,'GPU='+$gpu.Name,'BOARD='+$bb.Manufacturer+' '+$bb.Product,'DISK='+$dd.Model,'DISK_GB='+[math]::Round($dd.Size/1GB),'NET='+$net.Name,'LOCALE='+$loc,'FIRMWARE='+$fw);$L|Set-Content -LiteralPath '%KARTA%' -Encoding UTF8;Write-Host '--- KARTA (territoriya po faktam) ---';$L|ForEach-Object{Write-Host ('  '+$_)}"
if errorlevel 1 (
  echo  [ОТКАЗ] КАРТА не собралась.
  echo  ПОЧЕМУ ТОЛЬКО ТАК: CIM/WMI - единственный факт-источник железа,
  echo  встроенный в Windows без установки чего-либо. По-другому нет:
  echo  читать железо из догадок запрещено законом нуля догадок.
  call :log "ОТКАЗ: карта не собралась"
  exit /b 4
)
call :log "КАРТА собрана и записана: %KARTA%"

REM =========================== СТАДИЯ 2: РЕШЕНИЕ ===================
echo.
echo  [2/5] РЕШЕНИЕ: какой алгоритм и какие ядра нужны...
call :log "СТАДИЯ 2-РЕШЕНИЕ: выбор ветки по карте и КОНФИГУ"
set "RAM_GB="
for /f "tokens=1,* delims==" %%a in ('type "%KARTA%" ^| findstr /b /c:"RAM_GB="') do set "RAM_GB=%%b"
if /i "%CEL_OSI%"=="auto" (
  set "CEL_OSI=win11"
  call :log "auto: хост Windows, цель по умолчанию win11 (активный пункт каталога)"
)
if defined RAM_GB if %RAM_GB% LSS 4 (
  echo  [СОВЕТ ПО КАРТЕ] RAM_GB=%RAM_GB% меньше 4: Windows 11 будет тесна.
  echo  Рассмотри CEL_OSI=debian в КОНФИГЕ - это совет, решение твоё.
  call :log "СОВЕТ: RAM %RAM_GB% ГБ - тесно для Windows 11; debian рассмотри"
)
if /i "%CEL_OSI%"=="win11"  set "IMAGE_NAME=Windows 11 %WIN_ED%"
if /i "%CEL_OSI%"=="win10"  set "IMAGE_NAME=Windows 10 %WIN_ED%"
if /i "%CEL_OSI%"=="debian" (
  echo  [РЕШЕНИЕ] Цель debian с Windows-хоста: v0.1 делает ISO Linux только
  echo  с Linux-хоста. ПОЧЕМУ: пересборка Debian-ISO требует xorriso, а он
  echo  Linux-инструмент; WSL-маршрут - пункт v0.2, честно пассивен.
  call :log "ОТКАЗ: debian с Windows-хоста в v0.1 не собирается - см. запуск.sh"
  exit /b 5
)
call :log "Решение: цель=%CEL_OSI%, образ=%IMAGE_NAME%, редакция=%WIN_REL%"

REM ============================ СТАДИЯ 3: СЕТЬ =====================
echo.
echo  [3/5] СЕТЬ: иду в репозиторий за ядрами и пунктами каталога...
call :log "СТАДИЯ 3-СЕТЬ: ядра и каталог из репозитория (тег v0.1)"
set "CORES="
set "CATSRC="
if exist "%~dp0cores\win\inject.ps1" (
  set "CORES=%~dp0cores\win"
  set "CATSRC=%~dp0catalog"
  call :log "Режим разработки: ядра и каталог беру из папки рядом с батником"
) else (
  if not exist "%CATDIR%" mkdir "%CATDIR%"
  curl -fsSL "%REPO_RAW%/cores/win/fido-bridge.ps1" -o "%VYHOD%\fido-bridge.ps1"
  if errorlevel 1 goto netfail
  curl -fsSL "%REPO_RAW%/cores/win/inject.ps1" -o "%VYHOD%\inject.ps1"
  if errorlevel 1 goto netfail
  curl -fsSL "%REPO_RAW%/cores/win/autounattend.xml.tmpl" -o "%VYHOD%\autounattend.xml.tmpl"
  if errorlevel 1 goto netfail
  for %%C in (00-OS-SOURCES 01-DRIVERS-WIN 02-DRIVERS-LINUX 03-TUNING-WIN 04-TUNING-LINUX) do (
    curl -fsSL "%REPO_RAW%/catalog/%%C.txt" -o "%CATDIR%\%%C.txt"
    if errorlevel 1 goto netfail
  )
  set "CORES=%VYHOD%"
  set "CATSRC=%CATDIR%"
  call :log "Ядра и каталог скачаны по тегу v0.1 (хэш-пин)"
)
set "CAT=%CATSRC%\00-OS-SOURCES.txt"
set "FIDO_URL="
for /f "usebackq tokens=1,4 delims=|" %%a in (`findstr /b /c:"ACTIVE|%CEL_OSI%-fido" "%CAT%"`) do set "FIDO_URL=%%b"
if not defined FIDO_URL if /i "%CEL_OSI%"=="win10" for /f "usebackq tokens=1,4 delims=|" %%a in (`findstr /b /c:"ACTIVE|win10-fido" "%CAT%"`) do set "FIDO_URL=%%b"
if not defined FIDO_URL (
  echo  [ОТКАЗ] Активный пункт для цели %CEL_OSI% в каталоге не найден.
  echo  ПОЧЕМУ ТАК: батник не действует без пункта - закон пунктов.
  echo  Раскомментируй нужный пункт в catalog\00-OS-SOURCES.txt.
  call :log "ОТКАЗ: нет активного пункта для %CEL_OSI%"
  exit /b 6
)
call :log "Пункт активен: %CEL_OSI%-fido -> %FIDO_URL%"

if "%DRY%"=="1" (
  echo.
  echo  ============ СУХОЙ ПРОГОН: план без исполнения ============
  echo   ВЫХОД      : %VYHOD%
  echo   КАРТА      : %KARTA%
  echo   ЦЕЛЬ       : %CEL_OSI% / %IMAGE_NAME% / %WIN_REL% / x64
  echo   FIDO_URL   : %FIDO_URL%
  echo   ЯДРА       : %CORES%
  echo   ДРАЙВЕРЫ   : %DRIVERS_DIR%
  echo   БАТНИК остановлен по DRY=1. Поставь DRY=0 для сборки.
  call :log "СУХОЙ ПРОГОН: план показан, исполнение остановлено"
  exit /b 0
)

REM =========================== СТАДИЯ 4: СБОРКА ====================
echo.
echo  [4/5] СБОРКА: добываю актуальную ОС и вживляю пункты...
call :log "СТАДИЯ 4-СБОРКА: Fido качает официальную ссылку Microsoft"
set "FIDO_PS=%VYHOD%\Fido.ps1"
curl -fsSL "%FIDO_URL%" -o "%FIDO_PS%"
if errorlevel 1 (
  echo  [ОТКАЗ] Fido.ps1 не скачался по пину. ПОЧЕМУ ТАК: хэш-пин -
  echo  закон; если пин умер, обнови пункт каталога с новым хэшем.
  call :log "ОТКАЗ: Fido по пину не скачался"
  exit /b 6
)
call :log "Fido скачан по хэш-пину"
set "ISOPATH_FILE=%VYHOD%\iso_path.txt"
%PS% -File "%CORES%\fido-bridge.ps1" -OutDir "%VYHOD%" -Rel "%WIN_REL%" -Ed "%WIN_ED%" -Lang "%WIN_LANG%" -Arch "x64" > "%ISOPATH_FILE%"
if errorlevel 1 (
  echo  [ОТКАЗ] Мост Fido упал - смотри сообщения выше.
  call :log "ОТКАЗ: fido-bridge"
  exit /b 7
)
set "ISO="
for /f "usebackq tokens=1,* delims==" %%a in (`type "%ISOPATH_FILE%" ^| findstr /b /c:"ISO="`) do set "ISO=%%b"
if not defined ISO (
  echo  [ОТКАЗ] Строка ISO= не вернулась от моста. По-другому нет: без образа собирать не из чего.
  call :log "ОТКАЗ: строка ISO= пуста - см. iso_path.txt"
  exit /b 7
)
call :log "Образ на месте: %ISO%"

call :log "СТАДИЯ 4-СБОРКА: вживление ответов, драйверов, пунктов + пересборка IMAPI2"
set "OUT_ISO=%VYHOD%\OSFORGE_%CEL_OSI%_%WIN_REL%_x64.iso"
if exist "%OUT_ISO%" del "%OUT_ISO%"
%PS% -File "%CORES%\inject.ps1" -IsoPath "%ISO%" -WorkDir "%VYHOD%\work" -OutIso "%OUT_ISO%" -TmplPath "%CORES%\autounattend.xml.tmpl" -CatalogDir "%CATSRC%" -DriversDir "%DRIVERS_DIR%" -LocalUser "%LOCAL_USER%" -LocalPass "%LOCAL_PASS%" -ImageName "%IMAGE_NAME%"
if errorlevel 1 (
  echo  [ОТКАЗ] Инъектор упал - смотри [ЯДРО/INJECT] выше.
  call :log "ОТКАЗ: inject"
  exit /b 8
)

REM ========================== СТАДИЯ 5: АРТЕФАКТ ===================
echo.
echo  [5/5] АРТЕФАКТ: готов.
call :log "СТАДИЯ 5-АРТЕФАКТ: %OUT_ISO%"
echo  ============================================================
echo   ГОТОВО. Полный ISO лежит тут:
echo     %OUT_ISO%
echo   КАРТА среды      : %KARTA%
echo   ЖУРНАЛ такта     : %LOG%
echo   МАНИФЕСТ         : %OUT_ISO%.МАНИФЕСТ.json
echo   Установка: запиши ISO на флешку (Rufus, режим DD) и загрузись.
echo   ISO грузится в UEFI-режиме; ответы/драйверы/пункты уже внутри.
echo  ============================================================
exit /b 0

:netfail
echo  [ОТКАЗ] Сеть не отдала ядра/каталог по тегу v0.1.
echo  ПОЧЕМУ ТАК: без репозитория пунктов батник слеп - закон сети.
echo  Проверь сеть. Если репо переименован - обнови REPO_RAW.
call :log "ОТКАЗ: сеть, ядра/каталог не скачались"
exit /b 6

:log
for /f "tokens=1-3 delims=., " %%t in ("%TIME%") do set "TT=%%t"
echo [%DATE% %TT%] %~1>>"%LOG%"
echo    [ЖУРНАЛ] %~1
exit /b 0
