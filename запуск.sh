#!/usr/bin/env bash
# ================================================================
#  OS-FORGE v0.1 — запуск.sh: близнец БАТНИКА для Unix-подобных (Linux)
#  Стадии: АКТИВАЦИЯ → КАРТА → РЕШЕНИЕ → СЕТЬ → СБОРКА → АРТЕФАКТ → ЖУРНАЛ
#  Канон: карта=территория | пункт фиксируется с «почему только так» |
#         опасное пассивно | честные русские отказы | журнал в момент такта
#  Запускающий правит ТОЛЬКО блок КОНФИГ ниже. Прав root НЕ требуется.
# ================================================================
set -u
# ================= КОНФИГ (правь только здесь) ==================
VYHOD="${VYHOD:-$(cd "$(dirname "$0")" && pwd)/output}"
CEL_OSI="${CEL_OSI:-auto}"     # auto | debian
LOCAL_USER="${LOCAL_USER:-user}"
LOCAL_PASS="${LOCAL_PASS:-}"
DRY="${DRY:-0}"                # 1 = сухой прогон (план без исполнения)
# ================= КОНЕЦ КОНФИГ =================================

BASE="$(cd "$(dirname "$0")" && pwd)"
REPO_RAW="https://raw.githubusercontent.com/rtynbirf/os-forge/v0.1.1"
LOG="$VYHOD/ЖУРНАЛ.txt"; KARTA="$VYHOD/КАРТА.txt"; CATDIR="$VYHOD/catalog"
mkdir -p "$VYHOD" "$CATDIR"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
die()  { log "ОТКАЗ: $1 — ПОЧЕМУ: $2"; echo "  [ОТКАЗ] $1"; echo "  ПОЧЕМУ: $2" >&2; exit "${3:-3}"; }
стадия() { log "СТАДИЯ $1: $2"; }
run()  { if [ "$DRY" = "1" ]; then echo "  [СУХОЙ ПРОГОН] $*"; else "$@"; fi }

# ---------------------------------------------------------------
стадия_карта() {
стадия 1 "КАРТА: распознавание среды по фактам, ноль догадок"
  {
    echo "ARCH=$(uname -m)"
    echo "KERNEL=$(uname -sr)"
    if command -v lscpu >/dev/null 2>&1; then
      echo "CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2; exit}' | sed 's/^ *//')"
    else echo "CPU=НЕИЗВЕСТНО (нет lscpu; почему: util-linux не установлен)"; fi
    echo "CORES=$(nproc 2>/dev/null || echo НЕИЗВЕСТНО)"
    mem=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)
    echo "RAM_GB=${mem:-НЕИЗВЕСТНО}"
    if command -v lspci >/dev/null 2>&1; then
      echo "GPU=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | cut -d: -f3- | sed 's/^ *//')"
      echo "NET_PCI=$(lspci 2>/dev/null | grep -iE 'ethernet' | head -1 | cut -d: -f3- | sed 's/^ *//')"
      echo "WIFI=$(lspci 2>/dev/null | grep -iE 'network' | head -1 | cut -d: -f3- | sed 's/^ *//')"
    else
      echo "GPU=НЕИЗВЕСТНО (нет lspci; ПОЧЕМУ: pciutils не установлен — apt-get install pciutils)"
      echo "NET_PCI=НЕИЗВЕСТНО"; echo "WIFI=НЕИЗВЕСТНО"
    fi
    if command -v dmidecode >/dev/null 2>&1; then
      echo "BOARD=$(dmidecode -s baseboard-product-name 2>/dev/null | head -1)"
    else echo "BOARD=НЕИЗВЕСТНО (нет dmidecode — нужны root, честно пропускаю)"; fi
    echo "DISK_ROOT_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [ -d /sys/firmware/efi ]; then echo "FIRMWARE=uefi"; else echo "FIRMWARE=bios"; fi
    echo "LOCALE=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}')"
  } > "$KARTA"
  log "КАРТА собрана: $KARTA"
  cat "$KARTA" | sed 's/^/  /'
}

стадия_решение() {
стадия 2 "РЕШЕНИЕ: ветка алгоритма и набор ядер"
  [ "$(id -u)" = "0" ] && log "ВНИМАНИЕ: запуск от root не нужен и не рекомендуется (закон нуля админа)"
  case "$CEL_OSI" in
    auto)   CEL_OSI=debian; log "auto: хост Linux, цель по умолчанию debian (активный пункт каталога)" ;;
    debian) : ;;
    win*)   die "win-цель с Linux-хоста в v0.1 не собирается" "пересборка Windows-ISO требует wimlib на Linux — пункт v0.2, честно пассивен" 5 ;;
    *)      die "неизвестная цель: $CEL_OSI" "допустимо: auto | debian" 2 ;;
  esac
  # каталог: локальный (режим разработки) или из сети по тегу v0.1
  if [ -d "$BASE/catalog" ] && [ -f "$BASE/catalog/00-OS-SOURCES.txt" ]; then
    rm -rf "$CATDIR"; cp -r "$BASE/catalog" "$CATDIR"
    log "Режим разработки: каталог из папки рядом с скриптом"
  else
    for C in 00-OS-SOURCES 01-DRIVERS-WIN 02-DRIVERS-LINUX 03-TUNING-WIN 04-TUNING-LINUX; do
      curl -fsSL "$REPO_RAW/catalog/$C.txt" -o "$CATDIR/$C.txt" || die "каталог $C не скачался" "без репозитория пунктов батник слеп — закон сети" 6
    done
    log "Каталог скачан по тегу v0.1 (хэш-пин)"
  fi
  ARCH_K="$(grep '^ARCH=' "$KARTA" | cut -d= -f2)"
  case "$ARCH_K" in
    x86_64)  DARCH=amd64 ;;
    aarch64) DARCH=arm64 ;;
    *) die "архитектура $ARCH_K вне активных пунктов" "активен amd64; arm64 — пассивный пункт в каталоге 00, раскомментируй" 6 ;;
  esac
  DIR_URL="$(grep -E "^ACTIVE\|debian-$DARCH\|" "$CATDIR/00-OS-SOURCES.txt" | cut -d'|' -f4)"
  [ -n "$DIR_URL" ] || die "нет активного пункта debian-$DARCH" "раскомментируй пункт в catalog/00-OS-SOURCES.txt — закон пунктов" 6
  log "Пункт активен: debian-$DARCH → $DIR_URL"
  RAM="$(grep '^RAM_GB=' "$KARTA" | cut -d= -f2)"
  if [ -n "${RAM:-}" ] && [ "${RAM:-0}" -lt 2 ] 2>/dev/null; then
    log "СОВЕТ ПО КАРТЕ: RAM ${RAM} ГБ — debian-минимум ок, рабочий стол (XFCE) не включай"
  fi
}

стадия_сборка() {
стадия 3 "СЕТЬ+СБОРКА: добыча актуального образа и вживление пунктов"
  # --- имя актуального netinst-образа из официального каталога источника ---
  ISO_NAME="$(curl -fsSL "$DIR_URL" | grep -oE 'debian-[0-9.]+-'"$DARCH"'-netinst\.iso' | sort -u | tail -1)"
  [ -n "$ISO_NAME" ] || die "не нашёл netinst-образ в $DIR_URL" "источник жив по поверке; если умер — обнови пункт каталога (закон: карта=территория)" 6
  ISO_URL="$DIR_URL$ISO_NAME"
  log "Актуальный образ на момент запуска: $ISO_NAME"
  # --- пакеты из активных пунктов каталога (тюнинг + прошивки по карте) ---
  # ПОЧЕМУ ФИЛЬТР: в ACTIVE допустимы только машинные значения (имена пакетов,
  # ASCII) — проза в значениях разваливается в apt и молча ломает сборку (шрам v0.1).
  PKGS="$(grep -hE '^ACTIVE\|' "$CATDIR"/02-DRIVERS-LINUX.txt "$CATDIR"/04-TUNING-LINUX.txt | cut -d'|' -f4 | tr ',' '\n' | grep -E '^[a-z0-9][a-z0-9.+-]*$' | awk '!seen[$0]++' | paste -sd, -)"
  log "Активные пакеты пунктов: ${PKGS:-нет}"
  # --- preseed из шаблона + карты ---
  # Прошивка Wi-Fi — только от строки WIFI карты (шрам v0.1: CPU "Intel Xeon"
  # ложно зажигал iwlwifi). Дедупликация: если пункт каталога уже дал пакет — не дублируем.
  WIFI_EXTRA=""
  WIFI_LINE="$(grep '^WIFI=' "$KARTA" | cut -d= -f2-)"
  if echo "$WIFI_LINE" | grep -qi intel && ! echo ",$PKGS," | grep -q ',firmware-iwlwifi,'; then
    WIFI_EXTRA=",firmware-iwlwifi"
    log "По карте: Wi-Fi Intel — вшиваю firmware-iwlwifi"
  fi
  T="$BASE/cores/linux/preseed.cfg.tmpl"
  [ -f "$T" ] || { curl -fsSL "$REPO_RAW/cores/linux/preseed.cfg.tmpl" -o "$T" || die "шаблон preseed не добыт" "закон сети" 6; }
  PRESEED="$VYHOD/preseed.cfg"
  sed -e "s|{{LOCALE}}|$(grep '^LOCALE=' "$KARTA" | cut -d= -f2 | sed 's/\..*//;s/$/.UTF-8/' )|" \
      -e "s|{{LOCAL_USER}}|$LOCAL_USER|" \
      -e "s|{{LOCAL_PASS}}|$LOCAL_PASS|" \
      -e "s|{{PACKAGES}}|$(echo $PKGS | tr ' ' ',')|" \
      -e "s|{{WIFI_EXTRA}}|${WIFI_EXTRA}|" "$T" > "$PRESEED"
  if grep -q '{{' "$PRESEED"; then die "незамещённые {{...}} в preseed" "грамматика шаблона нарушена — продолжать нельзя" 4; fi
  log "preseed.cfg сгенерирован по карте: $PRESEED"
  # --- ядро сборки ---
  B="$BASE/cores/linux/build-debian.sh"
  [ -f "$B" ] || { curl -fsSL "$REPO_RAW/cores/linux/build-debian.sh" -o "$B" || die "ядро сборки не добыто" "закон сети" 6; }
  OUT_ISO="$VYHOD/OSFORGE_debian_${DARCH}.iso"
  log "Передаю ядру: образ=$ISO_URL выход=$OUT_ISO сухой_прогон=$DRY"
  DRY="$DRY" bash "$B" "$ISO_URL" "$PRESEED" "$OUT_ISO" "$VYHOD/work" || die "ядро сборки упало" "смотри сообщения ядра выше" 8
  log "СТАДИЯ 5-АРТЕФАКТ: $OUT_ISO"
  echo; echo "  ============================================================"
  echo "   ГОТОВО. Полный ISO лежит тут:"
  echo "     $OUT_ISO"
  echo "   КАРТА среды  : $KARTA"
  echo "   ЖУРНАЛ такта : $LOG"
  echo "   МАНИФЕСТ     : $OUT_ISO.МАНИФЕСТ.json"
  echo "   Запись флешки: cp $OUT_ISO /dev/sdX  (или dd status=progress)"
  echo "  ============================================================"
}

case "${1:-всё}" in
  карта|map)              стадия_карта ;;
  решение|decision)       стадия_карта; стадия_решение ;;
  сборка|build)           стадия_карта; стадия_решение; стадия_сборка ;;
  сухой-прогон|dry)       DRY=1; стадия_карта; стадия_решение; стадия_сборка ;;
  всё|all|"")             стадия_карта; стадия_решение; стадия_сборка ;;
  *) echo "Не знаю команду: $1"; echo "Команды: карта | решение | сборка | сухой-прогон | всё"; exit 2 ;;
esac
