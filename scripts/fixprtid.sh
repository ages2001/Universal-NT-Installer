#!/bin/bash
# fixprtid.sh - Universal MBR Partition ID Optimization Engine

# Accept disk target as a dynamic parameter or inherit from caller
INSTLR_DEVICE="$1"
DISK_TARGET="$2"

# Force array sanitation to prevent environment pollution
unset DISK_MENU PART_MENU DISK_INFO HAS_OLD_OS_MAP PART_INDEX_MAP PART_FS_MAP PART_LABEL_MAP PART_SIZE_MAP PART_FREE_KB_MAP PART_NUM_MAP
declare -a DISK_MENU=()
declare -a PART_MENU=()
declare -A DISK_INFO
declare -A HAS_OLD_OS_MAP
declare -A PART_INDEX_MAP
declare -A PART_FS_MAP
declare -A PART_LABEL_MAP
declare -A PART_SIZE_MAP
declare -A PART_FREE_KB_MAP
declare -A PART_NUM_MAP

# 1. Source required modules if not already loaded in shell space
if [[ -f "./scripts/diskinfo.sh" && -f "./scripts/partinfo.sh" ]]; then
  source "./scripts/diskinfo.sh"
  source "./scripts/partinfo.sh"
else
  dialog --msgbox "Critical Error: Core dependencies (diskinfo.sh / partinfo.sh) are missing!" 7 70
  exit 1
fi

# 2. Dynamic Operational Routing (Direct Interactive Run vs Automated Call Mode)
if [[ -z "$DISK_TARGET" ]]; then
  # INTERACTIVE MODE: User launched this tool directly (e.g., from tools.sh)
  while true; do
    DISK_MENU=()
    scan_disks "$INSTLR_DEVICE"

    if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
      dialog --msgbox "Error: No viable disks discovered for partition ID optimization!" 7 65
      exit 1
    fi

    DISK_SELECTED=$(dialog --clear --backtitle "Partition System ID Optimizer" \
      --title "Select Target Disk" \
      --menu "Choose the disk you want to scan and optimize partition IDs:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

    # Cancel or ESC -> Explicitly return to tools.sh menu
    [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
	
	# --- CRITICAL CHECK: Verify if the disk label type is strictly MBR/MSDOS via diskinfo.sh map ---
    IS_MBR="${DISK_INFO["$DISK_SELECTED,type"]}"

    if [[ "$IS_MBR" != "MBR" && "$IS_MBR" != "MSDOS" ]]; then
      dialog --msgbox "Error: The selected disk format is ${IS_MBR:-UNKNOWN}!\n\nPartition System ID optimization can only be performed on MBR partition tables." 8 70
      continue
    fi

    # Prompt explicit user confirmation before touching the raw partition table mapping layout
    dialog --yesno "WARNING: You are about to analyze and optimize partition table IDs on $DISK_SELECTED.\n\nFilesystems will be cross-referenced and matched with legacy/modern standard MBR flags.\n\nDo you want to proceed?" 12 75
    
    # If user chooses "No", loop back to the disk selection menu
    [[ $? -ne 0 ]] && continue

    # Break loop to initiate the optimization engine
    break
  done
else
  # AUTOMATED MODE: Script was invoked or sourced with a direct argument
  DISK_SELECTED="$DISK_TARGET"
fi

# 3. Fire ID Optimization Engine Core
dialog --infobox "Optimizing MBR partition IDs based on geometry and types..." 3 65

# Gathers only the selected disk's partitions with an exact match to avoid loops or generic mapping traps
mapfile -t DETECTED_PARTS < <(lsblk -lnpo NAME "$DISK_SELECTED" | grep -E "^${DISK_SELECTED}[p0-9]")

for PART in "${DETECTED_PARTS[@]}"; do
  sleep 0.1
  # Fetch filesystem type via standard kernel level block properties
  PART_FS=$(lsblk -no FSTYPE "$PART" 2>/dev/null | xargs | tr '[:lower:]' '[:upper:]')
  PART_NUM=$(echo "$PART" | sed -E 's/^.*p?([0-9]+)$/\1/')
  
  # Detect Hidden Attribute from previous layout definitions
  IS_HIDDEN=0
  if sudo sfdisk -d "$DISK_SELECTED" 2>/dev/null | grep "^$PART" | grep -qi "hidden"; then
    IS_HIDDEN=1
  fi
  
  # Get Sector and Boundary geometry data for CHS/LBA matching boundaries
  SECTOR_SIZE=$(cat /sys/block/$(basename "$DISK_SELECTED")/queue/logical_block_size 2>/dev/null || echo 512)
  SECTORS=$(cat "/sys/class/block/$(basename "$PART")/size" 2>/dev/null || echo 0)
  SIZE_BYTES=$(( SECTORS * SECTOR_SIZE ))
  
  # 8.4 GiB boundary check via fdisk end sector mapping layout rules
  FDISK_LINE=$(sudo fdisk -l "$DISK_SELECTED" 2>/dev/null | grep "^$PART")
  if [[ "$FDISK_LINE" =~ \* ]]; then
    END_SECTOR=$(echo "$FDISK_LINE" | awk '{print $4}')
  else
    END_SECTOR=$(echo "$FDISK_LINE" | awk '{print $3}')
  fi
  
  LIMIT_BYTES=9019431321
  WITHIN_84G=1
  if (( (END_SECTOR * SECTOR_SIZE) > LIMIT_BYTES )); then
    WITHIN_84G=0
  fi
  
  # If VFAT/FAT ambiguity is detected, overwrite 'PART_FS' immediately using low-level magic byte sector analysis
  if [[ "$PART_FS" == "VFAT" || "$PART_FS" == "FAT" ]]; then
    FILE_RAW=$(sudo file -s "$PART" 2>/dev/null)
    if echo "$FILE_RAW" | grep -q -i "FAT (32 bit)"; then
      PART_FS="FAT32"
    elif echo "$FILE_RAW" | grep -q -i "FAT (16 bit)"; then
      PART_FS="FAT16"
    elif echo "$FILE_RAW" | grep -q -i "FAT (12 bit)"; then
      PART_FS="FAT12"
    else
      # Secondary Fallback routine using blkid identifiers
      BLKID_VAL=$(sudo blkid -o value -s TYPE "$PART" 2>/dev/null | tr '[:lower:]' '[:upper:]')
      if [[ "$BLKID_VAL" == "FAT32" || "$BLKID_VAL" == "FAT16" || "$BLKID_VAL" == "FAT12" ]]; then
        PART_FS="$BLKID_VAL"
      fi
    fi
  fi

  ASSIGNED_ID=""
  
  # 4. Partition ID System Decision Matrix (Supports hidden mapping tags and geometry boundaries)
  case "$PART_FS" in
    FAT12)
      if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="11"; else ASSIGNED_ID="01"; fi
      ;;
    FAT16)
      if [[ $SIZE_BYTES -lt 33554432 ]]; then
        if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="14"; else ASSIGNED_ID="04"; fi
      else
        if [[ $WITHIN_84G -eq 1 ]]; then
          if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="16"; else ASSIGNED_ID="06"; fi
        else
          if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="1e"; else ASSIGNED_ID="0e"; fi
        fi
      fi
      ;;
    FAT32)
      if [[ $WITHIN_84G -eq 1 ]]; then
        if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="1b"; else ASSIGNED_ID="0b"; fi
      else
        if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="1c"; else ASSIGNED_ID="0c"; fi
      fi
      ;;
    EXFAT|NTFS|HPFS)
      if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="17"; else ASSIGNED_ID="07"; fi
      ;;
    EXT2|EXT3|EXT4|BTRFS|XFS|F2FS|REISERFS)
      if [[ $IS_HIDDEN -eq 1 ]]; then ASSIGNED_ID="93"; else ASSIGNED_ID="83"; fi
      ;;
    LINUX-SWAP)
      ASSIGNED_ID="82"
      ;;
  esac
  
  # 5. Injection Execution & Fine-Grained Error Catching
  if [[ -n "$ASSIGNED_ID" ]]; then
    sudo sfdisk --part-type "$DISK_SELECTED" "$PART_NUM" "$ASSIGNED_ID" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      dialog --msgbox "Error: Failed to apply target system ID patch!\n\nPartition: $PART\nAttempted Hex ID: ${ASSIGNED_ID}h\n\nPlease check if the drive partition map is currently locked or busy." 8 65
    fi
  fi
done

# Final layout initialization flush
sudo partprobe "$DISK_SELECTED" >/dev/null 2>&1

# 6. Inform direct user completion if interactive execution path occurred
if [[ -z "$DISK_TARGET" ]]; then
  dialog --msgbox "Success: MBR partition layout system IDs on $DISK_SELECTED have been optimized successfully." 7 75
  
  # Re-execute itself seamlessly to loop back into disk selection rather than terminating out to tools.sh
  exec "$0" "$INSTLR_DEVICE"
fi
