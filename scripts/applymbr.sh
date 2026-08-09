#!/bin/bash

TARGET_DISK="$1"
MBR_TYPE="$2"

if [[ -z "$TARGET_DISK" || -z "$MBR_TYPE" ]]; then
  exit 1
fi

BOOTLACE_BIN="./bootldr/grldr/bootlace.com"
DOSMBR_BIN="./bootldr/freeldr/dosmbr.bin"

case "$MBR_TYPE" in
  BOOTMGR|NT6|1|-7)
    sudo ms-sys -f -7 "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  NTLDR|NT5|2|-m)
    sudo ms-sys -f -m "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  REACTOS|FREELDR|3|-a)
    sudo ms-sys -f -a "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  GRUB4DOS|G4D|4|-g)
    if [[ ! -f "$BOOTLACE_BIN" ]]; then
      echo "Error: Bootlace binary ($BOOTLACE_BIN) not found!" >&2
      exit 3
    fi
    sudo chmod 777 "$BOOTLACE_BIN" 2>/dev/null
    sudo "$BOOTLACE_BIN" "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  WIN9X|DOS95B|5|-9)
    sudo ms-sys -f -9 "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  DOS|NT95A|6|-d)
    sudo ms-sys -f -d "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  ZERO|WIPE|7|-z)
    sudo ms-sys -f -z "$TARGET_DISK" >/dev/null 2>&1
    exit $?
    ;;
  *)
    exit 2
    ;;
esac
