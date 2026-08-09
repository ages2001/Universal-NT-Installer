#!/bin/bash

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

unset DISK_INFO HAS_OLD_OS_MAP PART_INDEX_MAP PART_FS_MAP PART_LABEL_MAP PART_SIZE_MAP PART_FREE_KB_MAP PART_NUM_MAP
declare -A DISK_INFO
declare -A HAS_OLD_OS_MAP
declare -A PART_INDEX_MAP
declare -A PART_FS_MAP
declare -A PART_LABEL_MAP
declare -A PART_SIZE_MAP
declare -A PART_FREE_KB_MAP
declare -A PART_NUM_MAP

declare -a DISK_MENU=()
declare -a PART_MENU=()

source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"

# Function to analyze PBR boot sector by reading raw hex signatures
detect_current_pbr() {
  local target_part="$1"
  local hex_data=""

  # Read first 8 sectors (4 KB) safely to cover multi-sector PBRs
  hex_data=$(sudo dd if="$target_part" bs=512 count=8 2>/dev/null | strings)

  if echo "$hex_data" | grep -q "BOOTMGR"; then
    echo "BOOTMGR (Vista/7/8/10/11 / Late Longhorn)"
  elif echo "$hex_data" | grep -q "NTLDR"; then
    echo "NTLDR (NT/2000/XP / Early Longhorn)"
  elif echo "$hex_data" | grep -qiE "freeldr|freeboot|F R E E L D R"; then
    echo "FREELDR.SYS (ReactOS)"
  elif echo "$hex_data" | grep -qE "IO +SYS|WINBOOT"; then
    echo "IO.SYS (MS-DOS/Win9x)"
  elif echo "$hex_data" | grep -qiE "GRLDR|Grub4dos"; then
    echo "GRLDR (Grub4dos)"
  elif echo "$hex_data" | grep -qiE "KERNEL.*SYS|FreeDOS"; then
    echo "KERNEL.SYS (FreeDOS)"
  else
    # Fallback: Check using ms-sys for ReactOS boot sector
    if sudo ms-sys "$target_part" 2>/dev/null | grep -qi "ReactOS"; then
      echo "FREELDR.SYS (ReactOS)"
    else
      # Check if code area (excluding BPB and signature) is mostly empty/zeroed
      local zero_check=$(sudo dd if="$target_part" bs=1 skip=90 count=400 2>/dev/null | tr -d '\0')
      if [[ -z "$zero_check" ]]; then
        echo "Zeroed / Empty"
      else
        echo "Unknown / Custom PBR"
      fi
    fi
  fi
}

while true; do
  DISK_MENU=()
  scan_disks "$INSTLR_DEVICE"

  DISK_SELECTED=$(dialog --clear --backtitle "PBR Boot Record Manager" \
    --title "Select Target Disk" \
    --menu "Choose the disk containing the partition to repair:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
  
  IS_MBR="${DISK_INFO["$DISK_SELECTED,type"]}"

  if [[ "$IS_MBR" != "MBR" && "$IS_MBR" != "MSDOS" ]]; then
    dialog --msgbox "Error: The selected disk format is ${IS_MBR:-UNKNOWN}!\n\nPBR Boot Record Repair Tool can only be performed on MBR partition tables." 8 70
    continue
  fi

  while true; do
    PART_MENU=()
    scan_partitions "$DISK_SELECTED"

    if [[ ${#PART_MENU[@]} -eq 0 ]]; then
      dialog --msgbox "No partitions found on $DISK_SELECTED." 7 50
      break 
    fi

    TARGET_PARTITION=$(dialog --clear --backtitle "PBR Boot Record Manager" \
      --title "Select Partition" \
      --menu "Choose the specific partition to rewrite its PBR boot record:" 19 80 13 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$TARGET_PARTITION" ]] && break

    PART_FS=$(lsblk -no FSTYPE "$TARGET_PARTITION" 2>/dev/null | xargs | tr '[:lower:]' '[:upper:]')
    
    if [[ "$PART_FS" == "VFAT" || "$PART_FS" == "FAT" ]]; then
      FILE_RAW=$(sudo file -s "$TARGET_PARTITION" 2>/dev/null)
      if echo "$FILE_RAW" | grep -q -i "FAT (32 bit)"; then PART_FS="FAT32"
      elif echo "$FILE_RAW" | grep -q -i "FAT (16 bit)"; then PART_FS="FAT16"
      elif echo "$FILE_RAW" | grep -q -i "FAT (12 bit)"; then PART_FS="FAT12"
      fi
    fi
    
    if [[ "$PART_FS" != "FAT12" && "$PART_FS" != "FAT16" && "$PART_FS" != "FAT32" && "$PART_FS" != "VFAT" && "$PART_FS" != "FAT" && "$PART_FS" != "NTFS" ]]; then
      dialog --msgbox "Error: Unsupported FS! Only FAT12, FAT16, FAT32 and NTFS filesystems are supported for PBR management operations." 7 68
      continue
    fi

    # Read current PBR via Hex/ASCII Inspection
    CURRENT_PBR=$(detect_current_pbr "$TARGET_PARTITION")

    declare -a DYNAMIC_OPTIONS=()

    case "$PART_FS" in
      NTFS)
        DYNAMIC_OPTIONS+=(
          "1" "Windows Vista/7/8/10/11 / Late Longhorn Boot Record (BOOTMGR)"
          "2" "Windows NT/2000/XP / Early Longhorn Boot Record (NTLDR)"
          "3" "ReactOS Boot Record (FREELDR.SYS)"
        )
        ;;
      FAT32|VFAT|FAT|FAT16|FAT12)
        DYNAMIC_OPTIONS+=(
          "1" "Windows Vista/7/8/10/11 / Late Longhorn Boot Record (BOOTMGR)"
          "2" "Windows NT/2000/XP / Early Longhorn Boot Record (NTLDR)"
          "3" "ReactOS Boot Record (FREELDR.SYS)"
          "4" "MS-DOS / Windows 9x Boot Record (IO.SYS)"
        )
        ;;
    esac

    DYNAMIC_OPTIONS+=("5" "Grub4dos Partition Boot Record (GRLDR)")

    case "$PART_FS" in
      FAT32|VFAT|FAT|FAT16|FAT12)
        DYNAMIC_OPTIONS+=("6" "FreeDOS Boot Record (KERNEL.SYS)")
        ;;
    esac

    DYNAMIC_OPTIONS+=("7" "Zero Out PBR Boot Code (Wipe/Clear Sector)")
    
    H=14
    W=77
    R=7
    
    if [[ "$PART_FS" == "NTFS" ]]; then
      H=$((H - 2))
      R=$((R - 2))
    fi

    while true; do
      PBR_ACTION=$(dialog --clear \
        --backtitle "PBR Boot Record Manager" \
        --title " $TARGET_PARTITION | Current PBR: $CURRENT_PBR " \
        --menu "Select Partition Boot Record payload to deploy on $TARGET_PARTITION:" $H $W $R "${DYNAMIC_OPTIONS[@]}" 3>&1 1>&2 2>&3)

      [[ $? -ne 0 || -z "$PBR_ACTION" ]] && break

      LOADER_ID=""
      PBR_LABEL=""

      case "$PBR_ACTION" in
        1) LOADER_ID="BOOTMGR"; PBR_LABEL="Windows Vista/7/8/10/11 / Late Longhorn (BOOTMGR)";;
        2) LOADER_ID="NTLDR";   PBR_LABEL="Windows NT/2000/XP / Early Longhorn (NTLDR)";;
        3) LOADER_ID="FREELDR"; PBR_LABEL="ReactOS (FREELDR.SYS)";;
        4) LOADER_ID="IOSYS";   PBR_LABEL="MS-DOS / Windows 9x (IO.SYS)";;
        5) LOADER_ID="GRLDR";   PBR_LABEL="Grub4dos (GRLDR)";;
        6) LOADER_ID="KERNEL";  PBR_LABEL="FreeDOS (KERNEL.SYS)";;
        7) LOADER_ID="ZERO";    PBR_LABEL="Zeroed/Empty PBR Code";;
      esac

      dialog --yesno "Write PBR onto $TARGET_PARTITION?\n\nCurrent PBR: $CURRENT_PBR\nNew PBR: $PBR_LABEL\n\nThis will rewrite the boot record code." 11 70
      [[ $? -ne 0 ]] && continue

      dialog --infobox "Injecting PBR boot sector metadata block..." 3 50
      
      # Import and execute applypbr.sh logic
      ./scripts/applypbr.sh "$TARGET_PARTITION" "$LOADER_ID" "$PART_FS" "$DISK_SELECTED"
      status=$?

      if [[ $status -eq 0 ]]; then
        dialog --msgbox "Success: Partition Boot Record (PBR) on $TARGET_PARTITION has been adjusted to look for $PBR_LABEL." 8 65
      elif [[ $status -eq 88 ]]; then
        dialog --msgbox "Error: Bootlace engine failed! Missing 'bootlace.com' binary inside path." 7 70
      elif [[ $status -eq 77 ]]; then
        dialog --msgbox "Error: System utility ms-sys failed to write FAT32 sectors even with force flag override applied!" 8 80
      elif [[ $status -eq 10 ]]; then
        dialog --msgbox "Error: Flash aborted! Core binary file template is completely missing from path: ./pbrbins." 7 80
      elif [[ $status -eq 11 || $status -eq 12 ]]; then
        dialog --msgbox "Error: BPB Shield aborted! Failed to clone or safeguard live partition identity headers." 7 80
      else
        dialog --msgbox "Error: Target boot execution engine failed to write partition boot records block directly!" 7 75
      fi
      
      if [[ -f "/tmp/pbr_executed_cmd.log" ]]; then
        EXECUTED_CMD=$(cat /tmp/pbr_executed_cmd.log)
        rm -f /tmp/pbr_executed_cmd.log
      fi
      
      break
    done
  done
done
