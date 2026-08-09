#!/bin/bash

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

unset DISK_INFO
declare -A DISK_INFO
declare -a DISK_MENU=()

source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"

while true; do
  DISK_MENU=()
  scan_disks "$INSTLR_DEVICE"

  DISK_SELECTED=$(dialog --clear --backtitle "MBR Boot Record Manager" \
    --title "Select Target Disk" \
    --menu "Choose the target MBR disk to rewrite the Master Boot Record:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)
  
  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
  
  IS_MBR="${DISK_INFO["$DISK_SELECTED,type"]}"

  if [[ "$IS_MBR" != "MBR" && "$IS_MBR" != "MSDOS" ]]; then
    dialog --msgbox "Error: The selected disk format is ${IS_MBR:-UNKNOWN}!\n\nPBR Boot Record Repair Tool can only be performed on MBR partition tables." 8 70
    continue
  fi

  CURRENT_MBR_RAW=$(sudo ms-sys "$DISK_SELECTED" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  CURRENT_MBR_DESC="Unknown / Custom Bootloader"

  if echo "$CURRENT_MBR_RAW" | grep -q "grub4dos"; then
    CURRENT_MBR_DESC="Grub4dos"
  elif echo "$CURRENT_MBR_RAW" | grep -qE "microsoft 7|bootmgr"; then
    CURRENT_MBR_DESC="Windows Vista/7/8/10/11 / Late Longhorn"
  elif echo "$CURRENT_MBR_RAW" | grep -qE "2000/xp/2003|ntldr"; then
    CURRENT_MBR_DESC="Windows NT/2000/XP / Early Longhorn"
  elif echo "$CURRENT_MBR_RAW" | grep -qE "95b/98/98se/me"; then
    CURRENT_MBR_DESC="Windows 95B/98/SE/ME"
  elif echo "$CURRENT_MBR_RAW" | grep -qE "dos|95a|mbrdos"; then
    CURRENT_MBR_DESC="DOS/NT/95A"
  elif echo "$CURRENT_MBR_RAW" | grep -q "reactos"; then
    CURRENT_MBR_DESC="ReactOS / FreeLdr"
  elif echo "$CURRENT_MBR_RAW" | grep -q "zeroed"; then
    CURRENT_MBR_DESC="Zeroed/Empty MBR Structure"
  else
    MBR_STRINGS=$(sudo dd if="$DISK_SELECTED" bs=512 count=16 2>/dev/null | strings)

    if echo "$MBR_STRINGS" | grep -qiE "grub4dos|grldr"; then
      CURRENT_MBR_DESC="Grub4dos"
    fi
  fi

  while true; do
    MBR_TYPE_ACTION=$(dialog --clear --backtitle "MBR Boot Record Manager" \
      --title "$DISK_SELECTED | Current MBR: $CURRENT_MBR_DESC" \
      --menu "Select Master Boot Record payload to deploy on $DISK_SELECTED:" 14 77 7 \
      "1" "Windows Vista/7/8/10/11 / Late Longhorn MBR" \
      "2" "Windows NT/2000/XP / Early Longhorn MBR" \
      "3" "ReactOS / FreeLdr MBR" \
      "4" "Grub4dos MBR" \
      "5" "Windows 95B/98/SE/ME MBR" \
      "6" "DOS/NT/95A MBR" \
      "7" "Zero Out MBR Boot Code (Empty/Clear Executable Block)" \
      3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$MBR_TYPE_ACTION" ]] && break

    MBR_ID=""
    SELECTED_MBR_LABEL=""

    # Map menu options directly to clean string IDs for startinst.sh compatibility
    case "$MBR_TYPE_ACTION" in
      1) MBR_ID="BOOTMGR";  SELECTED_MBR_LABEL="Windows Vista/7/8/10/11 / Late Longhorn MBR" ;;
      2) MBR_ID="NTLDR";    SELECTED_MBR_LABEL="Windows NT/2000/XP / Early Longhorn MBR" ;;
      3) MBR_ID="REACTOS";  SELECTED_MBR_LABEL="ReactOS / FreeLdr MBR" ;; 
      4) MBR_ID="GRUB4DOS"; SELECTED_MBR_LABEL="Grub4dos MBR" ;;
      5) MBR_ID="WIN9X";    SELECTED_MBR_LABEL="Windows 95B/98/SE/ME MBR" ;;
      6) MBR_ID="DOS";      SELECTED_MBR_LABEL="DOS/NT/95A MBR" ;;
      7) MBR_ID="ZERO";     SELECTED_MBR_LABEL="Zeroed/Empty MBR Code" ;;
      *) continue ;;
    esac

    dialog --yesno "Are you sure you want to alter the MBR on $DISK_SELECTED?\n\nCurrent Layout: $CURRENT_MBR_DESC\nTarget Layout: $SELECTED_MBR_LABEL\n\nExisting partitions and data will be preserved. Do you want to continue?" 13 75
    [[ $? -ne 0 ]] && continue

    dialog --infobox "Deploying Master Boot Record table sector payload..." 3 50
    
    # Import and execute applymbr.sh logic with human-readable string ID
    ./scripts/applymbr.sh "$DISK_SELECTED" "$MBR_ID"
    status=$?

    if [[ $status -eq 0 ]]; then
      dialog --msgbox "Success: MBR updated to $SELECTED_MBR_LABEL successfully." 7 60
    else
      dialog --msgbox "Error: System utility ms-sys failed to write master boot records even with force flag override applied!" 7 85
    fi

    break
  done
done
