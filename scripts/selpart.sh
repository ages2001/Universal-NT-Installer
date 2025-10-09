#!/bin/bash

INSTLR_DEVICE="$1"
WIM_FILE="$2"
WIM_FILE_INDEX="$3"
OSCODE="$4"
SETUP_TYPE="$5"
WIM_IMAGE_INFO="$6"

if [[ -z "$INSTLR_DEVICE" || -z "$WIM_FILE" || -z "$WIM_FILE_INDEX" || -z "$OSCODE" || -z "$SETUP_TYPE" || -z "$WIM_IMAGE_INFO" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

declare -a DISK_MENU=()
declare -A DISK_INFO=()

declare -a PART_MENU=()
declare -A PART_INDEX_MAP=()
declare -A PART_FS_MAP=()
declare -A PART_LABEL_MAP=()
declare -A PART_SIZE_MAP=()
declare -A PART_FREE_KB_MAP=()
declare -A HAS_OLD_OS_MAP=()

parts_scanned=0

check_appletv() {
  if [[ $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null) == "AppleTV1,1" ]]; then
    echo "Yes"
  else
    echo "No"
  fi
}

scan_disks() {
  dialog --infobox "Scanning disks..." 3 22

  for disk in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [[ ! -b "$disk" ]] && continue
    type=$(lsblk -dn -o TYPE "$disk" 2>/dev/null)
    [[ "$type" != "disk" ]] && continue
	
	CNTRLR=$(get_disk_interface_type "$disk")
	
	case "$CNTRLR" in
      "IDE"|"SATA (IDE)"|"AHCI"|"RAID"|"eMMC"|"NVMe"|"SCSI")
        ;;  # accepted types -> do nothing
      *)
        continue  # skip unsupported types
        ;;
    esac
    
    # Installer device skipped
    [[ $INSTLR_DEVICE == $disk* ]] && continue

    part_table=$(sudo parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2 {print $6}')
    case "$part_table" in
      msdos) table_type="MBR" ;;
      gpt)   table_type="GPT" ;;
      *)
        # If parted result is not valid, try fdisk as a fallback
        fdisk_type=$(sudo fdisk -l "$disk" 2>/dev/null | grep "Disklabel type" | awk '{print $3}')
        case "$fdisk_type" in
          dos) table_type="MBR" ;;
          gpt) table_type="GPT" ;;
          "")  table_type="Unknown" ;;
          *)   table_type="${fdisk_type^^}" ;;
        esac
        ;;
    esac

    disk_basename=$(basename "$disk")
    sector_size=$(cat /sys/block/$disk_basename/queue/hw_sector_size 2>/dev/null || echo 512)
    sector_count=$(cat /sys/block/$disk_basename/size 2>/dev/null || echo 0)
    size_bytes=$((sector_count * sector_size))
    size_kb=$((size_bytes / 1024))
    size_fmt=$(format_size "$size_kb")

    DISK_MENU+=("$disk" "Size: $size_fmt | Type: $table_type | Cntrlr: $CNTRLR")
    DISK_INFO["$disk,type"]="$table_type"
    DISK_INFO["$disk,size"]="$size_fmt"
  done

  if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
    dialog --msgbox "No suitable disks found." 7 50
    exit 1
  fi
}

scan_partitions() {
  dialog --infobox "Scanning partitions..." 3 27
  
  PART_MENU=()
  PART_INDEX_MAP=()
  PART_FS_MAP=()
  PART_LABEL_MAP=()
  PART_SIZE_MAP=()
  PART_FREE_KB_MAP=()
  HAS_OLD_OS_MAP=()
  
  index=1
  DISK_SELECTED=$1

  DISK_BASENAME=$(basename "$DISK_SELECTED")
  mapfile -t parts < <(lsblk -ln -o NAME,SIZE,FSTYPE,LABEL "/dev/$DISK_BASENAME")
  FDISK_OUTPUT=$(sudo fdisk -l "$DISK_SELECTED" 2>/dev/null)

  mapfile -t fdisk_parts < <(echo "$FDISK_OUTPUT" | grep "^/dev/$DISK_BASENAME" | grep -E "^/dev/${DISK_BASENAME}p?[0-9]+")
    
  declare -A FDISK_LINE_MAP
  for line in "${fdisk_parts[@]}"; do
    dev=$(echo "$line" | awk '{print $1}')
    FDISK_LINE_MAP["$dev"]="$line"
  done

  declare -A part_start_lba_map=()
  for line in "${fdisk_parts[@]}"; do
    read -r dev boot_or_start rest <<<"$line"
    if [[ "$boot_or_start" == "*" ]]; then
      start_lba=$(echo "$line" | awk '{print $3}')
    else
      start_lba=$(echo "$line" | awk '{print $2}')
    fi
    part_start_lba_map["$dev"]=$start_lba
  done

  declare -a parts_sorted=()
  for part_info in "${parts[@]}"; do
    read -r part_name size fstype label <<<"$part_info"
    full_path="/dev/$part_name"
    [[ -z "${part_start_lba_map[$full_path]}" ]] && continue
    parts_sorted+=("${part_start_lba_map[$full_path]}:$part_info")
  done

  IFS=$'\n' sorted=($(sort -n <<<"${parts_sorted[*]}"))
  unset IFS

  parts=()
  for item in "${sorted[@]}"; do
    part_info="${item#*:}"
    parts+=("$part_info")
  done

  for part_info in "${parts[@]}"; do
    read -r part_name size fstype label <<<"$part_info"
    full_path="/dev/$part_name"

    part_line="${FDISK_LINE_MAP[$full_path]}"
    [[ -z "$part_line" ]] && continue
      
    read -r -a fields <<<"$part_line"

    [[ "${fields[1]}" == "*" ]] && id_index=6 || id_index=5
    id_value="${fields[$id_index]}"
    [[ ! "$id_value" =~ ^[0-9a-fA-F]+$ ]] && id_value="${fields[$((${#fields[@]} - 2))]}"
    id_value=$(echo "$id_value" | tr '[:upper:]' '[:lower:]')
      
    active_flag=" "
    if [[ "${fields[1]}" == "*" ]]; then
      active_flag="A"
    fi
      
    hidden_flag=" "
    if [[ "$id_value" =~ ^1[0-9a-f]$ ]]; then
      hidden_flag="H"
    fi
      
    part_number=$(echo "$full_path" | sed -E 's/^.*p?([0-9]+)$/\1/')
    part_type="PRI"
    if [[ "$part_number" -ge 5 ]]; then
      part_type="LOG"
    fi
    if [[ "$id_value" == "5" || "$id_value" == "f" || "$id_value" == "15" || "$id_value" == "1f" ]]; then
      part_type="EXT"
	  continue
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
      5|15)
        fs_display="Extended DOS"
        ;;
      f|1f)
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

    label_display="${label:-"-"}"

    TMP_MOUNT="/tmp/mnt_$part_name"
    sudo mkdir -p "$TMP_MOUNT"
    sudo umount "$TMP_MOUNT" 2>/dev/null

    HAS_OLD_OS_MAP["$full_path"]=0
    if sudo mount -o ro "$full_path" "$TMP_MOUNT" 2>/dev/null \
      || { [[ "$fstype" == "ntfs" || -z "$fstype" ]] && sudo ntfs-3g -o ro "$full_path" "$TMP_MOUNT" 2>/dev/null; } \
      || { [[ "$fstype" == "ntfs" || -z "$fstype" ]] && sudo mount -t ntfs3 -o force "$full_path" "$TMP_MOUNT" 2>/dev/null; }
    then
      # Get total and free space in KB from df
      df_out=$(df -kP "$TMP_MOUNT" | awk 'NR==2 {print $2, $4}')
      free_kb=$(echo "$df_out" | cut -d' ' -f2)
	  
      # Total size in KB using lsblk
      part_name=$(basename "$full_path")
      part_bytes=$(lsblk -b -n -o KNAME,SIZE 2>/dev/null | awk -v part="$part_name" '$1 ~ part { print $2; exit }')

      if [[ -n "$part_bytes" ]]; then
        total_kb=$(awk -v b="$part_bytes" 'BEGIN { printf "%.2f", b / 1024 }')
      else
        total_kb=0
      fi

      [[ -z "$total_kb" ]] && total_kb=0

      PART_SIZE_KB_MAP["$index"]="$total_kb"
      PART_FREE_KB_MAP["$index"]="$free_kb"

      # Check for old OS folders if needed
      for folder in "${OLD_OS_FOLDERS[@]}"; do
        if find "$TMP_MOUNT" -maxdepth 1 -type d -iname "$folder" | grep -q .; then
          HAS_OLD_OS_MAP["$full_path"]=1
          break
        fi
      done

      sudo umount "$TMP_MOUNT"
      rm -rf "$TMP_MOUNT"

      # Format sizes for display
      size_fmt=$(format_size "$total_kb")
      avail_fmt=$(format_size "$free_kb")
    else
      size_fmt="N/A"
      avail_fmt="N/A"
      PART_SIZE_KB_MAP["$index"]=0
      PART_FREE_KB_MAP["$index"]=0
    fi

    desc=$(printf "%s%s %s | FS: %-9s | Size: %-9s | Free: %-9s" "$active_flag" "$hidden_flag" "$part_type" "$fs_display" "$size_fmt" "$avail_fmt")

    PART_MENU+=("$full_path" "$desc")
    PART_INDEX_MAP["$full_path"]="$index"
    PART_FS_MAP["$full_path"]="$fs_display"
    PART_LABEL_MAP["$full_path"]="$label_display"
    PART_SIZE_MAP["$full_path"]="$size_fmt"
    PART_FREE_KB_MAP["$full_path"]="$free_kb"

    ((index++))
  done
}

# Format size function: input in KB, output in KB/MB/GB/TB with decimals
format_size() {
  local size_kb=$1
  local result

  if awk "BEGIN {exit !($size_kb < 1024)}"; then
    result=$(awk -v kb="$size_kb" 'BEGIN { val=kb; fmt=sprintf("%.2f KB", val); print fmt }')
  elif awk "BEGIN {exit !($size_kb < 1024*1024)}"; then
    result=$(awk -v kb="$size_kb" 'BEGIN { val=kb/1024; fmt=sprintf("%.2f MB", val); print fmt }')
  elif awk "BEGIN {exit !($size_kb < 1024*1024*1024)}"; then
    result=$(awk -v kb="$size_kb" 'BEGIN { val=kb/1024/1024; fmt=sprintf("%.2f GB", val); print fmt }')
  else
    result=$(awk -v kb="$size_kb" 'BEGIN { val=kb/1024/1024/1024; fmt=sprintf("%.2f TB", val); print fmt }')
  fi

  # Clean up trailing zeros after the decimal point
  result=$(awk -v v="$result" 'BEGIN {
    # Split value and unit
    split(v, arr, " ")
    val = arr[1]
    unit = arr[2]

    # Only process if there is a decimal point
    if (val ~ /\./) {
        sub(/\.00$/, "", val)       # remove .00
        if (val ~ /\./) {
            sub(/0$/, "", val)      # remove trailing 0 from .x0
        }
    }

    # Recombine value and unit
    if (unit != "") {
        v = val " " unit
    } else {
        v = val
    }
    print v
  }')

  echo "$result"
}

check_partition_compatibility() {
  local part_type="$1"
  local fs_type="$2"
  local disk="$3"
  local start_lba="$4"
  local end_lba="$5"
  local edition_desc="$6"
  
  # Check for extended partition
  if [[ "$part_type" == "EXT" ]]; then
    dialog --msgbox "Installation is not possible on an extended partition!\n\nPlease choose a primary or logical partition." 7 60
    return 1
  fi
  
  # Check for unformatted partition
  if [[ "$fs_type" == "Unformatted" ]]; then
    dialog --msgbox "The selected partition is unformatted.\n\nPlease format it before installing OS." 7 60
    return 1
  fi

  local sector_size=$(cat /sys/block/$(basename "$disk")/queue/logical_block_size 2>/dev/null)
  [[ -z "$sector_size" || "$sector_size" -le 0 ]] && sector_size=512  # Default fallback

  local chs_limit_8gb=$(( 7987 * 1024 * 1024 / sector_size ))
  local lba_limit_137gb=$(( 137400000000 / sector_size ))

  # Windows NT 3.1 / 3.50 / 3.51 Vanilla
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.[15] && "$edition_desc" =~ Vanilla ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" ]] || (( end_lba > chs_limit_8gb )); then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirements:\n* FAT12 or FAT16 formatted partition\n* Entire partition must reside within the first 8.3 GB of the disk\n* Must be CHS-accessible" 12 60
      return 1
    fi
  fi

  # Windows NT 3.51 Patched
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.51 && "$edition_desc" =~ Patched ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirements:\n* FAT12, FAT16, or FAT32 formatted partition" 9 60
      return 1
    fi
  fi

  # Windows NT 4.0 Vanilla
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.00 && "$edition_desc" =~ Vanilla ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "NTFS" ]] || (( end_lba > lba_limit_137gb )); then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirements:\n* FAT12, FAT16, or NTFS formatted partition\n* Entire partition must reside within the first 137.4 GB of the disk" 11 60
      return 1
    fi
  fi
  
  # Windows NT 4.0 Patched
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.00 && "$edition_desc" =~ Patched ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirements:\n* FAT12, FAT16, FAT32 or NTFS formatted partition" 9 60
      return 1
    fi
  fi

  # Windows 2000 or XP (any edition)
  if [[ "$edition_desc" =~ Windows\ 2000 || "$edition_desc" =~ Windows\ XP ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirements:\n* FAT12, FAT16, FAT32 or NTFS formatted partition" 9 60
      return 1
    fi
  fi
  
  # Apple TV (Any version)
  if [[ "$edition_desc" =~ Bootloader ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" ]]; then
      dialog --msgbox "Incompatible bootloader partition!\n\nRequirements:\n* FAT12, FAT16, or FAT32 formatted partition" 9 60
      return 1
    fi
  fi
  return 0
}

check_partition_compatibility_custom() {
  local part_type="$1"
  local fs_type="$2"
  
  # Check for extended partition
  if [[ "$part_type" == "EXT" ]]; then
    dialog --msgbox "Installation is not possible on an extended partition!\n\nPlease choose a primary or logical partition." 7 60
    return 1
  fi
  
  # Check for unformatted partition
  if [[ "$fs_type" == "Unformatted" ]]; then
    dialog --msgbox "The selected partition is unformatted.\n\nPlease format it before installing OS." 7 60
    return 1
  fi
  
  if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" ]]; then
    dialog --msgbox "Incompatible partition filesystem!\n\nRequirements:\n* FAT12, FAT16, FAT32 or NTFS formatted partition" 9 60
    return 1
  fi
  
  return 0
}

check_free_space() {
  local free_kb="$1"
  local edition_desc="$2"

  local required_kb=0

  if [[ "$edition_desc" =~ Windows\ NT\ 3\.(1|50|51) && "$edition_desc" =~ Vanilla ]]; then
    required_kb=$((60 * 1024))
  elif [[ "$edition_desc" =~ Windows\ NT\ 3\.51 && "$edition_desc" =~ Patched ]]; then
    required_kb=$((70 * 1024))
  elif [[ "$edition_desc" =~ Windows\ NT\ 4\.00 && "$edition_desc" =~ Vanilla ]]; then
    required_kb=$((140 * 1024))
  elif [[ "$edition_desc" =~ Windows\ NT\ 4\.00 && "$edition_desc" =~ Patched ]]; then
    required_kb=$((160 * 1024))
  elif [[ "$edition_desc" =~ Windows\ 2000 && "$edition_desc" =~ Vanilla ]]; then
    required_kb=$((850 * 1024))
  elif [[ "$edition_desc" =~ Windows\ 2000 && "$edition_desc" =~ Patched ]]; then
    required_kb=$((790 * 1024))
  elif [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ 86 && "$edition_desc" =~ Vanilla ]]; then
    required_kb=$((950 * 1024))
  elif [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ 86 && "$edition_desc" =~ Patched && "$edition_desc" =~ 5.1 ]]; then
    required_kb=$((980 * 1024))
  elif [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ 86 && "$edition_desc" =~ Patched && "$edition_desc" =~ 5.2 ]]; then
    required_kb=$((860 * 1024))
  elif [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ 64 && "$edition_desc" =~ Vanilla ]]; then
    required_kb=$((1350 * 1024))
  elif [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ 64 && "$edition_desc" =~ Patched ]]; then
    required_kb=$((1450 * 1024))
  elif [[ "$edition_desc" =~ Apple\ TV ]]; then
    required_kb=$((50 * 1024))
  else
    required_kb=$((1536 * 1024))
  fi

  if (( free_kb < required_kb )); then
    local free_fmt=$(format_size "$free_kb")
    local required_fmt=$(format_size "$required_kb")
    dialog --msgbox "Not enough free space on selected partition for $edition_desc!\n\nRequired: $required_fmt\nAvailable: $free_fmt" 10 50
    return 1
  fi

  return 0
}

check_free_space_custom() {
  local free_kb="$1"
  
  local total_bytes=0
  local custom_WIM_file_path="/mnt/isofiles/osfiles/custom/$WIM_FILE"
  
  total_bytes=$(wimlib-imagex info "$custom_WIM_file_path" "$WIM_FILE_INDEX" \
  | grep -i -m1 'Total Bytes' | sed -E 's/[^0-9]//g' | tr -d '\r')

  if [[ -z "$total_bytes" ]]; then
    dialog --msgbox "Failed to read WIM file size!\n\nFile: $WIM_FILE\nIndex: $WIM_FILE_INDEX" 9 60
    return 1
  fi

  local required_kb=$(( (((total_bytes / 1024 + 10240) + 1023) / 1024) * 1024 ))

  if (( free_kb < required_kb )); then
    local free_fmt=$(format_size "$free_kb")
    local required_fmt=$(format_size "$required_kb")
    dialog --msgbox "Not enough free space on selected partition!\n\nRequired: $required_fmt\nAvailable: $free_fmt" 8 50
    return 1
  fi

  return 0
}

get_disk_interface_type() {
  local disk="$1"
  local sys_path pci_addr pci_id_short lspci_out

  # Ensure we're using only the disk name (e.g., "sda" from "/dev/sda")
  disk=$(basename "$disk")
  
  if [[ "$disk" == *nvme* ]]; then
    echo "NVMe"
    return
  fi
  
  if [[ "$disk" == *mmc* ]]; then
    if [[ -e "/sys/block/${disk}boot0" || -e "/sys/block/${disk}boot1" ]]; then
      echo "eMMC"
    else
      echo "SD/MMC"
    fi
    return
  fi
  
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
  [[ -z "$lspci_out" ]] && { echo "Unknown"; return; }

  # Identify controller type
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
  
  if echo "$lspci_out" | grep -qi "bolt"; then
    echo "Thunderbolt"
	return
  fi
  
  if echo "$lspci_out" | grep -qi "usb"; then
    if echo "$lspci_out" | grep -qiE "xhci|extensible "; then
      echo "USB 3.x"
    elif echo "$lspci_out" | grep -qiE "ehci|enhanced|[[:space:]]2\.0[[:space:]]"; then
      echo "USB 2.0"
    elif echo "$lspci_out" | grep -qiE "uhci|ohci|universal|open|[[:space:]]1\.1[[:space:]]|[[:space:]]1\.0[[:space:]]"; then
      echo "USB 1.x"
    else
      echo "USB"
    fi
    return
  fi
  
  if echo "$lspci_out" | grep -qiE 'firewire|ieee'; then
    echo "IEEE 1394"
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
  
  if echo "$lspci_out" | grep -qiE 'pcmcia|cardbus'; then
    echo "PCMCIA"
    return
  fi

  echo "Unknown"
}

get_disk_irq() {
  local disk_base pci_path pci_addr short_pci_addr irq driver irq_line irq_num
  disk_base=$(basename "$1")

  # Get full device path
  pci_path=$(readlink -f "/sys/block/$disk_base/device" 2>/dev/null)
  [[ -z "$pci_path" ]] && { echo "Unknown"; return; }

  # Search PCI address in full path (regex match inside path)
  pci_addr=$(echo "$pci_path" | grep -oE '([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
  [[ -z "$pci_addr" ]] && { echo "Unknown"; return; }

  # Strip the domain part (e.g., 0000:) if present
  short_pci_addr="${pci_addr#0000:}"

  # Extract IRQ from lspci
  irq=$(lspci -v -s "$short_pci_addr" 2>/dev/null | awk '/\bIRQ\b/ {print $2; exit}')

  if [[ -z "$irq" ]]; then
    # Fallback: try /proc/interrupts based on driver name

    driver=$(basename "$(readlink -f /sys/bus/pci/devices/$pci_addr/driver)" 2>/dev/null)
    if [[ -n "$driver" ]]; then
      irq_line=$(grep "$driver" /proc/interrupts | head -n1)
      if [[ -n "$irq_line" ]]; then
        irq_num=$(echo "$irq_line" | awk -F: '{print $1}' | tr -d ' ')
        irq="$irq_num"
      fi
    fi
  fi

  [[ -z "$irq" ]] && irq="Unknown"

  echo "$irq"
}

controller_OS_check() {
  local controller="$1"
  local edition_desc="$2"
  local irq="$3"

  # NT 3.x Vanilla only IDE allowed
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.[01-9] ]] && [[ "$edition_desc" =~ Vanilla ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" ]]; then
      dialog --msgbox "Only IDE disks are supported for $edition_desc!" 7 60
      return 1
    fi
    # IRQ must be 14 for NT 3.1 Vanilla IDE controller
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.1 && "$edition_desc" =~ Vanilla && "$irq" != "14" ]]; then
      dialog --msgbox "For $edition_desc, IDE or SATA (IDE) controller IRQ must be 14!\n\nDetected IRQ: $irq" 8 60
      return 1
    fi
  fi

  # NT 3.51 Patched allows IDE and AHCI
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.51 ]] && [[ "$edition_desc" =~ Patched ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" ]]; then
      dialog --msgbox "Only IDE and AHCI disks are supported for $edition_desc!" 7 60
      return 1
    fi
  fi

  # NT 4.0 Vanilla, 2000 Vanilla, XP Vanilla only IDE allowed
  if ([[ "$edition_desc" =~ Windows\ NT\ 4\.0 ]] || [[ "$edition_desc" =~ Windows\ 2000 ]] || [[ "$edition_desc" =~ Windows\ XP ]]) && [[ "$edition_desc" =~ Vanilla ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" ]]; then
      dialog --msgbox "Only IDE disks are supported for $edition_desc!" 7 60
      return 1
    fi
  fi

  # NT 4.0 Patched allows IDE and AHCI
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.0 ]] && [[ "$edition_desc" =~ Patched ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" ]]; then
      dialog --msgbox "Only IDE and AHCI disks are supported for $edition_desc!" 7 60
      return 1
    fi
  fi

  # 2000 Patched: IDE, AHCI and NVMe
  if [[ "$edition_desc" =~ Windows\ 2000 ]] && [[ "$edition_desc" =~ Patched ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "NVMe" ]]; then
      dialog --msgbox "Only IDE, AHCI and NVMe disks are supported for $edition_desc!" 7 60
      return 1
    fi
  fi

  # XP (x86/x64) Patched: IDE, AHCI, RAID, eMMC and NVMe
  if [[ "$edition_desc" =~ Windows\ XP ]] && [[ "$edition_desc" =~ Patched ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "RAID" && "$controller" != "eMMC" && "$controller" != "NVMe" ]]; then
      dialog --msgbox "Only IDE, AHCI, RAID, eMMC and NVMe disks are supported for $edition_desc!" 7 60
      return 1
    fi
  fi

  # Otherwise allow
  return 0
}

check_disk_position() {
  local device="$1"       # e.g. /dev/sda
  local edition_desc="$2" # OS edition string

  # 1) Get disk controller type
  local controller
  controller=$(get_disk_interface_type "$device")
  
  # Skip check for non-IDE disks
  if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" ]]; then
    return 0
  fi

  # 2) Get sysfs path for block device
  local sys_path="/sys/block/$(basename "$device")"
  if [[ ! -e "$sys_path" ]]; then
    dialog --msgbox "Sysfs path $sys_path does not exist for device $device." 7 60
    return 1
  fi

  # 3) Get DEVPATH from udevadm info using --path
  local devpath
  devpath=$(udevadm info --query=all --path="$sys_path" 2>/dev/null | grep '^E: DEVPATH=' | cut -d= -f2)
  if [[ -z "$devpath" ]]; then
    dialog --msgbox "Failed to retrieve DEVPATH for device $device." 7 60
    return 1
  fi

  # 4) Extract ataX from DEVPATH
  local ata_name=""
  if [[ "$devpath" =~ /ata([0-9]+)/ ]]; then
    ata_name="ata${BASH_REMATCH[1]}"
  else
    dialog --msgbox "Could not extract ataX from DEVPATH: $devpath" 7 70
    return 1
  fi
  
  local appletv=$(check_appletv)

  # 5) Determine IDE channel (0 = primary, 1 = secondary) from dmesg by ataX
  # Only check for PATA IDE
  if [[ "$appletv" == "No" ]]; then # HACK!!!
    if [[ "$controller" == "IDE" ]]; then
      local channel=""
      while read -r line; do
        if [[ "$line" =~ ($ata_name).*cmd\ (0x[0-9a-f]+) ]]; then
          case "${BASH_REMATCH[2]}" in
            0x1f0) channel=0 ;;  # Primary
            0x170) channel=1 ;;  # Secondary
            *) channel="unknown" ;;
          esac
          break
        fi
      done < <(dmesg | grep -i "PATA max")

      if [[ -z "$channel" || "$channel" == "unknown" ]]; then
        dialog --msgbox "Unable to determine IDE channel for $ata_name based on dmesg output." 7 70
        return 1
      fi
    fi
  fi

  # 6) Extract device position (Y) from DEVPATH (targetX:0:Y)
  local position=""
  local sata_port=""
  if [[ "$devpath" =~ target([0-9]+):[0-9]+:([0-9]+) ]]; then
    sata_port="${BASH_REMATCH[1]}"
    position="${BASH_REMATCH[2]}"
  else
    dialog --msgbox "Failed to extract device position from DEVPATH for $device." 7 70
    return 1
  fi

  # 7) Validate according to OS edition and controller type

  # Windows NT 3.1 Vanilla:
  # IDE disk must be primary master (channel=0, position=0)
  # SATA (IDE) disk must be on first SATA port (position=0)
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.1 ]] && [[ "$edition_desc" =~ Vanilla ]]; then
    if [[ "$controller" == "IDE" ]]; then
      if (( channel != 0 || position != 0 )); then
        dialog --msgbox "For $edition_desc with IDE disk, the device must be Primary Master (channel 0, device 0)." 8 70
        return 1
      fi
    elif [[ "$controller" == "SATA (IDE)" ]]; then
      if (( sata_port != 0 )); then
        dialog --msgbox "For $edition_desc with SATA (IDE) disk, the device must be on the first SATA port (port 0)." 8 80
        return 1
      fi
    else
      dialog --msgbox "Only IDE or SATA (IDE) disks are supported for $edition_desc." 7 60
      return 1
    fi
  fi

  # Windows NT 3.50 or 3.51 Vanilla:
  # IDE disk must be primary or secondary master (channel=0 or 1, position=0)
  # SATA (IDE) disks have no restriction here
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.(50|51) ]] && [[ "$edition_desc" =~ Vanilla ]]; then
    if [[ "$controller" == "IDE" ]]; then
      if ! { (( channel == 0 || channel == 1 )) && (( position == 0 )); }; then
        dialog --msgbox "For $edition_desc with IDE disk, the device must be Primary or Secondary Master (channel 0 or 1, device 0)." 8 75
        return 1
      fi
    fi
  fi

  # All checks passed
  return 0
}

parse_boot_part_num() {
  local disk="$1"
  local valid_ids="01 04 06 07 0b 0c 0e 11 14 16 17 1b 1c 1e"
  local active_partnum=""
  local id

  # Try to find a partition with the 'boot' flag
  active_partnum=$(sudo parted -sm "$disk" print | awk -F: '{ if ($0 ~ /boot/) print $1 }' | head -n1)

  if [[ -n "$active_partnum" ]]; then
    local partname parttype fstype

    # Construct the full partition path
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ || "$disk" =~ mmcblk[0-9]+$ ]]; then
      partname="${disk}p${active_partnum}"
    else
      partname="${disk}${active_partnum}"
    fi

    # Get the partition type and filesystem type
    parttype=$(lsblk -no PARTTYPE "$partname" 2>/dev/null)
    fstype=$(lsblk -no FSTYPE "$partname" 2>/dev/null)
	partsize=$(lsblk -nb -no SIZE "$partname" 2>/dev/null)
	
	# Check partitions with vaild partition id and size at least 4 MB
	if [[ "$parttype" =~ ^0x ]] && [[ "$partsize" -ge 4194304 ]]; then
      id="${parttype#0x}"
      id="${id,,}"
      [[ ${#id} -eq 1 ]] && id="0$id"

      # If ID is 07 or 17, filesystem must be NTFS
      if [[ "$id" == "07" || "$id" == "17" ]]; then
        # if [[ "$fstype" != "ntfs" && "$fstype" != "exfat" ]]; then // NTLDR cannot recognize exFAT partitions
        if [[ "$fstype" != "ntfs" ]]; then
          # Invalid filesystem for this ID
          active_partnum=""
        fi
      fi

      if [[ -n "$active_partnum" && "$valid_ids" =~ $id ]]; then
        echo "$active_partnum"
        return 0
      fi
    fi
  fi

  # Fallback: loop through all primary partitions and check validity
  readarray -t lines < <(lsblk -lnpo NAME,FSTYPE,PARTTYPE "$disk")
  for line in "${lines[@]}"; do
    read -r part fstype parttype <<< "$line"

    partnum=$(echo "$part" | grep -o '[0-9]\+$')
    [[ -z "$partnum" || -z "$fstype" || ! "$parttype" =~ ^0x ]] && continue	
	
    # Check partition size (minimum 4 MB)
    partsize=$(lsblk -nb -no SIZE "$part" 2>/dev/null)
    [[ "$partsize" -lt 4194304 ]] && continue  # Skip partitions smaller than 4 MB

    id="${parttype#0x}"
    id="${id,,}"
    [[ ${#id} -eq 1 ]] && id="0$id"

    # If ID is 07 or 17, filesystem must be NTFS
    if [[ "$id" == "07" || "$id" == "17" ]]; then
      if [[ "$fstype" != "ntfs" ]]; then
        continue
      fi
    fi

    if grep -qw "$id" <<< "$valid_ids"; then
      echo "$partnum"
      return 0
    fi
  done

  echo -1
  return 1
}

is_partition_hidden() {
  local disk="$1"       # Example: /dev/sda or /dev/nvme0n1
  local part_num="$2"   # Example: 1, 2, 3, 4

  # Build partition device name (nvme disks have 'p' before partition number)
  local part_dev=""
  if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ || "$disk" =~ mmcblk[0-9]+$ ]]; then
    part_dev="${disk}p${part_num}"
  else
    part_dev="${disk}${part_num}"
  fi

  # Get partition flags with parted
  local flags
  flags=$(sudo parted -sm "$disk" print | awk -F: -v p="$part_num" '$1 == p {print $7}')

  # Check if 'hidden' flag exists in flags string
  if [[ "$flags" == *hidden* ]]; then
    return 0  # partition is hidden
  else
    return 1  # partition is not hidden
  fi
}

read_os_edition_names() {
  EDITION_DESC=""
  while IFS='=' read -r os_code editions; do
    if [[ "$os_code" == "$OSCODE" ]]; then
      IFS=',' read -ra ed_arr <<< "$editions"
      for ed in "${ed_arr[@]}"; do
        IFS=':' read -r ed_code ed_index ed_desc <<< "$ed"
        if [[ "$ed_index" == "$WIM_FILE_INDEX" ]]; then
          EDITION_DESC="$ed_desc"
          break 2
        fi
      done
    fi
  done < "./edition_list.cfg"
}

read_old_os_folders() {
  OLD_OS_FOLDERS=()
  if [[ -f "./old_os_folders.cfg" ]]; then
    IFS=':' read -ra OLD_OS_FOLDERS <<< "$(cat ./old_os_folders.cfg)"
  fi
}

if [[ "$SETUP_TYPE" -eq 0 ]]; then
  read_os_edition_names
fi

read_old_os_folders

scan_disks

while true; do
  DISK_SELECTED=$(dialog --clear --backtitle "Disk Selection" \
    --title "Select Target Disk" \
    --menu "Choose the target disk for installation:" 18 70 10 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
  
  dialog --infobox "Checking OS disk requirements..." 3 37
  
  if [[ "$SETUP_TYPE" -eq 0 ]]; then
    CNTRLR=$(get_disk_interface_type "$DISK_SELECTED")
    IRQ_NUM=$(get_disk_irq "$DISK_SELECTED")
    if ! controller_OS_check "$CNTRLR" "$EDITION_DESC" "$IRQ_NUM"; then
      continue
    fi
  
    if ! check_disk_position "$DISK_SELECTED" "$EDITION_DESC"; then
      continue
    fi
  fi
  
  [[ "${DISK_INFO[$DISK_SELECTED,type]}" != "MBR" ]] && {
    dialog --msgbox "Only MBR disks are supported!\n\nSelected disk type is ${DISK_INFO[$DISK_SELECTED,type]}." 8 50
    continue
  }
  
  IS_APPLETV=$(check_appletv)
  
  if [[ "$IS_APPLETV" == "No" ]]; then
    BOOT_PART_NUM=$(parse_boot_part_num "$DISK_SELECTED")
    if [[ "$BOOT_PART_NUM" == "-1" ]]; then
      dialog --msgbox "Setup was unable to find a supported primary partition for booting the NT OS.\n\nPlease create a primary partition at least 4 MB formatted with one of the supported file systems:\n\n* FAT12\n* FAT16\n* FAT32\n* NTFS\n\nThen try again." 16 60
      continue
    fi
  fi

  
  if [[ "$parts_scanned" -eq 0 ]]; then  
    scan_partitions $DISK_SELECTED
    # parts_scanned=1  // makes problem when more than one disk
  fi

  while true; do
    [[ ${#PART_MENU[@]} -eq 0 ]] && { dialog --msgbox "No partitions found on $DISK_SELECTED." 7 50; break; }

    PART_SELECTED_INDEX=$(dialog --clear --backtitle "Partition Selection" \
      --title "Select Installation Partition" \
      --menu "Choose the partition for installation:" 20 80 10 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$PART_SELECTED_INDEX" ]] && break
    
    dialog --infobox "Checking OS and platform partition requirements..." 3 42

    OS_PART_NAME="$PART_SELECTED_INDEX"

    OS_PART_NUM=$(echo "$OS_PART_NAME" | grep -oE '[0-9]+$')
    PART_FS="${PART_FS_MAP[$OS_PART_NAME]}"
    PART_LABEL="${PART_LABEL_MAP[$OS_PART_NAME]}"
    PART_SIZE="${PART_SIZE_MAP[$OS_PART_NAME]}"
    PART_FREE_KB="${PART_FREE_KB_MAP[$OS_PART_NAME]}"
    HAS_OLD_OS="${HAS_OLD_OS_MAP[$OS_PART_NAME]}"
    
    CNTRLR=$(get_disk_interface_type "$DISK_SELECTED")
    
    active_flag=" "
    fdisk -l "$DISK_SELECTED" | grep "^$OS_PART_NAME" | awk '{ if ($2 == "*") print "*" }' | grep -q '*'
    if [[ $? -eq 0 ]]; then
      active_flag="A"
    fi
    
    hidden_flag=" "
    if is_partition_hidden "$DISK_SELECTED" $OS_PART_NUM; then
      hidden_flag="H"
    fi
    
    part_number=$(echo "$OS_PART_NAME" | grep -oE '[0-9]+$')
    part_type_id=$(lsblk -no PARTTYPE "$OS_PART_NAME")
    
    is_logical=0
    if [[ "$part_number" -ge 5 ]]; then
      is_logical=1
    fi
    
    part_type=$([[ $is_logical -eq 1 ]] && echo "LOG" || echo "PRI")
    
    if [[ "$part_type_id" == "0x5" || "$part_type_id" == "0xf" || "$part_type_id" == "0x15" || "$part_type_id" == "0x1f" ]]; then
      part_type="EXT"
    fi

    disk_info_line="Disk: $DISK_SELECTED | Size: ${DISK_INFO[$DISK_SELECTED,size]} | Type: ${DISK_INFO[$DISK_SELECTED,type]} | Cntrlr: $CNTRLR"
    free_fmt=$(format_size "$PART_FREE_KB")
    part_info_line1=$(printf $"Partition: %s | %s%s %s | FS: %-9s" \
    "$OS_PART_NAME" \
    "$active_flag" \
    "$hidden_flag" \
    "$part_type" \
    "$PART_FS")
    part_info_line2=$(printf $"Size: %-9s | Free: %-9s" \
    "$PART_SIZE" \
    "$free_fmt")

    FDISK_LINE=$(fdisk -l "$DISK_SELECTED" | grep "^$OS_PART_NAME")
    
    START_LBA=$(echo "$FDISK_LINE" | awk '{print $2}')
    END_LBA=$(echo "$FDISK_LINE" | awk '{print $3}')

    if [[ "$SETUP_TYPE" -eq 0 ]]; then
	  check_partition_compatibility "$part_type" "${PART_FS_MAP[$PART_SELECTED_INDEX]}" "$DISK_SELECTED" "$START_LBA" "$END_LBA" "$EDITION_DESC" || continue
      check_free_space "${PART_FREE_KB_MAP[$PART_SELECTED_INDEX]}" "$EDITION_DESC" || continue
	
      # Primary/Logical check for NT 3.1, NT 3.50 and NT 3.51
      if [[ $is_logical -eq 1 && "$EDITION_DESC" =~ NT\ 3 ]]; then
        dialog --yesno "$EDITION_DESC might not boot from a logical partition.\n\nProceed at your own risk!\n\nIf it fails to boot, try installing it to a primary partition instead.\n\nDo you want to continue?" 15 70
        if [[ $? -ne 0 ]]; then
          continue
        fi
      fi
	elif [[ "$SETUP_TYPE" -eq 1 ]]; then
	  check_partition_compatibility_custom "$part_type" "${PART_FS_MAP[$PART_SELECTED_INDEX]}" || continue
      check_free_space_custom "${PART_FREE_KB_MAP[$PART_SELECTED_INDEX]}" || continue
	fi

    if [[ $hidden_flag == "H" ]]; then
      if ! dialog --yesno "Install partition must be unhidden in order to continue with the installation.\n\nSetup will make the install partition unhidden when it is installing OS.\n\nDo you want to continue?" 15 70; then
        continue
      fi
    fi
    
    if [[ "$IS_APPLETV" == "Yes" ]]; then
      ATVBOOT_SELECTED_INDEX=$(dialog --clear --backtitle "Bootloader Partition Selection" \
      --title "Select Apple TV Bootloader Partition" \
      --menu "Choose the partition for bootloader installation:" 20 80 10 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

      [[ $? -ne 0 || -z "$ATVBOOT_SELECTED_INDEX" ]] && break
      
      BOOT_PART_NAME="$ATVBOOT_SELECTED_INDEX"
      BOOT_PART_NUM=$(echo "$BOOT_PART_NAME" | grep -oE '[0-9]+$')
      
      FDISK_LINE=$(fdisk -l "$DISK_SELECTED" | grep "^$BOOT_PART_NAME")
    
      START_LBA=$(echo "$FDISK_LINE" | awk '{print $2}')
      END_LBA=$(echo "$FDISK_LINE" | awk '{print $3}')
      
      part_type=$([[ $is_logical -eq 1 ]] && echo "LOG" || echo "PRI")
    
      if [[ "$part_type_id" == "0x5" || "$part_type_id" == "0xf" || "$part_type_id" == "0x15" || "$part_type_id" == "0x1f" ]]; then
        part_type="EXT"
      fi
      
      # Must be a FAT32 partition (could be HFS+ too but hell nah)
      check_partition_compatibility "$part_type" "${PART_FS_MAP[$ATVBOOT_SELECTED_INDEX]}" "$DISK_SELECTED" "$START_LBA" "$END_LBA" "Apple TV Bootloader" || continue
      check_free_space "${PART_FREE_KB_MAP[$ATVBOOT_SELECTED_INDEX]}" "Apple TV Bootloader" || continue
      
      
    fi

    if [[ "${HAS_OLD_OS_MAP[$OS_PART_NAME]:-0}" -eq 1 ]]; then
      dialog --yesno "Old Windows OS files detected on the selected partition.\n\nThey will be moved to Windows.old.\n\nContinue?" 9 60
      if [[ $? -ne 0 ]]; then
        continue
      fi
    fi

    CONFIRM_MSG=""
    if [[ "$SETUP_TYPE" -eq 0 ]]; then
      CONFIRM_MSG="OS Edition: $EDITION_DESC\n\n$disk_info_line\n\n$part_info_line1\n$part_info_line2\n\n\nProceed with installation?"
    else
	  CONFIRM_MSG="Custom Installation: $WIM_FILE -> $WIM_IMAGE_INFO\n\n$disk_info_line\n\n$part_info_line1\n$part_info_line2\n\n\nProceed with installation?"
	fi
	
	dialog --yesno "$CONFIRM_MSG" 14 80 || continue

    bash ./scripts/startins.sh "$OS_PART_NAME" "$WIM_FILE" "$WIM_FILE_INDEX" "$OS_PART_NUM" "$BOOT_PART_NUM" "$OSCODE" "$EDITION_DESC" "$SETUP_TYPE" "$WIM_IMAGE_INFO"
    
    STARTINST_EXIT=$?
    
    if [[ $STARTINST_EXIT -eq 5 ]]; then
      exit 5
    fi
    
    exit 0
  done
done
