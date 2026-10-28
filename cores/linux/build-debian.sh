#!/usr/bin/env bash
# ================================================================
# OS-FORGE ядро: build-debian.sh (v0.1)
# Роль: скачать актуальный netinst, вживить preseed, пересобрать гибрид
#       BIOS+UEFI через xorriso по официальному рецепту Debian.
# Законы: SHA256 обязателен; preseed в ОБА загрузчика (BIOS и UEFI);
#         журнал в момент такта; DRY=1 = показать план без исполнения.
# Использование: DRY=0|1 bash build-debian.sh <ISO_URL> <PRESEED> <OUT_ISO> <WORKDIR>
# ================================================================
set -u
ISO_URL="$1"; PRESEED="$2"; OUT_ISO="$3"; WORKDIR="$4"
DRY="${DRY:-0}"
say()  { echo "[ЯДРО/DEB] $*"; }
run()  { if [ "$DRY" = "1" ]; then echo "  [СУХОЙ ПРОГОН] $*"; else "$@"; fi }

# --- 0. Инструменты: xorriso + isohdpfx (закон честных отказов) ---
if ! command -v xorriso >/dev/null 2>&1; then
  if [ "$DRY" = "1" ]; then say "xorriso отсутствует — в сухом прогоне не мешает; на живом прогоне: sudo apt-get install -y xorriso"
  else
    say "ОТКАЗ: xorriso не найден."
    say "ПОЧЕМУ ТОЛЬКО ТАК: xorriso — единственный инструмент, который и распаковывает,"
    say "и собирает гибрид BIOS+UEFI в один проход. genisoimage/mkisofs этого не умеют —"
    say "получится ISO без загрузки. Установка: sudo apt-get install -y xorriso"
    exit 3
  fi
fi
HDPFX=""
for P in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/modules/bios/isohdpfx.bin; do
  [ -f "$P" ] && HDPFX="$P" && break
done
if [ -z "$HDPFX" ]; then
  if [ "$DRY" = "1" ]; then say "isohdpfx.bin не найден — на живом прогоне: sudo apt-get install -y isolinux"
  else
    say "ОТКАЗ: isohdpfx.bin не найден."
    say "ПОЧЕМУ ТАК: это загрузочный сектор гибрида ISO+USB; без него образ не"
    say "загрузится с флешки в BIOS-режиме. Установка: sudo apt-get install -y isolinux"
    exit 3
  fi
else
  say "Загрузочный сектор гибрида: $HDPFX"
fi

# --- 1. Имя образа из URL ---
ISO_NAME="$(basename "$ISO_URL")"
DL_DIR="$(dirname "$OUT_ISO")/dl"
mkdir -p "$DL_DIR" "$WORKDIR"
ISO_PATH="$DL_DIR/$ISO_NAME"

# --- 2. Скачивание + SHA256 (закон: артефакт без проверки не существует) ---
say "Скачиваю $ISO_URL (~700 МБ)..."
run curl -fL --retry 3 -o "$ISO_PATH" "$ISO_URL" || { say "ОТКАЗ: образ не скачался"; exit 6; }
say "Скачиваю SHA256SUMS и проверяю целостность..."
run curl -fL --retry 3 -o "$DL_DIR/SHA256SUMS" "$(dirname "$ISO_URL")/SHA256SUMS" || { say "ОТКАЗ: SHA256SUMS не скачался"; exit 6; }
if [ "$DRY" != "1" ]; then
  (cd "$DL_DIR" && grep "$ISO_NAME" SHA256SUMS | sha256sum -c -) || {
    say "ОТКАЗ: хэш образа НЕ сошёлся — карта не равна территории, продолжать запрещено"; exit 6; }
  say "Хэш сошёлся: образ цел."
fi

# --- 3. Распаковка ---
say "Распаковываю образ: xorriso -osirrox on ..."
run rm -rf "$WORKDIR/tree"
run xorriso -osirrox on -indev "$ISO_PATH" -extract / "$WORKDIR/tree" || { say "ОТКАЗ: распаковка"; exit 8; }
TREE="$WORKDIR/tree"

# --- 4. preseed в корень + ОБА загрузчика (BIOS isolinux + UEFI grub) ---
run cp "$PRESEED" "$TREE/preseed.cfg"
say "Вживляю preseed в isolinux (BIOS-путь) и grub (UEFI-путь)..."
if [ "$DRY" = "1" ]; then
  say "  [СУХОЙ ПРОГОН] sed: isolinux/txt.cfg + boot/grub/grub.cfg <- auto=true priority=critical preseed/file=/cdrom/preseed.cfg"
else
  [ -f "$TREE/isolinux/txt.cfg" ] && sed -i 's|^\(append .*\)$|\1 auto=true priority=critical preseed/file=/cdrom/preseed.cfg|' "$TREE/isolinux/txt.cfg"
  [ -f "$TREE/isolinux/isolinux.cfg" ] && sed -i 's|^\(append .*\)$|\1 auto=true priority=critical preseed/file=/cdrom/preseed.cfg|' "$TREE/isolinux/isolinux.cfg"
  [ -f "$TREE/boot/grub/grub.cfg" ] && sed -i 's|^\(\s*linux\s\+.*\)$|\1 auto=true priority=critical file=/cdrom/preseed.cfg|' "$TREE/boot/grub/grub.cfg"
  grep -rq "preseed.cfg" "$TREE/isolinux" "$TREE/boot/grub" 2>/dev/null || {
    say "ОТКАЗ: preseed не вписался ни в один загрузчик — продолжать бессмысленно (машина остановится на вопросах установщика)"; exit 8; }
  say "preseed вписан в загрузчики (проверено grep'ом)."
fi

# --- 5. Пересборка: официальный рецепт Debian (гибрид BIOS+UEFI) ---
say "Пересобираю ISO: xorriso -as mkisofs (isohybrid, partition_offset 16, два El Torito входа)..."
run xorriso -as mkisofs -r -J -joliet-long -l \
    -isohybrid-mbr "$HDPFX" -partition_offset 16 \
    -V 'OSFORGE_DEBIAN' \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
    -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
    -o "$OUT_ISO" "$TREE" || { say "ОТКАЗ: пересборка"; exit 8; }

# --- 6. Артефакт: хэш + манифест + уборка ---
# МАНИФЕСТ.json — практика донора H-PE11-PHOENIX (MANIFEST.json/VERIFICATION.txt):
# артефакт отдаётся файлом+манифестом; ключи ASCII (закон машины-слова), значения — факты.
if [ "$DRY" != "1" ]; then
  [ -s "$OUT_ISO" ] || { say "ОТКАЗ: артефакт пуст — сборка сломана"; exit 8; }
  SHA="$(sha256sum "$OUT_ISO" | cut -d' ' -f1)"
  say "АРТЕФАКТ: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
  say "SHA256: $SHA"
  MANI="$OUT_ISO.МАНИФЕСТ.json"
  printf '{\n' > "$MANI"
  printf '  "artifact": "%s",\n' "$(basename "$OUT_ISO")" >> "$MANI"
  printf '  "sha256": "%s",\n' "$SHA" >> "$MANI"
  printf '  "size_bytes": %s,\n' "$(stat -c%s "$OUT_ISO" 2>/dev/null || echo 0)" >> "$MANI"
  printf '  "built_utc": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$MANI"
  printf '  "toolchain": "xorriso -as mkisofs (isohybrid, partition_offset 16, BIOS+UEFI El Torito)",\n' >> "$MANI"
  printf '  "iso_source": "%s",\n' "$ISO_URL" >> "$MANI"
  printf '  "osforge_version": "v0.1.1",\n' >> "$MANI"
  printf '  "manifest_practice": "donor: H-PE11-PHOENIX (MANIFEST.json / VERIFICATION.txt, Task 40)"\n}\n' >> "$MANI"
  say "МАНИФЕСТ записан: $MANI"
  rm -rf "$WORKDIR/tree"
  say "Рабочее дерево убрано, ISO остался."
else
  say "[СУХОЙ ПРОГОН] Артефакт был бы тут: $OUT_ISO"
fi
exit 0
