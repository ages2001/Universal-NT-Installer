#!/bin/bash

DISK_MENU_READY=0
PART_MENU_READY=0

declare -a DISK_MENU=()
declare -A DISK_INFO=()

declare -a PART_MENU=()
declare -A PART_NUM_MAP=()
declare -A FDISK_LINE_MAP=()
declare -A part_start_lba_map=()
declare -a parts_sorted=()

# === Format helper ===
format_size() {
  local size_kb=$1
  if (( size_kb < 1024 )); then
    awk -v kb="$size_kb" 'BEGIN { printf "%.2f KB", kb }'
  elif (( size_kb < 1024*1024 )); then
    awk -v kb="$size_kb" 'BEGIN { printf "%.2f MB", kb/1024 }'
  elif (( size_kb < 1024*1024*1024 )); then
    awk -v kb="$size_kb" 'BEGIN { printf "%.2f GB", kb/1024/1024 }'
  else
    awk -v kb="$size_kb" 'BEGIN { printf "%.2f TB", kb/1024/1024/1024 }'
  fi
}

# === Get disk controller type ===
get_disk_interface_type() {
  local disk="$1"
  local sys_path pci_addr pci_id_short lspci_out

  # Ensure we're using only the disk name (e.g., "sda" from "/dev/sda")
  disk=$(basename "$disk")

  # Get the sysfs path for the device
  sys_path=$(readlink -f "/sys/block/$disk/device" 2>/dev/null)
  [[ -z "$sys_path" ]] && { echo "Unknown"; return; }

  # Extract the PCI address (e.g., 0000:00:1f.2 or 00:1f.2)
  pci_addr=$(echo "$sys_path" | grep -oE '([[:alnum:]]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
  [[ -z "$pci_addr" ]] && { echo "Unknown"; return; }

  # Remove domain part if present (0000:) for use in lspci
  pci_id_short="${pci_addr#0000:}"

  # Get lspci output and convert to lowercase
  lspci_out=$(lspci -s "$pci_id_short" 2>/dev/null | tr '[:upper:]' '[:lower:]')

  # Identify controller type
  if [[ "$disk" == *nvme* ]]; then
    echo "NVMe"
    return
  fi
  
  if echo "$lspci_out" | grep -qi "sata"; then
    if echo "$lspci_out" | grep -qi "ahci"; then
      echo "AHCI"
    else
      echo "SATA (IDE)"
    fi
    return
  fi

  if echo "$lspci_out" | grep -qi "ide"; then
    echo "IDE"
    return
  fi

  if echo "$lspci_out" | grep -qi "raid"; then
    echo "RAID"
    return
  fi

  if echo "$lspci_out" | grep -qi "sas"; then
    echo "SAS"
    return
  fi

  if echo "$lspci_out" | grep -qi "scsi"; then
    echo "SCSI"
    return
  fi

  echo "Unknown"
}

# === Step 1: Disk selection ===
select_disk() {
  while true; do
    if [[ "$DISK_MENU_READY" != "1" ]]; then
      dialog --infobox "Scanning disks..." 3 22
  
      for disk in /dev/sd? /dev/nvme?n?; do
        [[ ! -b "$disk" ]] && continue
        type=$(lsblk -dn -o TYPE "$disk" 2>/dev/null)
        [[ "$type" != "disk" ]] && continue
        
        # Removable disks skipped
        rm_flag=$(lsblk -dn -o RM "$disk" 2>/dev/null)
        [[ "${rm_flag//[[:space:]]/}" == "1" ]] && continue

        part_table=$(parted -sm "$disk" print 2>/dev/null | grep "^/dev" | cut -d: -f6 | head -n 1)
        [[ -z "$part_table" ]] && part_table="Unknown"
        [[ "$part_table" == "msdos" ]] && part_table="MBR"
        [[ "$part_table" == "gpt" ]] && part_table="GPT"

        disk_basename=$(basename "$disk")
        sector_size=$(cat /sys/block/$disk_basename/queue/hw_sector_size 2>/dev/null || echo 512)
        sector_count=$(cat /sys/block/$disk_basename/size 2>/dev/null || echo 0)
        size_bytes=$((sector_count * sector_size))
        size_kb=$((size_bytes / 1024))
        size_fmt=$(format_size "$size_kb")
    
        # Get controller type
        controller=$(get_disk_interface_type "$disk")

        DISK_MENU+=("$disk" "Size: $size_fmt | Type: $part_table | Cntrlr: $controller")
        DISK_INFO["$disk,type"]="$part_table"
        DISK_INFO["$disk,size"]="$size_fmt"
      done

      [[ ${#DISK_MENU[@]} -eq 0 ]] && dialog --msgbox "No suitable disks found." 7 50 && exit 1
  
      DISK_MENU_READY=1
    fi

    DISK_SELECTED=$(dialog --clear --backtitle "Partition Formatter" \
      --title "Select Disk" \
      --menu "Choose disk to format a partition:" 18 70 10 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 0
  
    # Check if selected disk is MBR
    if [[ "${DISK_INFO["$DISK_SELECTED,type"]}" != "MBR" ]]; then
      dialog --msgbox "Only MBR disks are supported for formatting!\n\nSelected disk type is: ${DISK_INFO["$DISK_SELECTED,type"]}" 7 50
      continue  # Go back to disk selection
    fi
    
    break  # valid disk selected, exit loop
  done
}

# === Step 2: Partition selection ===
select_partition() {
  # If partitions already scanned, skip scanning
  if [[ "$PART_MENU_READY" != "1" ]]; then
    dialog --infobox "Scanning partitions..." 3 27
    
    PART_MENU=()
    PART_NUM_MAP=()
    FDISK_LINE_MAP=()
    part_start_lba_map=()
    parts_sorted=()

    while true; do
      # Get disk base name, e.g. 'sda' from '/dev/sda'
      disk_basename=$(basename "$DISK_SELECTED")

      # Get partition info with lsblk: NAME, SIZE, FSTYPE, LABEL
      mapfile -t parts < <(lsblk -ln -o NAME,SIZE,FSTYPE,LABEL "/dev/$disk_basename")

      # Get detailed partition info from fdisk
      fdisk_output=$(sudo fdisk -l "$DISK_SELECTED" 2>/dev/null)

      # Extract lines for partitions on this disk, e.g. /dev/sda1, /dev/sda2...
      mapfile -t fdisk_parts < <(echo "$fdisk_output" | grep "^/dev/$disk_basename" | grep -E "^/dev/${disk_basename}p?[0-9]+")

      # Map device to full fdisk line
      for line in "${fdisk_parts[@]}"; do
        dev=$(echo "$line" | awk '{print $1}')
        FDISK_LINE_MAP["$dev"]="$line"
      done

      # Map partition start LBA to device
      for line in "${fdisk_parts[@]}"; do
        # Handle possible boot '*' flag in second field
        boot_or_start=$(echo "$line" | awk '{print $2}')
        if [[ "$boot_or_start" == "*" ]]; then
          start_lba=$(echo "$line" | awk '{print $3}')
        else
          start_lba="$boot_or_start"
        fi
        dev=$(echo "$line" | awk '{print $1}')
        part_start_lba_map["$dev"]=$start_lba
      done

      # Prepare array to sort partitions by start LBA
      for part_info in "${parts[@]}"; do
        # Read NAME SIZE FSTYPE LABEL properly
        read -r part_name part_size part_fstype part_label <<<"$part_info"
        full_path="/dev/$part_name"
        # Skip if no fdisk info available
        [[ -z "${part_start_lba_map[$full_path]}" ]] && continue
        parts_sorted+=("${part_start_lba_map[$full_path]}:$part_info")
      done

      # Sort partitions by LBA start
      IFS=$'\n' sorted=($(sort -n <<<"${parts_sorted[*]}"))
      unset IFS

      # Rebuild sorted parts array without LBA prefix
      parts=()
      for item in "${sorted[@]}"; do
        parts+=("${item#*:}")
      done

      for part_info in "${parts[@]}"; do
        read -r part_name part_size fstype label <<<"$part_info"
        full_path="/dev/$part_name"

        part_line="${FDISK_LINE_MAP[$full_path]}"
        [[ -z "$part_line" ]] && continue

        # Split fdisk line into fields
        read -r -a fields <<<"$part_line"

        # Determine index of partition type ID in fdisk line
        if [[ "${fields[1]}" == "*" ]]; then
          id_index=6
        else
          id_index=5
        fi

        id_value="${fields[$id_index]}"
        # If id_value not hex, fallback to 2nd last field (safe way to handle variable output)
        if ! [[ "$id_value" =~ ^[0-9a-fA-F]+$ ]]; then
          id_value="${fields[$((${#fields[@]} - 2))]}"
        fi
        id_value=$(echo "$id_value" | tr '[:upper:]' '[:lower:]')

        # Active (boot) and hidden flag
        active_flag=" "
        hidden_flag=" "
        [[ "${fields[1]}" == "*" ]] && active_flag="A"
        [[ "$id_value" =~ ^1[0-9a-f]$ ]] && hidden_flag="H"

        # Partition number from device name
        part_number=$(echo "$full_path" | grep -oE '[0-9]+$')
        part_type_id=$(lsblk -no PARTTYPE "$full_path")
        
        part_type="PRI"
        (( part_number >= 5 )) && part_type="LOG"
        
        if [[ "$part_type_id" == "0x5" || "$part_type_id" == "0xf" || "$part_type_id" == "0x15" || "$part_type_id" == "0x1f" ]]; then
          part_type="EXT"
        fi

        # Map partition ID to display filesystem
        case "$id_value" in
          1|11)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="FAT12"
            fi
            ;;
          4|6|14|16)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="FAT16 CHS"
            fi
            ;;
          e|1e)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="FAT16 LBA"
            fi
            ;;
          b|1b)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="FAT32 CHS"
            fi
            ;;
          c|1c)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="FAT32 LBA"
            fi
            ;;
          7|17)
            if [[ "$fstype" == "ntfs" ]]; then
              fs_display="NTFS"
            elif [[ "$fstype" == "exfat" ]]; then
              fs_display="exFAT"
            elif [[ "$fstype" == "hpfs" ]]; then
              fs_display="HPFS"
            elif [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="${fstype^^}"
            fi
            ;;
          5)
            fs_display="Extended DOS"
            ;;
          f)
            fs_display="Extended LBA"
            ;;
          *)
            if [[ -z "$fstype" ]]; then
              fs_display="Unformatted"
            else
              fs_display="${fstype^^}"  # Uppercase fallback
            fi
            ;;
        esac

        # Mount partition readonly to get size info
        tmp_mount="/tmp/mnt_$part_name"
        sudo mkdir -p "$tmp_mount"
        sudo umount "$tmp_mount" 2>/dev/null

        if sudo mount -o ro "$full_path" "$tmp_mount" 2>/dev/null; then
          df_out=$(df -kP "$tmp_mount" | awk 'NR==2 {print $2, $4}')
          total_kb=$(echo "$df_out" | cut -d' ' -f1)
          free_kb=$(echo "$df_out" | cut -d' ' -f2)
          sudo umount "$tmp_mount"
          rm -rf "$tmp_mount"

          size_fmt=$(format_size "$total_kb")
          free_fmt=$(format_size "$free_kb")
        else
          size_fmt="N/A"
          free_fmt="N/A"
        fi

        desc=$(printf "%s%s %s | FS: %-9s | Size: %-9s | Free: %-9s" "$active_flag" "$hidden_flag" "$part_type" "$fs_display" "$size_fmt" "$free_fmt")

        # Add to menu list
        PART_MENU+=("$full_path" "$desc")

        # Map partition number for later use
        PART_NUM_MAP["$full_path"]="$part_number"
      done

      # If no partitions found, show error and exit
      if [[ ${#PART_MENU[@]} -eq 0 ]]; then
        dialog --msgbox "No partitions found on $DISK_SELECTED." 7 50
        return 1
      fi

      # Mark partitions scanned
      # PART_MENU_READY=1 // makes problem when more than one disk
      break
    done
  fi
  
  while true; do
    # Show dialog menu to select partition
    selected_partition=$(dialog --clear --backtitle "Partition Selection" \
      --title "Select Partition" \
      --menu "Choose a partition to format:" 20 80 10 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    # Handle cancel or empty selection
    if [[ $? -ne 0 || -z "$selected_partition" ]]; then
      return 1
    fi

    # === Check if selected partition is EXT ===
    part_line="${FDISK_LINE_MAP[$selected_partition]}"
    [[ -z "$part_line" ]] && continue  # safety fallback

    read -r -a fields <<<"$part_line"
    if [[ "${fields[1]}" == "*" ]]; then
      id_index=6
    else
      id_index=5
    fi

    id_value="${fields[$id_index]}"
    if ! [[ "$id_value" =~ ^[0-9a-fA-F]+$ ]]; then
      id_value="${fields[$((${#fields[@]} - 2))]}"
    fi
    id_value=$(echo "$id_value" | tr '[:upper:]' '[:lower:]')

    if [[ "$id_value" == "5" || "$id_value" == "f" || "$id_value" == "15" || "$id_value" == "1f" ]]; then
      dialog --msgbox "Extended partitions cannot be formatted!\nPlease choose a primary or logical partition." 7 60
      continue  # show menu again
    fi

    # Passed check
    break
  done
  
  PARTITION_SELECTED="$selected_partition"
  PARTITION_NUMBER="${PART_NUM_MAP[$selected_partition]}"
  return 0
}

# === Step 3: Confirm formatting ===
confirm_format() {
  dialog --yesno "WARNING: All data will be permanently erased on:\n\n$PARTITION_SELECTED\n\nProceed with formatting?" 10 60
  [[ $? -eq 0 ]]
}

# === Step 4: Format partition ===
detect_and_format() {
  partname=$(basename "$PARTITION_SELECTED")
  part_line=$(fdisk -l "$DISK_SELECTED" 2>/dev/null | grep -E "^/dev/$partname[[:space:]]") || {
    dialog --msgbox "Failed to get partition info from fdisk." 7 50
    return 1
  }

  read -r -a fields <<< "$part_line"
  id_index=$([[ "${fields[1]}" == "*" ]] && echo 6 || echo 5)
  ID="${fields[$id_index]}" ; ID=${ID,,}
  [[ ${#ID} -gt 2 ]] && ID="${ID:0:2}"

  partnum=$(echo "$partname" | grep -o '[0-9]\+$')
  size_bytes=$(blockdev --getsize64 "$PARTITION_SELECTED")
  size_kb=$(( size_bytes / 1024 ))
  size_mb=$(( size_kb / 1024 ))

  format_cmd=""
  set_id="$ID"
  LABEL=""
  FS_TYPE=""
  ACCESS_MODE=""

  # === Step 1: Choose valid filesystems based on partition size ===
  FS_OPTIONS=()
  (( size_mb >= 1 && size_mb < 16 ))    && FS_OPTIONS+=("FAT12"  "File Allocation Table 12 bit")
  (( size_mb >= 16 && size_mb < 4096 )) && FS_OPTIONS+=("FAT16"  "File Allocation Table 16 bit")
  (( size_mb >= 32 ))                   && FS_OPTIONS+=("FAT32"  "File Allocation Table 28 bit")
  (( size_mb >= 10 ))                   && FS_OPTIONS+=("NTFS"   "New Technology File System 3.x")
  (( size_mb >= 512 ))                  && FS_OPTIONS+=("exFAT"  "Extended File Allocation Table")

  if [[ ${#FS_OPTIONS[@]} -eq 0 ]]; then
    dialog --msgbox "No compatible filesystems for ${size_mb} MB partition." 7 50
    return 1
  fi

  FS_TYPE=$(dialog --menu "Select filesystem to format partition:" 15 50 6 "${FS_OPTIONS[@]}" 3>&1 1>&2 2>&3) || return 1

  # === Step 2: Access type for FAT16/FAT32 ===
  if [[ "$FS_TYPE" == "FAT16" || "$FS_TYPE" == "FAT32" ]]; then
    ACCESS_MODE=$(dialog --menu "Select access mode:" 10 43 2 CHS "CHS (Cylinder/Head/Sector)" LBA "LBA (Logical Block Addressing)" 3>&1 1>&2 2>&3) || return 1
  fi

  # === Step 3: Label input ===
  while true; do
    LABEL=$(dialog --inputbox "Enter volume label (A-Z, a-z, 0-9, space, _ and - allowed):" 10 60 3>&1 1>&2 2>&3) || return 1
    LABEL="${LABEL#"${LABEL%%[![:space:]]*}"}"
    LABEL="${LABEL%"${LABEL##*[![:space:]]}"}"

    [[ -z "$LABEL" ]] && break

    if [[ "$FS_TYPE" == "NTFS" ]]; then
      maxlen=255
    elif [[ "$FS_TYPE" == "exFAT" ]]; then
      maxlen=15
    else  # FAT12/FAT16/FAT32
      maxlen=11
    fi

    if [[ ${#LABEL} -gt $maxlen ]]; then
      dialog --msgbox "Label too long. Max allowed: $maxlen characters." 6 40
      continue
    elif echo "$LABEL" | grep -qvE '^[a-zA-Z0-9 _-]+$'; then
      dialog --msgbox "Invalid characters in label." 6 40
      continue
    fi
    break
  done

  # === Step 4: Construct format command ===
  case "$FS_TYPE" in
    FAT12)
      format_cmd="mkfs.fat -F 12" ; set_id="1" ;;
    FAT16)
      format_cmd="mkfs.fat -F 16"
      [[ "$ACCESS_MODE" == "CHS" ]] && set_id="6"
      [[ "$ACCESS_MODE" == "LBA" ]] && set_id="e"
      ;;
    FAT32)
      format_cmd="mkfs.fat -F 32"
      [[ "$ACCESS_MODE" == "CHS" ]] && set_id="b"
      [[ "$ACCESS_MODE" == "LBA" ]] && set_id="c"
      ;;
    NTFS)
      format_cmd="mkfs.ntfs -f" ; set_id="7" ;;
    exFAT)
      format_cmd="mkfs.exfat" ; set_id="7" ;;
    *)
      dialog --msgbox "Unsupported filesystem selected." 6 40
      return 1 ;;
  esac

  # === Step 5: Execute format ===
  # Determine the correct label flag
  label_flag="-n"  # default for FAT
  [[ "$FS_TYPE" == "NTFS" || "$FS_TYPE" == "exFAT" ]] && label_flag="-L"

  # Add label if specified
  [[ -n "$LABEL" ]] && format_cmd+=" $label_flag \"$LABEL\""

  if ! eval sudo $format_cmd "$PARTITION_SELECTED" >/dev/null 2>&1; then
    dialog --msgbox "Format failed!" 6 40
    return 1
  fi

  sudo sfdisk --part-type "$DISK_SELECTED" "$partnum" "$set_id" >/dev/null 2>&1

  #  NTFS/exFAT post-labeling if needed
  #  if [[ "$FS_TYPE" == "NTFS" && -n "$LABEL" ]]; then
  #    sudo ntfslabel "$PARTITION_SELECTED" "$LABEL" >/dev/null 2>&1
  #  fi

  dialog --msgbox "Partition $PARTITION_SELECTED successfully formatted as $FS_TYPE." 6 50
  PART_MENU_READY=0  # force re-scan next time
  return 0
}

# === Main loop ===
while true; do
  select_disk
  while true; do
    if ! select_partition; then break; fi
    if confirm_format && detect_and_format; then
      continue
    else
      continue
    fi
  done
done


