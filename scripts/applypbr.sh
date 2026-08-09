#!/bin/bash

TARGET_PARTITION="$1"
LOADER_ID="$2"
PART_FS="$3"
DISK_SELECTED="$4"

BIN_PATH="./pbrbins"
EXECUTED_CMD=""

if [[ -z "$TARGET_PARTITION" || -z "$LOADER_ID" ]]; then
  exit 1
fi

# Detect File System dynamically if omitted
if [[ -z "$PART_FS" ]]; then
  PART_FS=$(lsblk -no FSTYPE "$TARGET_PARTITION" 2>/dev/null | xargs | tr '[:lower:]' '[:upper:]')
  if [[ "$PART_FS" == "VFAT" || "$PART_FS" == "FAT" ]]; then
    FILE_RAW=$(sudo file -s "$TARGET_PARTITION" 2>/dev/null)
    if echo "$FILE_RAW" | grep -q -i "FAT (32 bit)"; then PART_FS="FAT32"
    elif echo "$FILE_RAW" | grep -q -i "FAT (16 bit)"; then PART_FS="FAT16"
    elif echo "$FILE_RAW" | grep -q -i "FAT (12 bit)"; then PART_FS="FAT12"
    fi
  fi
fi

# Resolve parent disk if omitted
if [[ -z "$DISK_SELECTED" ]]; then
  DISK_SELECTED=$(lsblk -no PKNAME "$TARGET_PARTITION" 2>/dev/null | head -n 1)
  [[ -n "$DISK_SELECTED" ]] && DISK_SELECTED="/dev/$DISK_SELECTED"
fi

# PURE PBR BINARY INJECTION ENGINE WITH UNIVERSAL BLOCKED BPB SHIELD
write_pure_pbr() {
  local TARGET="$1"
  local FS_TYPE="$2"
  local LOADER="$3"
  
  local TEMPLATE_BIN=""
  local SECTOR_COUNT=0

  case "$FS_TYPE" in
    NTFS)
      [[ "$LOADER" == "BOOTMGR" ]] && TEMPLATE_BIN="${BIN_PATH}/bootmgrntfs.bin"
      [[ "$LOADER" == "NTLDR" ]] && TEMPLATE_BIN="${BIN_PATH}/ntldrntfs.bin"
      [[ "$LOADER" == "FREELDR" ]] && TEMPLATE_BIN="${BIN_PATH}/freeldrntfs.bin"
      [[ "$LOADER" == "GRLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/g4dntfs.bin"
      
      if [[ "$LOADER" == "BOOTMGR" ]]; then SECTOR_COUNT=12
      elif [[ "$LOADER" == "GRLDR" ]]; then SECTOR_COUNT=4
      else SECTOR_COUNT=8; fi
      ;;

    FAT32|VFAT|FAT)
      [[ "$LOADER" == "BOOTMGR" ]] && TEMPLATE_BIN="${BIN_PATH}/bootmgrfat32.bin"
      [[ "$LOADER" == "NTLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/ntldrfat32.bin"
      [[ "$LOADER" == "IOSYS" ]]   && TEMPLATE_BIN="${BIN_PATH}/msdosfat32.bin"
      [[ "$LOADER" == "KERNEL" ]]  && TEMPLATE_BIN="${BIN_PATH}/freedosfat32.bin"
      [[ "$LOADER" == "GRLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/g4dfat32.bin"
      
      if [[ "$LOADER" == "GRLDR" ]]; then SECTOR_COUNT=1
      else SECTOR_COUNT=3; fi
      ;;

    FAT16)
      [[ "$LOADER" == "BOOTMGR" ]] && TEMPLATE_BIN="${BIN_PATH}/bootmgrfat16.bin"
      [[ "$LOADER" == "NTLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/ntldrfat16.bin"
      [[ "$LOADER" == "IOSYS" ]]   && TEMPLATE_BIN="${BIN_PATH}/msdosfat16.bin"
      [[ "$LOADER" == "KERNEL" ]]  && TEMPLATE_BIN="${BIN_PATH}/freedosfat16.bin"
      [[ "$LOADER" == "GRLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/g4dfat16.bin"
      SECTOR_COUNT=1
      ;;

    FAT12)
      [[ "$LOADER" == "BOOTMGR" ]] && TEMPLATE_BIN="${BIN_PATH}/bootmgrfat12.bin"
      [[ "$LOADER" == "NTLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/ntldrfat12.bin"
      [[ "$LOADER" == "IOSYS" ]]   && TEMPLATE_BIN="${BIN_PATH}/msdosfat12.bin"
      [[ "$LOADER" == "KERNEL" ]]  && TEMPLATE_BIN="${BIN_PATH}/freedosfat12.bin"
      [[ "$LOADER" == "GRLDR" ]]   && TEMPLATE_BIN="${BIN_PATH}/g4dfat12.bin"
      SECTOR_COUNT=1
      ;;
  esac

  if [[ ! -f "$TEMPLATE_BIN" ]]; then
    return 10
  fi

  EXECUTED_CMD="Custom Binary Engine: Stage hybrid assembly via template [${TEMPLATE_BIN}] -> Save BPB parameters -> Apply block injection: sudo dd if=/tmp/staged_pbr.bin of=${TARGET} bs=512 count=${SECTOR_COUNT} conv=notrunc"

  local STAGED_PBR="/tmp/staged_pbr.bin"
  cp "$TEMPLATE_BIN" "$STAGED_PBR"

  if [[ "$FS_TYPE" == "NTFS" || "$FS_TYPE" == "FAT32" || "$FS_TYPE" == "VFAT" ]]; then
    local BLOCK_SIZE=72
    [[ "$FS_TYPE" == "FAT32" || "$FS_TYPE" == "VFAT" ]] && BLOCK_SIZE=90

    local LIVE_BLOCK="/tmp/live_block.bin"
    sudo dd if="$TARGET" of="$LIVE_BLOCK" bs=1 count="$BLOCK_SIZE" skip=3 status=none
    if [[ $? -ne 0 ]]; then return 11; fi

    sudo dd if="$LIVE_BLOCK" of="$STAGED_PBR" bs=1 count="$BLOCK_SIZE" seek=3 conv=notrunc status=none
    if [[ $? -ne 0 ]]; then return 12; fi
    rm -f "$LIVE_BLOCK"
  else
    local TARGET_JUMP=$(sudo dd if="$TARGET" bs=1 count=1 skip=1 status=none | xxd -p)
    local TARGET_BPB_SIZE=0
    if [[ -n "$TARGET_JUMP" ]]; then
      TARGET_BPB_SIZE=$(($((16#$TARGET_JUMP)) + 1 - 3))
    fi

    if [[ $TARGET_BPB_SIZE -lt 30 || $TARGET_BPB_SIZE -gt 90 ]]; then
      [[ "$FS_TYPE" == "FAT16" ]] && TARGET_BPB_SIZE=62
      [[ "$FS_TYPE" == "FAT12" ]] && TARGET_BPB_SIZE=36
    fi

    local LIVE_GEOMETRY="/tmp/live_geo.bin"
    sudo dd if="$TARGET" of="$LIVE_GEOMETRY" bs=1 count=25 skip=11 status=none
    if [[ $? -ne 0 ]]; then return 11; fi

    sudo dd if="$LIVE_GEOMETRY" of="$STAGED_PBR" bs=1 count=25 seek=11 conv=notrunc status=none
    if [[ $? -ne 0 ]]; then return 12; fi
    rm -f "$LIVE_GEOMETRY"
  fi

  sudo dd if="$STAGED_PBR" of="$TARGET" bs=512 count="$SECTOR_COUNT" conv=notrunc status=none
  local FLASH_STATUS=$?
  rm -f "$STAGED_PBR"
  return $FLASH_STATUS
}

# --- EXECUTION ENGINE DISPATCH ---
status=99

# 1. PRIORITY ZERO ACTION (CLEAR PBR BOOT CODE SAFELY)
if [[ "$LOADER_ID" == "ZERO" || "$LOADER_ID" == "7" ]]; then
  BPB_OFFSET=62
  [[ "$PART_FS" == "FAT32" || "$PART_FS" == "VFAT" ]] && BPB_OFFSET=90
  [[ "$PART_FS" == "FAT12" ]] && BPB_OFFSET=36
  [[ "$PART_FS" == "NTFS" ]] && BPB_OFFSET=84

  ZERO_LENGTH=$((510 - BPB_OFFSET))
  EXECUTED_CMD="sudo dd if=/dev/zero of=${TARGET_PARTITION} bs=1 seek=${BPB_OFFSET} count=${ZERO_LENGTH} conv=notrunc status=none"
  sudo dd if=/dev/zero of="$TARGET_PARTITION" bs=1 seek="$BPB_OFFSET" count="$ZERO_LENGTH" conv=notrunc status=none
  status=$?

# 2. GRLDR ACTION
elif [[ "$LOADER_ID" == "GRLDR" || "$LOADER_ID" == "5" ]]; then
  if [[ -f "/tmp/files/bootldr/grldr/bootlace.com" ]]; then
    chmod 777 /tmp/files/bootldr/grldr/bootlace.com
    
    mapfile -t DETECTED_PARTS < <(lsblk -ln -o NAME,TYPE "$DISK_SELECTED" | awk '$2=="part" {print "/dev/"$1}')
    
    FLOPPY_IDX=0
    MATCH_FOUND=0

    for idx in "${!DETECTED_PARTS[@]}"; do
      if [[ "${DETECTED_PARTS[$idx]}" == "$TARGET_PARTITION" ]]; then
        FLOPPY_IDX=$idx
        MATCH_FOUND=1
        break
      fi
    done

    [[ $MATCH_FOUND -eq 0 ]] && FLOPPY_IDX=0
    
    EXECUTED_CMD="sudo /tmp/files/bootldr/grldr/bootlace.com --floppy=${FLOPPY_IDX} ${TARGET_PARTITION}"
    sudo /tmp/files/bootldr/grldr/bootlace.com --floppy="${FLOPPY_IDX}" "$TARGET_PARTITION" >/dev/null 2>&1
    status=$?
  else
    status=88
  fi

# 3. FAT32 FILESYSTEM DISPATCH
elif [[ "$PART_FS" == "FAT32" || "$PART_FS" == "VFAT" || "$PART_FS" == "FAT" ]]; then
  MS_FLAG=""
  [[ "$LOADER_ID" == "BOOTMGR" || "$LOADER_ID" == "1" ]] && MS_FLAG="-8"
  [[ "$LOADER_ID" == "NTLDR" || "$LOADER_ID" == "2" ]]   && MS_FLAG="-2"
  [[ "$LOADER_ID" == "FREELDR" || "$LOADER_ID" == "3" ]] && MS_FLAG="-c"
  [[ "$LOADER_ID" == "IOSYS" || "$LOADER_ID" == "4" ]]   && MS_FLAG="-3"
  [[ "$LOADER_ID" == "KERNEL" || "$LOADER_ID" == "6" ]]  && MS_FLAG="-4"
  
  EXECUTED_CMD="sudo ms-sys -f ${MS_FLAG} ${TARGET_PARTITION}"
  sudo ms-sys -f "$MS_FLAG" "$TARGET_PARTITION" >/dev/null 2>&1
  status=$?
  [[ $status -ne 0 ]] && status=77

# 4. NTFS FILESYSTEM DISPATCH
elif [[ "$PART_FS" == "NTFS" ]]; then
  if [[ "$LOADER_ID" == "BOOTMGR" || "$LOADER_ID" == "1" ]]; then
    EXECUTED_CMD="sudo ms-sys -f -n ${TARGET_PARTITION}"
    sudo ms-sys -f -n "$TARGET_PARTITION" >/dev/null 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
      write_pure_pbr "$TARGET_PARTITION" "$PART_FS" "BOOTMGR"
      status=$?
    fi
  else
    NORMALIZED_LOADER="$LOADER_ID"
    [[ "$LOADER_ID" == "2" ]] && NORMALIZED_LOADER="NTLDR"
    [[ "$LOADER_ID" == "3" ]] && NORMALIZED_LOADER="FREELDR"
    write_pure_pbr "$TARGET_PARTITION" "$PART_FS" "$NORMALIZED_LOADER"
    status=$?
  fi

# 5. FAT16 AND FAT12 DISPATCH
else
  if [[ "$PART_FS" == "FAT12" && ("$LOADER_ID" == "FREELDR" || "$LOADER_ID" == "3") ]]; then
    EXECUTED_CMD="sudo ms-sys -f -o ${TARGET_PARTITION}"
    sudo ms-sys -f -o "$TARGET_PARTITION" >/dev/null 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
      write_pure_pbr "$TARGET_PARTITION" "$PART_FS" "FREELDR"
      status=$?
    fi
  elif [[ "$PART_FS" == "FAT16" && ("$LOADER_ID" == "BOOTMGR" || "$LOADER_ID" == "NTLDR" || "$LOADER_ID" == "1" || "$LOADER_ID" == "2") ]] || [[ "$PART_FS" == "FAT12" && "$LOADER_ID" != "FREELDR" && "$LOADER_ID" != "3" ]]; then
    NORMALIZED_LOADER="$LOADER_ID"
    [[ "$LOADER_ID" == "1" ]] && NORMALIZED_LOADER="BOOTMGR"
    [[ "$LOADER_ID" == "2" ]] && NORMALIZED_LOADER="NTLDR"
    [[ "$LOADER_ID" == "4" ]] && NORMALIZED_LOADER="IOSYS"
    [[ "$LOADER_ID" == "6" ]] && NORMALIZED_LOADER="KERNEL"
    write_pure_pbr "$TARGET_PARTITION" "$PART_FS" "$NORMALIZED_LOADER"
    status=$?
  else
    MS_FLAG=""
    if [[ "$PART_FS" == "FAT16" ]]; then
      [[ "$LOADER_ID" == "FREELDR" || "$LOADER_ID" == "3" ]] && MS_FLAG="-o"
      [[ "$LOADER_ID" == "IOSYS" || "$LOADER_ID" == "4" ]]   && MS_FLAG="-6"
      [[ "$LOADER_ID" == "KERNEL" || "$LOADER_ID" == "6" ]]  && MS_FLAG="-5"
    fi

    EXECUTED_CMD="sudo ms-sys -f ${MS_FLAG} ${TARGET_PARTITION}"
    sudo ms-sys -f "$MS_FLAG" "$TARGET_PARTITION" >/dev/null 2>&1
    status=$?
    if [[ $status -ne 0 ]]; then
      NORMALIZED_LOADER="$LOADER_ID"
      [[ "$LOADER_ID" == "3" ]] && NORMALIZED_LOADER="FREELDR"
      [[ "$LOADER_ID" == "4" ]] && NORMALIZED_LOADER="IOSYS"
      [[ "$LOADER_ID" == "6" ]] && NORMALIZED_LOADER="KERNEL"
      write_pure_pbr "$TARGET_PARTITION" "$PART_FS" "$NORMALIZED_LOADER"
      status=$?
    fi
  fi
fi

# Export executed command to audit log file for UI script access
echo "$EXECUTED_CMD" > /tmp/pbr_executed_cmd.log

exit $status
