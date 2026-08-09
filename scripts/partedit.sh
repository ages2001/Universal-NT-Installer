#!/bin/bash

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

source "./scripts/diskinfo.sh"

declare -a DISK_MENU=()
declare -A DISK_INFO=()

while true; do
  scan_disks "$INSTLR_DEVICE"

  if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
    dialog --msgbox "No suitable disks found." 7 50
    exit 1
  fi

  DISK_SELECTED=$(dialog --clear --backtitle "Disk/Partition Manager" \
    --title "Select Target Disk" \
    --menu "Choose the disk for partition editing:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  if [[ $? -ne 0 || -z "$DISK_SELECTED" ]]; then
    exit 1
  fi

  for p in $(lsblk -lnpo NAME "$DISK_SELECTED" | grep -E '[0-9]+$'); do
    mountpoint=$(lsblk -ln -o NAME,MOUNTPOINT "/dev/$p" | awk '$2 != "" {print $1}')
    [[ -n "$mountpoint" ]] && sudo umount "/dev/$p"
  done

  cfdisk "$DISK_SELECTED"
  dialog --infobox "Refreshing..." 3 18

  if command -v partprobe &>/dev/null; then
    sudo partprobe "$DISK_SELECTED"
  else
    sudo blockdev --rereadpt "$DISK_SELECTED"
  fi

  sleep 0.1
  command -v udevadm &>/dev/null && sudo udevadm settle
done
