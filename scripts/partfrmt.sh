#!/bin/bash

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"

DISK_MENU_READY=0
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

confirm_format_dialog() {
  local partition="$1" local fs="$2" local access="$3" local label="$4"
  local msg="You are about to format the following partition:\n\n"
  msg+="Partition: $partition\n"
  msg+="Filesystem: $fs\n"
  [[ -n "$access" ]] && msg+="Access type: $access\n"
  msg+="Label: ${label:--}\n"
  msg+="\nWARNING: ALL DATA WILL BE LOST.\n\nProceed?"

  dialog --yesno "$msg" 14 60
  [[ $? -eq 0 ]]
}

select_disk() {
  while true; do
    if [[ "$DISK_MENU_READY" != "1" ]]; then
      scan_disks "$INSTLR_DEVICE"
      [[ ${#DISK_MENU[@]} -eq 0 ]] && dialog --msgbox "No suitable disks found." 7 50 && exit 1
      DISK_MENU_READY=1
    fi

    DISK_SELECTED=$(dialog --clear --backtitle "Partition Formatter" \
      --title "Select Disk" \
      --menu "Choose disk to format a partition:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 0
  
    if [[ "${DISK_INFO["$DISK_SELECTED,type"]}" != "MBR" && "${DISK_INFO["$DISK_SELECTED,type"]}" != "GPT" ]]; then
      dialog --msgbox "Only MBR and GPT disks are supported for formatting!" 7 60
      continue
    fi
    break
  done
}

select_partition() {
  dialog --infobox "Scanning partitions..." 3 27
  scan_partitions "$DISK_SELECTED"
  
  while true; do
    selected_partition=$(dialog --clear --backtitle "Partition Formatter" \
      --title "Select Partition" \
      --menu "Choose a partition to format:" 19 80 13 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    if [[ $? -ne 0 || -z "$selected_partition" ]]; then return 1; fi

    local partname=$(basename "$selected_partition")
    local part_line=$(fdisk -l "$DISK_SELECTED" 2>/dev/null | grep -E "^/dev/$partname[[:space:]]")
    local -a fields
    read -r -a fields <<<"$part_line"
    local id_index=$([[ "${fields[1]}" == "*" ]] && echo 6 || echo 5)
    local id_value="${fields[$id_index]}"
    [[ ! "$id_value" =~ ^[0-9a-fA-F]+$ ]] && id_value="${fields[$((${#fields[@]} - 2))]}"
    id_value=$(echo "$id_value" | tr '[:upper:]' '[:lower:]')

    if [[ "$id_value" == "5" || "$id_value" == "f" || "$id_value" == "15" || "$id_value" == "1f" ]]; then
      dialog --msgbox "Extended partitions cannot be formatted!" 7 60 ; continue
    fi
    break
  done
  
  PARTITION_SELECTED="$selected_partition"
  PARTITION_NUMBER="${PART_NUM_MAP[$selected_partition]}"
  return 0
}

detect_and_format() {
  local partname=$(basename "$PARTITION_SELECTED")
  local part_line=$(fdisk -l "$DISK_SELECTED" 2>/dev/null | grep -E "^/dev/$partname[[:space:]]")
  local -a fields
  read -r -a fields <<< "$part_line"
  local id_index=$([[ "${fields[1]}" == "*" ]] && echo 6 || echo 5)
  local ID="${fields[$id_index]}" ; ID=${ID,,}
  [[ ${#ID} -gt 2 ]] && ID="${ID:0:2}"

  local partnum=$(echo "$partname" | grep -o '[0-9]\+$')
  local size_bytes=$(blockdev --getsize64 "$PARTITION_SELECTED")
  local size_mb=$(( size_bytes / 1024 / 1024 ))

  local format_cmd="" set_id="$ID" LABEL="" FS_TYPE="" ACCESS_MODE="" label_flag=""
  local fs_count=0 FS_OPTIONS=()
  
  (( size_mb >= 1 && size_mb < 32 ))    && FS_OPTIONS+=("FAT12"  "File Allocation Table 12 bit") && ((fs_count++))
  (( size_mb >= 16 && size_mb < 4096 )) && FS_OPTIONS+=("FAT16"  "File Allocation Table 16 bit") && ((fs_count++))
  (( size_mb >= 32 ))                   && FS_OPTIONS+=("FAT32"  "File Allocation Table 28 bit") && ((fs_count++))
  (( size_mb >= 10 ))                   && FS_OPTIONS+=("NTFS"   "New Technology File System 3.x") && ((fs_count++))
  (( size_mb >= 8 ))                    && FS_OPTIONS+=("exFAT"  "Extended File Allocation Table") && ((fs_count++))
  (( size_mb >= 1 ))                    && FS_OPTIONS+=("ext2"   "Second Extended File System") && ((fs_count++))
  (( size_mb >= 1 ))                    && FS_OPTIONS+=("ext3"   "Third Extended File System") && ((fs_count++))
  (( size_mb >= 1 ))                    && FS_OPTIONS+=("ext4"   "Fourth Extended File System") && ((fs_count++))
  (( size_mb >= 256 ))                  && FS_OPTIONS+=("Btrfs"  "B-tree File System") && ((fs_count++))
  (( size_mb >= 8 ))                    && FS_OPTIONS+=("ReiserFS" "Reiser File System") && ((fs_count++))

  [[ ${#FS_OPTIONS[@]} -eq 0 ]] && dialog --msgbox "No compatible filesystems." 7 50 && return 1

  local step=1
  while true; do
    case $step in
      1)
          FS_TYPE=$(dialog --menu "Select filesystem to format partition:" "$((7+$fs_count))" 50 10 "${FS_OPTIONS[@]}" 3>&1 1>&2 2>&3)
          [[ $? -eq 1 || $? -eq 255 ]] && step=$((step-1)) && { [[ $step -lt 1 ]] && return 1; continue; }
          step=2 ;;
      2)
          if [[ "$FS_TYPE" == "FAT16" || "$FS_TYPE" == "FAT32" ]]; then
            ACCESS_MODE=$(dialog --menu "Select access mode:" 10 43 2 CHS "CHS (Cylinder/Head/Sector)" LBA "LBA (Logical Block Addressing)" 3>&1 1>&2 2>&3)
            [[ $? -eq 1 || $? -eq 255 ]] && step=1 && continue
			
            # Check if partition extends beyond the 8.4 GiB boundary when CHS is selected
            if [[ "$ACCESS_MODE" == "CHS" ]]; then
              # Parse partition start and size in sectors using sfdisk
              local part_end_sector=$(sudo sfdisk -d "$DISK_SELECTED" 2>/dev/null | grep "$PARTITION_SELECTED" | grep -o 'size=[ ]*[0-9]*' | awk -F= '{print $2}' | xargs)
              local part_start_sector=$(sudo sfdisk -d "$DISK_SELECTED" 2>/dev/null | grep "$PARTITION_SELECTED" | grep -o 'start=[ ]*[0-9]*' | awk -F= '{print $2}' | xargs)
              
              if [[ -n "$part_start_sector" && -n "$part_end_sector" ]]; then
                local total_end_sector=$((part_start_sector + part_end_sector))
                local max_chs_sector=17616076 # 8.4 GiB limit calculated with 512-byte sectors

                if [ "$total_end_sector" -gt "$max_chs_sector" ]; then
                  dialog --msgbox "Error: This partition extends beyond the first 8.4 GiB of the disk! CHS mode cannot be used. Please select LBA." 8 60
                  continue # Go back to the access type menu
                fi
              fi
            fi
          fi
          step=3 ;;
      3)
          LABEL=$(dialog --inputbox "Enter volume label:" 9 60 3>&1 1>&2 2>&3) || { step=$([[ "$FS_TYPE" == "FAT16" || "$FS_TYPE" == "FAT32" ]] && echo 2 || echo 1); continue; }
          LABEL="${LABEL#"${LABEL%%[![:space:]]*}"}" ; LABEL="${LABEL%"${LABEL##*[![:space:]]}"}"
          if [[ -n "$LABEL" ]]; then
            local maxlen=11
            [[ "$FS_TYPE" == "NTFS" ]] && maxlen=32
            [[ "$FS_TYPE" == "exFAT" ]] && maxlen=15
            [[ "$FS_TYPE" == "ReiserFS" || "$FS_TYPE" == "ext2" || "$FS_TYPE" == "ext3" || "$FS_TYPE" == "ext4" ]] && maxlen=16
            [[ "$FS_TYPE" == "Btrfs" ]] && maxlen=256
            if [[ ${#LABEL} -gt $maxlen ]] || echo "$LABEL" | grep -qvE '^[a-zA-Z0-9 _-]+$'; then
              dialog --msgbox "Invalid label length or characters." 6 40 ; continue
            fi
          fi
          step=4 ;;
      4)
          case "$FS_TYPE" in
            FAT12)    format_cmd="mkfs.fat -F 12" ; set_id="1" ; label_flag="-n" ;;
            FAT16)    format_cmd="mkfs.fat -F 16" ; label_flag="-n" ; set_id=$([[ "$ACCESS_MODE" == "CHS" ]] && echo "6" || echo "e") ;;
            FAT32)    format_cmd="mkfs.fat -F 32" ; label_flag="-n" ; set_id=$([[ "$ACCESS_MODE" == "CHS" ]] && echo "b" || echo "c") ;;
            NTFS)     format_cmd="mkfs.ntfs -f" ; set_id="7" ; label_flag="-L" ;;
            exFAT)    format_cmd="mkfs.exfat" ; set_id="7" ; label_flag="-L" ;;
            ext2)     format_cmd="mkfs.ext2 -F" ; set_id="83" ; label_flag="-L" ;;
            ext3)     format_cmd="mkfs.ext3 -F" ; set_id="83" ; label_flag="-L" ;;
            ext4)     format_cmd="mkfs.ext4 -F" ; set_id="83" ; label_flag="-L" ;;
            Btrfs)    format_cmd="mkfs.btrfs -f" ; set_id="83" ; label_flag="-L" ;;
            ReiserFS) format_cmd="mkreiserfs -f" ; set_id="83" ; label_flag="-l" ;;
          esac
          step=5 ;;
      5)
          confirm_format_dialog "$PARTITION_SELECTED" "$FS_TYPE" "$ACCESS_MODE" "$LABEL" || { step=3 ; continue; }
          break ;;
    esac
  done
  
  dialog --infobox "Formatting..." 3 17
  [[ -n "$LABEL" ]] && format_cmd+=" $label_flag \"$LABEL\""
  eval sudo $format_cmd "$PARTITION_SELECTED" >/dev/null 2>&1 || { dialog --msgbox "Format failed!" 6 40 ; return 1; }
  sudo sfdisk --part-type "$DISK_SELECTED" "$partnum" "$set_id" >/dev/null 2>&1
  dialog --msgbox "Partition $PARTITION_SELECTED successfully formatted." 6 50
  return 0
}

while true; do
  select_disk
  while true; do
    select_partition || break
    detect_and_format
  done
done
