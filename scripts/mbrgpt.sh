#!/bin/bash

# Arguments or inputs initialized dynamically
INSTLR_DEVICE="$1"

declare -a DISK_MENU=()
declare -A DISK_INFO=()

# Source external disk scanning engine
source "./scripts/diskinfo.sh"

while true; do
  DISK_MENU=()
  DISK_INFO=()
  
  # 1. Select Target Disk
  scan_disks "$INSTLR_DEVICE"

  if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
    dialog --msgbox "Error: No target disks found for conversion (excluding installer device)!" 7 70
    exit 1
  fi

  DISK_SELECTED=$(dialog --clear --backtitle "Partition Table Utility" \
    --title "Select Target Disk" \
    --menu "Choose the disk you want to convert (In-Place / No Data Loss):" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  # Cancel or ESC -> Explicitly return to tools.sh menu
  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
  
  # --- CRITICAL CHECK: Verify if the disk label type is strictly MBR or GPT via diskinfo.sh map ---
  IS_MBR_OR_GPT="${DISK_INFO["$DISK_SELECTED,type"]}"

  if [[ "$IS_MBR_OR_GPT" != "MBR" && "$IS_MBR_OR_GPT" != "MSDOS" && "$IS_MBR_OR_GPT" != "GPT" ]]; then
    dialog --msgbox "Error: The selected disk format is ${IS_MBR_OR_GPT:-UNKNOWN}!\n\nDisk MBR/GPT Converter Tool can only be performed on MBR or GPT partition tables." 8 70
    continue
  fi

  # 2. Detect Current Partition Table Type safely via parted/fdisk
  CURRENT_TABLE=$(sudo parted -sm "$DISK_SELECTED" print 2>/dev/null | grep -i "^$DISK_SELECTED" | awk -F: '{print $6}' | tr '[:lower:]' '[:upper:]')

  if [[ -z "$CURRENT_TABLE" ]]; then
    if fdisk -l "$DISK_SELECTED" 2>/dev/null | grep -q "Disklabel type: gpt"; then
      CURRENT_TABLE="GPT"
    else
      CURRENT_TABLE="MBR"
    fi
  fi

  TARGET_TABLE=""
  CONVERSION_DESC=""
  GDISK_COMMAND=""

  case "$CURRENT_TABLE" in
    MBR|MSDOS)
      TARGET_TABLE="GPT"
      CONVERSION_DESC="MBR (Legacy) ---> GPT (Modern UEFI)"
      GDISK_COMMAND="echo -e 'w\ny' | sudo gdisk $DISK_SELECTED"
      ;;
    GPT)
      TARGET_TABLE="MBR"
      CONVERSION_DESC="GPT (Modern UEFI) ---> MBR (Legacy)"
      
      # Count real primary partitions
      PART_COUNT=$(lsblk -lnpo NAME "$DISK_SELECTED" | grep -E "^${DISK_SELECTED}[p0-9]" | wc -l)
      
      if (( PART_COUNT > 4 )); then
        dialog --msgbox "Error: Cannot convert GPT to MBR without data loss!\n\nThe disk has $PART_COUNT partitions. MBR partition layouts support a maximum of 4 Primary partitions.\n\nPlease delete some partitions first." 11 70
        continue 
      fi
      GDISK_COMMAND="echo -e 'r\ng\nw\ny' | sudo gdisk $DISK_SELECTED"
      ;;
    *)
      dialog --msgbox "Error: Unsupported or corrupted partition table type ($CURRENT_TABLE)!" 6 65
      continue
      ;;
  esac

  # 3. Confirmation Dialog
  dialog --yesno "WARNING: You are about to perform an in-place partition table conversion!\n\nDisk: $DISK_SELECTED\nOperation: $CONVERSION_DESC\n\nExisting files and filesystems will be preserved, but bootloaders may need reinstalling.\n\nDo you want to proceed?" 15 75
  [[ $? -ne 0 ]] && continue

  # 4. Execute the Conversion cleanly and log outputs
  dialog --infobox "Converting partition table layout dynamically..." 3 55

  GDISK_LOG="/tmp/gdisk_convert.log"
  rm -f "$GDISK_LOG"

  # Write internal conversion headers to the log file cleanly
  echo "=== GDISK PARTITION CONVERSION LOG ===" > "$GDISK_LOG"
  echo "Target Disk: $DISK_SELECTED" >> "$GDISK_LOG"
  echo "Operation: $CONVERSION_DESC" >> "$GDISK_LOG"
  echo "--------------------------------------" >> "$GDISK_LOG"

  # Execute gdisk non-interactively and pipe layout information
  eval "$GDISK_COMMAND" >> "$GDISK_LOG" 2>&1

  # Force kernel to re-read the updated partition layouts
  sudo partprobe "$DISK_SELECTED" >/dev/null 2>&1
  sleep 1

  # --- DESIRED TYPE VALIDATION ---
  POST_TABLE=$(sudo parted -sm "$DISK_SELECTED" print 2>/dev/null | grep -i "^$DISK_SELECTED" | awk -F: '{print $6}' | tr '[:lower:]' '[:upper:]')
  if [[ -z "$POST_TABLE" ]]; then
    if fdisk -l "$DISK_SELECTED" 2>/dev/null | grep -q "Disklabel type: gpt"; then
      POST_TABLE="GPT"
    else
      POST_TABLE="MBR"
    fi
  fi
  
  if [[ "$POST_TABLE" == "MSDOS" ]]; then POST_TABLE="MBR"; fi

  # If the new table structure perfectly matches the desired target type, consider it SUCCESSFUL
  if [[ "$POST_TABLE" == "$TARGET_TABLE" ]]; then
    rm -f "$GDISK_LOG"
    
    if [[ "$TARGET_TABLE" == "MBR" ]]; then
      if [[ -f "./scripts/fixprtid.sh" ]]; then
        source "./scripts/fixprtid.sh" "$INSTLR_DEVICE" "$DISK_SELECTED"
      else
        dialog --msgbox "Warning: MBR conversion was successful, but optimization script './scripts/fixprtid.sh' was not found!" 7 65
      fi
    fi

    # Success Notifications
    if [[ "$TARGET_TABLE" == "GPT" ]]; then
      dialog --msgbox "Partition table conversion completed successfully!\n\nDisk $DISK_SELECTED is now converted to GPT structure." 7 65
    else
      dialog --msgbox "Partition table conversion completed successfully!\n\nDisk $DISK_SELECTED is now converted to MBR structure and partition system IDs have been optimized." 8 65
    fi
    continue
  else
    # An error is triggered if the disk was NOT converted to the desired type
    dialog --backtitle "Partition Table Utility - Error Detected" \
      --title " Conversion Failed " \
      --yesno "Error: The conversion tool aborted or failed to achieve $TARGET_TABLE structure!\n\nWould you like to view the detailed log file to diagnose the issue?" 9 75
    
    if [[ $? -eq 0 ]]; then
      dialog --clear \
        --backtitle "Partition Table Utility - Log Viewer" \
        --title " gdisk Engine Execution Log " \
        --textbox "$GDISK_LOG" 18 78
    fi

    rm -f "$GDISK_LOG"
    continue
  fi
done
