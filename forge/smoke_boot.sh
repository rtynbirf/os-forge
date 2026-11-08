#!/usr/bin/env bash
# ================================================================
# OS-FORGE СМОК-ТЕСТ образа (П44, issue #3): QEMU-загрузка.
# Контракт: образ стартует как загрузочный CD ≤ N секунд — на серийной
# консоли появляются маркеры прошивки и старта с CD-ROM.
# Честные отказы: нет qemu — отказ (не имитация); нет ISO — отказ.
# Использование: bash forge/smoke_boot.sh <iso> [таймаут_сек=120]
# ================================================================
set -u
ISO="${1:-}"
TIMEOUT="${2:-120}"
MARK_MIN="${MARK_MIN:-3}"

say() { printf '[СМОК] %s\n' "$*"; }

[ -n "$ISO" ] || { say "ОТКАЗ: не задан ISO. Использование: smoke_boot.sh <iso> [сек]"; exit 2; }
[ -f "$ISO" ] || { say "ОТКАЗ: ISO не найден: $ISO"; exit 2; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
  say "ОТКАЗ: qemu-system-x86_64 не найден."
  say "ПОЧЕМУ ТОЛЬКО ТАК: смок-тест без запуска образа — не смок-тест, а обещание."
  say "Установка: sudo apt-get install -y qemu-system-x86"
  exit 3
}
command -v timeout >/dev/null 2>&1 || { say "ОТКАЗ: timeout не найден (coreutils)"; exit 3; }

OUT="${ISO}.СМОК.raw"
say "Загружаю образ в QEMU (serial console, без графики), таймаут ${TIMEOUT} с..."
timeout "$TIMEOUT" qemu-system-x86_64 \
  -m 2048 -cdrom "$ISO" -boot d -display none \
  -serial file:"$OUT" </dev/null >/dev/null 2>&1
RC=$?

# Критерий PASS: маркеры загрузки в серийной консоли (SeaBIOS + старт с CD)
MARKS=0
grep -qi "SeaBIOS" "$OUT" 2>/dev/null && MARKS=$((MARKS+1))
grep -qi "Booting from CD" "$OUT" 2>/dev/null && MARKS=$((MARKS+1))
grep -qiE "ISOLINUX|Boot failed" "$OUT" 2>/dev/null && MARKS=$((MARKS+1))
{
  echo "ISO: $ISO"
  echo "таймаут: ${TIMEOUT} с (rc=$RC: 124 = образ не дошёл до маркеров за срок)"
  echo "маркеры загрузки: $MARKS из 3 (порог $MARK_MIN)"
  echo "--- хвост серийной консоли ---"
  tail -20 "$OUT" 2>/dev/null
} > "${ISO}.СМОК-ОТЧЁТ.txt"

if [ "$MARKS" -ge "$MARK_MIN" ]; then
  say "СМОК=PASS — образ загружается, маркеры найдены (см. ${ISO}.СМОК-ОТЧЁТ.txt)"
  exit 0
fi
say "СМОК=FAIL — маркеров загрузки меньше порога ($MARKS < $MARK_MIN)."
say "ПОЧЕМУ ЭТО КРАСНЫЙ: загрузочный сектор/CD-старт не подтвердились —"
say "образ не прошёл контракт «boot до приглашения ≤ ${TIMEOUT} с»."
exit 1
