#!/usr/bin/env bash
# Grava a pasta usb/ num pendrive (FAT32, partição única, bootável via EFI shell).
# Uso: sudo ./make-usb.sh /dev/sdX      (o dispositivo INTEIRO, não a partição)
set -euo pipefail
DEV="${1:-}"
SRC="$(cd "$(dirname "$0")/usb" && pwd)"
[[ -b "$DEV" ]] || { echo "uso: sudo $0 /dev/sdX"; lsblk -dpo NAME,SIZE,MODEL,TRAN | grep -i usb || true; exit 1; }
[[ "$DEV" =~ [0-9]$ ]] && { echo "passe o disco inteiro (ex.: /dev/sdb), não a partição"; exit 1; }
[[ "$(lsblk -dno TRAN "$DEV")" == "usb" ]] || { echo "ABORT: $DEV não é USB"; exit 1; }
echo ">>> VAI APAGAR TUDO EM $DEV:"; lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "$DEV"
read -rp "Digite o nome do dispositivo ($DEV) pra confirmar: " ok; [[ "$ok" == "$DEV" ]] || exit 1

umount "${DEV}"?* 2>/dev/null || true
wipefs -a "$DEV"
parted -s "$DEV" mklabel gpt mkpart BC250 fat32 1MiB 100% set 1 esp on
partprobe "$DEV"; sleep 2
PART="$(lsblk -pnro NAME "$DEV" | sed -n 2p)"
mkfs.vfat -F 32 -n BC250 "$PART"
MNT="$(mktemp -d)"; mount "$PART" "$MNT"
cp -rv "$SRC"/. "$MNT"/
sync; (cd "$MNT" && sha256sum -c SHA256SUMS.txt --quiet && echo "checksums OK")
umount "$MNT"; rmdir "$MNT"
echo ">>> Pronto. Pendrive $DEV gravado. Boote a BC-250 por ele (F11/F12 ou Boot Override no setup)."
