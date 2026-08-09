#!/bin/bash

# Arguments or inputs initialized dynamically
INSTLR_DEVICE="$1"

# Initialize variables to prevent pollution from parent shells
declare -a DISK_MENU=()
declare -A DISK_INFO=()
declare -a PART_MENU=()
declare -A PART_INDEX_MAP=()
declare -A PART_FS_MAP=()
declare -A PART_LABEL_MAP=()
declare -A PART_SIZE_MAP=()
declare -A PART_FREE_KB_MAP=()
declare -A HAS_OLD_OS_MAP=()
declare -A PART_SIZE_KB_MAP=()
declare -A PART_NUM_MAP=()

# Source external scripts cleanly
source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"

# 1. Select Target Disk (Outer Loop)
while true; do
  DISK_MENU=()
  DISK_INFO=()
  scan_disks "$INSTLR_DEVICE"

  if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
    dialog --msgbox "Error: No target disks found for conversion (excluding installer device)!" 7 70
    exit 1
  fi

  DISK_SELECTED=$(dialog --clear --backtitle "Partition CHS/LBA Converter" \
    --title "Select Target Disk" \
    --menu "Choose the disk containing the partition to convert:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2

  # 2. Select Target Partition (Inner Loop)
  while true; do
    PART_MENU=()
    scan_partitions "$DISK_SELECTED"

    if [[ ${#PART_MENU[@]} -eq 0 ]]; then
      dialog --msgbox "No partitions found on $DISK_SELECTED.\n\nPlease ensure the disk layout has valid MBR partitions." 7 60
      break # Break to outer loop to re-select disk
    fi

    TARGET_PARTITION=$(dialog --clear --backtitle "Partition CHS/LBA Converter" \
      --title "Select Partition for Conversion" \
      --menu "Choose the FAT16/FAT32 partition to toggle CHS/LBA:" 19 80 13 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    # If user presses Cancel/ESC on partition selection, go back to disk selection
    [[ $? -ne 0 || -z "$TARGET_PARTITION" ]] && break

    # Extract metadata safely
    DISK_DEVICE=$(echo "$TARGET_PARTITION" | sed -E 's/p?[0-9]+$//')
    PART_NUM="${PART_NUM_MAP[$TARGET_PARTITION]}"

    # If local map lookup fails, fallback to regex extraction
    if [[ -z "$PART_NUM" ]]; then
      PART_NUM=$(echo "$TARGET_PARTITION" | sed -E 's/^.*p?([0-9]+)$/\1/')
    fi

    # Fetch filesystem
    PART_FS=$(lsblk -no FSTYPE "$TARGET_PARTITION" 2>/dev/null | xargs | tr '[:lower:]' '[:upper:]')

    # Validation: Check filesystem type first (Safely returns to partition list)
    if [[ "$PART_FS" != "VFAT" && "$PART_FS" != "FAT" && "$PART_FS" != "FAT16" && "$PART_FS" != "FAT32" ]]; then
      dialog --msgbox "Error: Selected partition filesystem must be FAT16 or FAT32!\n\nDetected: ${PART_FS:-Unknown}" 8 60
      continue
    fi

    # Robust ID extraction: Looks for 'type=XX' or 'Id=XX' in sfdisk dump layout
    CURRENT_ID=$(sudo sfdisk -d "$DISK_DEVICE" 2>/dev/null | grep "^$TARGET_PARTITION" | grep -oE '(type|Id|id)=["]?[0-9a-fA-F]+["]?' | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

    # Check if CURRENT_ID is actually found
    if [[ -z "$CURRENT_ID" ]]; then
      dialog --msgbox "Error: Could not determine Partition Type ID from partition map." 7 60
      continue
    fi

    NEW_ID=""
    CONVERSION_DESC=""
    DIRECTION="" 

    # Clean alternative to case block using if/elif chain for absolute stability with loops
    # Standard FAT16
    if [[ "$CURRENT_ID" == "4" || "$CURRENT_ID" == "04" ]]; then
      NEW_ID="e"
      CONVERSION_DESC="FAT16 <32MB CHS (04h) --> FAT16 LBA (0Eh)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "6" || "$CURRENT_ID" == "06" ]]; then
      NEW_ID="e"
      CONVERSION_DESC="FAT16 CHS (06h) --> FAT16 LBA (0Eh)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "e" || "$CURRENT_ID" == "0e" ]]; then
      SECTOR_SIZE=$(cat /sys/block/$(basename "$DISK_DEVICE")/queue/logical_block_size 2>/dev/null || echo 512)
      SECTORS=$(cat "/sys/class/block/$(basename "$TARGET_PARTITION")/size" 2>/dev/null || echo 0)
      SIZE_BYTES=$(( SECTORS * SECTOR_SIZE ))
      if (( SIZE_BYTES < 33554432 )); then
        NEW_ID="4"
        CONVERSION_DESC="FAT16 LBA (0Eh) --> FAT16 <32MB CHS (04h)"
      else
        NEW_ID="6"
        CONVERSION_DESC="FAT16 LBA (0Eh) --> FAT16 CHS (06h)"
      fi
      DIRECTION="TO_CHS"
    # Hidden FAT16 (1x Series)
    elif [[ "$CURRENT_ID" == "14" ]]; then
      NEW_ID="1e"
      CONVERSION_DESC="Hidden FAT16 <32MB CHS (14h) --> Hidden FAT16 LBA (1Eh)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "16" ]]; then
      NEW_ID="1e"
      CONVERSION_DESC="Hidden FAT16 CHS (16h) --> Hidden FAT16 LBA (1Eh)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "1e" ]]; then
      SECTOR_SIZE=$(cat /sys/block/$(basename "$DISK_DEVICE")/queue/logical_block_size 2>/dev/null || echo 512)
      SECTORS=$(cat "/sys/class/block/$(basename "$TARGET_PARTITION")/size" 2>/dev/null || echo 0)
      SIZE_BYTES=$(( SECTORS * SECTOR_SIZE ))
      if (( SIZE_BYTES < 33554432 )); then
        NEW_ID="14"
        CONVERSION_DESC="Hidden FAT16 LBA (1Eh) --> Hidden FAT16 <32MB CHS (14h)"
      else
        NEW_ID="16"
        CONVERSION_DESC="Hidden FAT16 LBA (1Eh) --> Hidden FAT16 CHS (16h)"
      fi
      DIRECTION="TO_CHS"
    # Standard FAT32
    elif [[ "$CURRENT_ID" == "b" || "$CURRENT_ID" == "0b" ]]; then
      NEW_ID="c"
      CONVERSION_DESC="FAT32 CHS (0Bh) --> FAT32 LBA (0Ch)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "c" || "$CURRENT_ID" == "0c" ]]; then
      NEW_ID="b"
      CONVERSION_DESC="FAT32 LBA (0Ch) --> FAT32 CHS (0Bh)"
      DIRECTION="TO_CHS"
    # Hidden FAT32 (1x Series)
    elif [[ "$CURRENT_ID" == "1b" ]]; then
      NEW_ID="1c"
      CONVERSION_DESC="Hidden FAT32 CHS (1Bh) --> Hidden FAT32 LBA (1Ch)"
      DIRECTION="TO_LBA"
    elif [[ "$CURRENT_ID" == "1c" ]]; then
      NEW_ID="1b"
      CONVERSION_DESC="Hidden FAT32 LBA (1Ch) --> Hidden FAT32 CHS (1Bh)"
      DIRECTION="TO_CHS"
    else
      dialog --msgbox "Error: Partition Type ID '${CURRENT_ID}' is not supported for conversion.\n\nSupported IDs:\n\n- Standard: 04h, 06h, 0Eh, 0Bh, 0Ch\n- Hidden: 14h, 16h, 1Eh, 1Bh, 1Ch" 11 65
      continue
    fi

    # 3. Boundary Check: 8.4 GiB Limit for TO_CHS
    if [[ "$DIRECTION" == "TO_CHS" ]]; then
      FDISK_LINE=$(sudo fdisk -l "$DISK_DEVICE" 2>/dev/null | grep "^$TARGET_PARTITION")
      if [[ "$FDISK_LINE" =~ \* ]]; then
        END_SECTOR=$(echo "$FDISK_LINE" | awk '{print $4}')
      else
        END_SECTOR=$(echo "$FDISK_LINE" | awk '{print $3}')
      fi

      LIMIT_BYTES=9019431321
      SECTOR_SIZE=$(cat /sys/block/$(basename "$DISK_DEVICE")/queue/logical_block_size 2>/dev/null || echo 512)
      if (( (END_SECTOR * SECTOR_SIZE) > LIMIT_BYTES )); then
        dialog --msgbox "Error: Cannot convert to CHS!\n\nPartition extends beyond the maximum legacy 8.4 GiB boundary." 8 65
        continue
      fi
    fi

    # 4. Confirmation
    dialog --yesno "Convert Partition Geometry?\n\nPartition: $TARGET_PARTITION\nOperation: $CONVERSION_DESC" 9 70
    [[ $? -ne 0 ]] && continue

    # 5. Apply change using 'sfdisk --part-type' (Direct partition patch)
    sudo sfdisk --part-type "$DISK_DEVICE" "$PART_NUM" "$NEW_ID" >/dev/null 2>&1
    status=$?

    sudo partprobe "$DISK_DEVICE" >/dev/null 2>&1

    if [[ $status -eq 0 ]]; then
      # Map the dynamic direction variable to user-friendly access type strings
      LOCAL_ACCESS_TYPE="CHS"
      if [[ "$DIRECTION" == "TO_LBA" ]]; then
        LOCAL_ACCESS_TYPE="LBA"
      fi

      dialog --msgbox "Geometry conversion completed successfully!\n\nPartition access type updated to $LOCAL_ACCESS_TYPE mode." 7 60
    else
      dialog --msgbox "Error: Failed to apply partition table geometry modification!" 6 60
      continue
    fi
  done
done
