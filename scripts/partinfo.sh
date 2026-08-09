#!/bin/bash

scan_partitions() {
  local DISK_SELECTED="$1"

  PART_MENU=()
  PART_INDEX_MAP=()
  PART_FS_MAP=()
  PART_LABEL_MAP=()
  PART_SIZE_MAP=()
  PART_FREE_KB_MAP=()
  HAS_OLD_OS_MAP=()
  PART_NUM_MAP=()
  PART_SIZE_KB_MAP=()
  
  dialog --infobox "Scanning partition(s)..." 3 29
  
  local index=1
  local DISK_BASENAME=$(basename "$DISK_SELECTED")
  
  DISK_LABEL_TYPE="${DISK_INFO["$DISK_SELECTED,type"]}"
  
  mapfile -t parts < <(lsblk -ln -o NAME,SIZE,FSTYPE,LABEL "/dev/$DISK_BASENAME" 2>/dev/null)
  
  # Map partition start sectors using sfdisk (Works for SATA, NVMe, eMMC, USB across all lsblk versions)
  declare -A part_start_lba_map=()
  while read -r line; do
    local dev_path=$(echo "$line" | awk '{print $1}')
    local start_sector=$(echo "$line" | grep -o 'start=[ ]*[0-9]*' | awk -F= '{print $2}' | xargs)
    if [[ -n "$dev_path" && -n "$start_sector" ]]; then
      part_start_lba_map["$dev_path"]="$start_sector"
    fi
  done < <(sudo sfdisk -d "$DISK_SELECTED" 2>/dev/null | grep "^/dev/")

  # Also capture fdisk output map for boot/active flags
  local FDISK_OUTPUT=$(sudo fdisk -l "$DISK_SELECTED" 2>/dev/null)
  mapfile -t fdisk_parts < <(echo "$FDISK_OUTPUT" | grep "^/dev/$DISK_BASENAME" | grep -E "^/dev/${DISK_BASENAME}p?[0-9]+")
  declare -A FDISK_LINE_MAP
  for line in "${fdisk_parts[@]}"; do
    local dev=$(echo "$line" | awk '{print $1}')
    FDISK_LINE_MAP["$dev"]="$line"
  done

  declare -a parts_sorted=()
  for part_info in "${parts[@]}"; do
    local -a part_cols
    read -r -a part_cols <<<"$part_info"
    local part_name="${part_cols[0]}"
    local full_path="/dev/$part_name"
    
    # If sfdisk mapped it, use start LBA; else fallback to 0
    local start_lba="${part_start_lba_map[$full_path]:-0}"
    parts_sorted+=("${start_lba}:$part_info")
  done

  IFS=$'\n' local sorted=($(sort -n <<<"${parts_sorted[*]}"))
  unset IFS

  parts=()
  for item in "${sorted[@]}"; do
    parts+=("${item#*:}")
  done

  for part_info in "${parts[@]}"; do
    local -a part_cols
    read -r -a part_cols <<<"$part_info"
    
    local part_name="${part_cols[0]}"
    local size="${part_cols[1]}"
    
    # Direct target queries heavily silenced
    local fstype=$(lsblk -no FSTYPE "/dev/$part_name" 2>/dev/null | xargs | tr '[:upper:]' '[:lower:]')
    local label=$(lsblk -no LABEL "/dev/$part_name" 2>/dev/null | xargs)
    
    local full_path="/dev/$part_name"

    local part_line="${FDISK_LINE_MAP[$full_path]}"
    [[ -z "$part_line" ]] && continue
      
    local -a fields
    read -r -a fields <<<"$part_line"

    local active_flag=" "
    local hidden_flag=" "
    local id_value=""

    # ONLY parse MBR specific Partition IDs if the disk label type is NOT GPT
    if [[ "$DISK_LABEL_TYPE" != "GPT" ]]; then
      local id_index=$([[ "${fields[1]}" == "*" ]] && echo 6 || echo 5)
      id_value="${fields[$id_index]}"
      [[ ! "$id_value" =~ ^[0-9a-fA-F]+$ ]] && id_value="${fields[$((${#fields[@]} - 2))]}"
      id_value=$(echo "$id_value" | tr '[:upper:]' '[:lower:]')
        
      active_flag=$([[ "${fields[1]}" == "*" ]] && echo "A" || echo " ")
      hidden_flag=$([[ "$id_value" =~ ^[19][0-9a-f]$ ]] && echo "H" || echo " ")

      # Ignore Extended Partition Headers on MBR
      if [[ "$id_value" == "5" || "$id_value" == "f" || "$id_value" == "15" || "$id_value" == "1f" ]]; then
        continue
      fi
    fi
      
    local part_number=$(echo "$full_path" | sed -E 's/^.*p?([0-9]+)$/\1/')
    
    # GPT vs MBR Partition Type Determination (GPT is strictly PRI since there are no LOG partitions)
    local part_type="PRI"
    if [[ "$DISK_LABEL_TYPE" != "GPT" ]]; then
      part_type=$([[ "$part_number" -ge 5 ]] && echo "LOG" || echo "PRI")
    fi

    local fs_display="Unformatted"
	
    if [[ "$DISK_LABEL_TYPE" == "GPT" ]]; then
      # Refined FAT inspection using file utility
      if [[ "$fstype" == "vfat" || "$fstype" == "fat" ]]; then
        FILE_RAW=$(sudo file -s "$full_path" 2>/dev/null)
        if echo "$FILE_RAW" | grep -q -i "FAT (32 bit)"; then
          fstype="fat32"
        elif echo "$FILE_RAW" | grep -q -i "FAT (16 bit)"; then
          fstype="fat16"
        elif echo "$FILE_RAW" | grep -q -i "FAT (12 bit)"; then
          fstype="fat12"
        fi
      fi
	
      # Direct clean string resolving for GPT targets
      if [[ -z "$fstype" ]]; then fs_display="Unformatted"
	  elif [[ "$fstype" == "exfat" ]]; then fs_display="exFAT"
	  elif [[ "$fstype" == "btrfs" ]]; then fs_display="Btrfs"
      elif [[ "$fstype" == "reiserfs" ]]; then fs_display="ReiserFS"
	  elif [[ "$fstype" =~ ext ]]; then fs_display="${fstype}"
      else fs_display="${fstype^^}"
	  fi
    else
      # Legacy MBR Hex ID Mapping Matrix
      case "$id_value" in
        1|11)          fs_display=$([[ -z "$fstype" ]] && echo "Unformatted" || echo "FAT12") ;;
        4|6|14|16)     fs_display=$([[ -z "$fstype" ]] && echo "Unformatted" || echo "FAT16 CHS") ;;
        e|1e)          fs_display=$([[ -z "$fstype" ]] && echo "Unformatted" || echo "FAT16 LBA") ;;
        b|1b)          fs_display=$([[ -z "$fstype" ]] && echo "Unformatted" || echo "FAT32 CHS") ;;
        c|1c)          fs_display=$([[ -z "$fstype" ]] && echo "Unformatted" || echo "FAT32 LBA") ;;
        7|17)
          if [[ "$fstype" == "ntfs" ]]; then fs_display="NTFS"
          elif [[ "$fstype" == "exfat" ]]; then fs_display="exFAT"
          elif [[ "$fstype" == "hpfs" ]]; then fs_display="HPFS"
          elif [[ -z "$fstype" ]]; then fs_display="Unformatted"
          else fs_display="${fstype^^}"; fi ;;
        83|93)
          if [[ "$fstype" == "btrfs" ]]; then fs_display="Btrfs"
          elif [[ "$fstype" == "reiserfs" ]]; then fs_display="ReiserFS"
          elif [[ -z "$fstype" ]]; then fs_display="Unformatted"
          else fs_display="${fstype}"; fi ;;
        *)
          if [[ -z "$fstype" ]]; then
            fs_display="Unformatted"
          else
            fs_display="${fstype^^}"
          fi ;;
      esac
    fi

    local TMP_MOUNT="/tmp/mnt_$part_name"
    sudo mkdir -p "$TMP_MOUNT" >/dev/null 2>&1
    sudo umount "$TMP_MOUNT" >/dev/null 2>&1

    HAS_OLD_OS_MAP["$full_path"]=0
    # Heavy redirection applied to filesystem mount operations to prevent "not a block device" leakage
    if sudo mount -o ro "$full_path" "$TMP_MOUNT" >/dev/null 2>&1 \
      || { [[ "$fstype" == "ntfs" || -z "$fstype" ]] && sudo ntfs-3g -o ro "$full_path" "$TMP_MOUNT" >/dev/null 2>&1; } \
      || { [[ "$fstype" == "ntfs" || -z "$fstype" ]] && sudo mount -t ntfs3 -o force "$full_path" "$TMP_MOUNT" >/dev/null 2>&1; }
    then
      local df_out=$(df -kP "$TMP_MOUNT" 2>/dev/null | awk 'NR==2 {print $2, $4}')
      local free_kb=$(echo "$df_out" | cut -d' ' -f2)
      local part_bytes=$(lsblk -b -n -o KNAME,SIZE 2>/dev/null | awk -v part="$(basename "$full_path")" '$1 ~ part { print $2; exit }')
      local total_kb=$([[ -n "$part_bytes" ]] && awk -v b="$part_bytes" 'BEGIN { printf "%.2f", b / 1024 }' || echo 0)

      PART_SIZE_KB_MAP["$index"]="$total_kb"
      PART_FREE_KB_MAP["$index"]="$free_kb"

      sudo umount "$TMP_MOUNT" >/dev/null 2>&1
      rm -rf "$TMP_MOUNT" >/dev/null 2>&1
      local size_fmt=$(format_size "$total_kb")
      local avail_fmt=$(format_size "$free_kb")
    else
      local part_bytes=$(lsblk -b -n -o KNAME,SIZE 2>/dev/null | awk -v part="$(basename "$full_path")" '$1 ~ part { print $2; exit }')
      local total_kb=$([[ -n "$part_bytes" ]] && awk -v b="$part_bytes" 'BEGIN { printf "%.2f", b / 1024 }' || echo 0)
      
      local size_fmt=$(format_size "$total_kb")
      local avail_fmt="N/A"
      
      PART_SIZE_KB_MAP["$index"]="$total_kb"
      PART_FREE_KB_MAP["$index"]=0
    fi

    local desc=$(printf "%s%s %s | %-1s | %-1s / %-1s | %-1s" "$active_flag" "$hidden_flag" "$part_type" "$fs_display" "$avail_fmt" "$size_fmt" "${label:-N/A}")
    PART_MENU+=("$full_path" "$desc")
    PART_INDEX_MAP["$full_path"]="$index"
    PART_FS_MAP["$full_path"]="$fs_display"
    PART_LABEL_MAP["$full_path"]="${label:-N/A}"
    PART_SIZE_MAP["$full_path"]="$size_fmt"
    PART_FREE_KB_MAP["$full_path"]="$free_kb"
    PART_NUM_MAP["$full_path"]="$part_number"
    ((index++))
  done
}
