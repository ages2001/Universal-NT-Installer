#!/bin/bash

# ==============================================================================
# startins.sh - Universal Windows Installation Engine
# ==============================================================================

# --- TUI Progress Initializer ---
sudo dialog --infobox "Installer is in progress..." 3 35

# --- Command Line Arguments ---
OS_PART_NAME="$1"
WIM_FILE="$2"
WIM_FILE_INDEX="$3"
OS_PART_NUM="$4"
BOOT_PART_NUM="$5"
OS_CODE="$6"
EDITION_DESC="$7"
SETUP_TYPE="$8"
WIM_IMAGE_INFO="$9"

if [[ -z "$SETUP_TYPE" ]]; then
  sudo dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

if [[ "$SETUP_TYPE" -eq 1 ]]; then
  OS_CODE="x"
  EDITION_DESC="x"
fi

if [[ -z "$OS_PART_NAME" || -z "$WIM_FILE" || -z "$WIM_FILE_INDEX" || -z "$OS_PART_NUM" || -z "$BOOT_PART_NUM" || -z "$OS_CODE" || -z "$EDITION_DESC" || -z "$SETUP_TYPE" || -z "$WIM_IMAGE_INFO" ]]; then
  sudo dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

# --- Global Paths & Shell Options ---
MOUNT_POINT="/mnt/install_part"
TEMP_BOOT="/mnt/boot_part"
WIM_FILE_PATH=""

source "./scripts/sysinfo.sh"

if [[ "$SETUP_TYPE" -eq 0 ]]; then
  WIM_FILE_PATH="/mnt/uwifiles/osfiles/$WIM_FILE"
elif [[ "$SETUP_TYPE" -eq 1 ]]; then
  WIM_FILE_PATH="/mnt/uwifiles/osfiles/custom/$WIM_FILE"
fi

DISK_DEVICE=$(sudo lsblk -no PKNAME "$OS_PART_NAME")
DISK="/dev/$DISK_DEVICE"
DISK_BASENAME=$(sudo basename "$DISK_DEVICE")

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

make_partition_path() {
  local disk="$1"
  local partnum="$2"
  if [[ "$disk" =~ ^/dev/nvme[0-9]+n[0-9]+$ || "$disk" =~ mmcblk[0-9]+$ ]]; then
    echo "${disk}p${partnum}"
  else
    echo "${disk}${partnum}"
  fi
}

unhide_partition() {
  local disk="$1"
  local partnum="$2"
  local flag=$(sudo parted -sm "$disk" print | awk -F: -v p="$partnum" '$1 == p {print $7}')
  if [[ $flag == *hidden* ]]; then
    sudo parted "$disk" set "$partnum" hidden off >/dev/null 2>&1
  fi
}

get_fs_type() {
  local part="$1"
  local fstype=$(sudo lsblk -no FSTYPE "$part" 2>/dev/null | xargs | tr '[:upper:]' '[:lower:]')
  
  if [[ "$fstype" == "vfat" || "$fstype" == "fat" ]]; then
    local file_raw=$(sudo file -s "$part" 2>/dev/null)
    if echo "$file_raw" | grep -q -i "FAT (32 bit)"; then fstype="fat32"
    elif echo "$file_raw" | grep -q -i "FAT (16 bit)"; then fstype="fat16"
    elif echo "$file_raw" | grep -q -i "FAT (12 bit)"; then fstype="fat12"
    fi
  fi
  echo "$fstype"
}

check_mount_partition() {
  local part="$1"
  local mountpoint="$2"
  local fs=$(get_fs_type "$part")

  sudo mkdir -p "$mountpoint"
  sudo umount "$mountpoint" 2>/dev/null

  case "$fs" in
    ntfs)
      sudo ntfsfix -b -d "$part" >/dev/null 2>&1
      ;;
    vfat|fat12|fat16|fat32)
      sudo fsck.fat -a "$part" >/dev/null 2>&1
      ;;
    exfat)
      sudo fsck.exfat -a "$part" >/dev/null 2>&1
      ;;
    ext2|ext3|ext4)
      sudo e2fsck -p "$part" >/dev/null 2>&1
      ;;
    btrfs)
      sudo btrfs check "$part" >/dev/null 2>&1
      ;;
    reiserfs)
      sudo reiserfsck --check "$part" >/dev/null 2>&1
      ;;
  esac

  if [[ "$fs" == "ntfs" ]]; then
    sudo mount -t ntfs3 -o force "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo ntfs-3g "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo mount -t ntfs -o rw "$part" "$mountpoint" >/dev/null 2>&1
  else
    sudo mount -o rw "$part" "$mountpoint" >/dev/null 2>&1
  fi
}

get_disk_number() {
  if [[ "$DISK_BASENAME" =~ ^sd([a-z])$ ]]; then
    local letter=${BASH_REMATCH[1]}
    echo $(( $(printf '%d' "'$letter") - 97 ))
  elif [[ "$DISK_BASENAME" =~ ^nvme([0-9]+)n[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$DISK_BASENAME" =~ ^mmcblk([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 0
  fi
}

get_bootini_number() {
  local selected_part="$1"
  local real_part_num=$(echo "$selected_part" | grep -o '[0-9]\+$')
  
  if [[ -z "$real_part_num" ]]; then
    echo 1
    return
  fi

  if (( real_part_num >= 5 )); then
    echo $(( real_part_num - 1 ))
  else
    echo "$real_part_num"
  fi
}

unmount_all() {
  sudo dialog --infobox "Unmounting installed partitions..." 3 40
  sudo sync
  [[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount -l "$TEMP_BOOT" 2>/dev/null
  sudo umount -l "$MOUNT_POINT" 2>/dev/null
}

# ==============================================================================
# MODULAR OS BACKUP & DRIVER PATCH FUNCTIONS
# ==============================================================================

# --- 1. Backup Old OS Directories to Windows.old ---
backup_old_windows_folders() {
  local old_os_cfg="/mnt/uwifiles/configs/old_os_folders.cfg"
  [[ ! -f "$old_os_cfg" ]] && return 0

  IFS=':' read -ra OLD_FOLDERS < "$old_os_cfg"
  local has_valid_folder=false
  for folder in "${OLD_FOLDERS[@]}"; do
    match=$(sudo find "$MOUNT_POINT" -maxdepth 1 -type d -iname "$folder" | head -n1)
    if [[ -n "$match" ]]; then
      has_valid_folder=true
      break
    fi
  done

  if $has_valid_folder; then
    sudo dialog --infobox "Backing up old OS folders to Windows.old..." 3 52
    local windows_old_dir=$(sudo find "$MOUNT_POINT" -maxdepth 1 -type d -iname "Windows.old" | head -n1)

    if [[ -n "$windows_old_dir" ]]; then
      local i=1
      local suffix
      while true; do
        if (( i <= 999 )); then
          suffix=$(printf "%03d" "$i")
        else
          suffix="$i"
        fi
        local new_dir="$MOUNT_POINT/Windows.$suffix"
        if [[ ! -d "$new_dir" ]]; then
          sudo mv "$windows_old_dir" "$new_dir"
          break
        fi
        ((i++))
      done
    fi

    sudo mkdir -p "$MOUNT_POINT/Windows.old"
    for folder in "${OLD_FOLDERS[@]}"; do
      local src=$(sudo find "$MOUNT_POINT" -maxdepth 1 -type d -iname "$folder" | head -n1)
      if [[ -n "$src" ]]; then
        local dest="$MOUNT_POINT/Windows.old/$(sudo basename "$src")"
        sudo mkdir -p "$(sudo dirname "$dest")"
        sudo mv "$src" "$dest"
      fi
    done
  fi
}

# --- Apply Patched acpi.sys Driver ---
apply_patched_acpi_driver() {
  local base_acpi_dir="/mnt/uwifiles/drivers/patched/ACPI"
  local acpi_folder=""

  if [[ "$EDITION_DESC" =~ 2000 && "$EDITION_DESC" =~ Patched && "$EDITION_DESC" =~ ACPI\+APIC ]]; then
    acpi_folder="2KAPIC"
  elif [[ "$EDITION_DESC" =~ 2000 && "$EDITION_DESC" =~ Patched ]]; then
    acpi_folder="2000"
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 86 && "$EDITION_DESC" =~ Patched && ! "$EDITION_DESC" =~ 486 && "$EDITION_DESC" =~ NT\ 5.2 ]]; then
    acpi_folder="XP86NT52"
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 86 && "$EDITION_DESC" =~ Patched && ! "$EDITION_DESC" =~ 486 ]]; then
    acpi_folder="XP86"
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 64 && "$EDITION_DESC" =~ Patched ]]; then
    acpi_folder="XP64"
  elif [[ "$OS_CODE" =~ VISTA86 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="VISTA86"
  elif [[ "$OS_CODE" =~ VISTA64 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="VISTA64"
  elif [[ "$OS_CODE" =~ WIN7_86 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="WIN7_86"
  elif [[ "$OS_CODE" =~ WIN7_64 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="WIN7_64"
  elif [[ "$OS_CODE" =~ WIN80_86 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="WIN80_86"
  elif [[ "$OS_CODE" =~ WIN80_64 && "$EDITION_DESC" =~ Patched ]]; then acpi_folder="WIN80_64"
  fi

  if [[ -n "$acpi_folder" ]]; then
    sudo dialog --infobox "Applying patched ACPI driver..." 3 36
    local acpi_src=$(sudo find "$base_acpi_dir/$acpi_folder" -type f -iname "acpi.sys" 2>/dev/null | head -n1)
    if [[ -n "$acpi_src" && -f "$acpi_src" ]]; then
      local drivers_dir=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type d -ipath "*/system32/drivers" 2>/dev/null | head -n1)
      if [[ -n "$drivers_dir" ]]; then
        local acpi_file=$(sudo find "$drivers_dir" -maxdepth 1 -type f -iname "acpi.sys" 2>/dev/null | head -n1)
        [[ -n "$acpi_file" ]] && sudo mv "$acpi_file" "$drivers_dir/acpi.rsc" 2>/dev/null
        sudo cp -f "$acpi_src" "$drivers_dir/"
      fi

      # Copy acpi.sys directly to OS Partition root for Windows NT6+
      if [[ "$OS_CODE" =~ VISTA || "$OS_CODE" =~ WIN7 || "$OS_CODE" =~ WIN8 || "$OS_CODE" =~ WIN10 || "$OS_CODE" =~ WIN11 ]]; then
        sudo cp -f "$acpi_src" "$MOUNT_POINT/acpi.sys" 2>/dev/null
      fi

      # --- Copy acpi.sys to folder where driver cabinet files exist for Win 2000 / XP Patched (non-486) ---
      if [[ ("$EDITION_DESC" =~ 2000 || "$EDITION_DESC" =~ XP) && "$EDITION_DESC" =~ Patched && ! "$EDITION_DESC" =~ 486 ]]; then
        sudo find "$MOUNT_POINT/$SYS_DIR" -type d -ipath "*/Driver Cache/i386" -exec sudo cp -f "$acpi_src" {}/ \; 2>/dev/null
      fi
    fi
  fi
}

# --- Apply Patched uniata.sys Driver ---
apply_patched_uniata_driver() {
  local base_uniata_dir="/mnt/uwifiles/drivers/patched/UNIATA"
  local uniata_folder=""

  if [[ "$EDITION_DESC" =~ NT\ 3.51 && "$EDITION_DESC" =~ Patched ]]; then
    uniata_folder="NT351"
  elif [[ "$EDITION_DESC" =~ NT\ 4 && "$EDITION_DESC" =~ Patched ]]; then
    uniata_folder="NT4"
# elif [[ "$EDITION_DESC" =~ 2000 && "$EDITION_DESC" =~ Patched && ! "$EDITION_DESC" =~ ACPI\+APIC ]]; then
#   uniata_folder="2000"
  fi

  if [[ -n "$uniata_folder" ]]; then
    sudo dialog --infobox "Applying patched UniATA driver..." 3 42
    local uniata_src=$(sudo find "$base_uniata_dir/$uniata_folder" -type f -iname "uniata.sys" 2>/dev/null | head -n1)
    if [[ -n "$uniata_src" && -f "$uniata_src" ]]; then
      local drivers_dir=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type d -ipath "*/system32/drivers" 2>/dev/null | head -n1)
      if [[ -n "$drivers_dir" ]]; then
        local uniata_file=$(sudo find "$drivers_dir" -maxdepth 1 -type f -iname "uniata.sys" 2>/dev/null | head -n1)
        [[ -n "$uniata_file" ]] && sudo mv "$uniata_file" "$drivers_dir/uniata.rsc" 2>/dev/null
        sudo cp -f "$uniata_src" "$drivers_dir/"
      fi
    fi
  fi
}

# --- Apply nvme2k Driver ---
apply_nvme2k_driver() {
  local base_nvme2k_dir="/mnt/uwifiles/drivers/patched/NVME2K"
  local nvme2k_folder=""
  local nvme2k_sys_name="nvme"

  if [[ "$EDITION_DESC" =~ NT\ 3.50 && "$EDITION_DESC" =~ Patched ]]; then
    nvme2k_folder="NT350"
  elif [[ "$EDITION_DESC" =~ NT\ 3.51 && "$EDITION_DESC" =~ Patched ]]; then
    nvme2k_folder="NT351"
  elif [[ "$EDITION_DESC" =~ NT\ 4 && "$EDITION_DESC" =~ Patched ]]; then
    nvme2k_folder="NT4"
  elif [[ "$EDITION_DESC" =~ 2000 && "$EDITION_DESC" =~ Patched && ! "$EDITION_DESC" =~ ACPI\+APIC ]]; then
    nvme2k_folder="2000"
    nvme2k_sys_name="nvme2k"
  fi

  if [[ -n "$nvme2k_folder" ]]; then
    sudo dialog --infobox "Applying nvme2k driver..." 3 35
    local nvme2k_src=$(sudo find "$base_nvme2k_dir/$nvme2k_folder" -type f -iname "$nvme2k_sys_name.sys" 2>/dev/null | head -n1)
    if [[ -n "$nvme2k_src" && -f "$nvme2k_src" ]]; then
      local drivers_dir=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type d -ipath "*/system32/drivers" 2>/dev/null | head -n1)
      if [[ -n "$drivers_dir" ]]; then
        local nvme2k_file=$(sudo find "$drivers_dir" -maxdepth 1 -type f -iname "$nvme2k_sys_name.sys" 2>/dev/null | head -n1)
        [[ -n "$nvme2k_file" ]] && sudo mv -f "$nvme2k_file" "$drivers_dir/$nvme2k_sys_name.rsc" 2>/dev/null
        sudo cp -f "$nvme2k_src" "$drivers_dir/$nvme2k_sys_name.sys"
      fi
    fi
  fi
}

# ==============================================================================
# BOOT INI, FREELDR & BCD PARSER ENGINE FUNCTIONS
# ==============================================================================

update_existing_bootini() {
  local bootini_path="$1"
  local ini_src="$2"
  local disk_num=$(get_disk_number)
  local part_num=$(get_bootini_number "$OS_PART_NAME")

  # 1. Copy template and modify parameters if target file does not exist
  if [[ ! -f "$bootini_path" ]]; then
    sudo cp -f "$ini_src" "$bootini_path"
    sudo dos2unix "$bootini_path" 2>/dev/null
    sudo sed -i -E "s/partition\([0-9]+\)/partition($part_num)/g" "$bootini_path"
    sudo sed -i -E "s/\"([^\"]+)\"/\"\1 (disk $disk_num part $part_num)\"/" "$bootini_path"
    sudo unix2dos "$bootini_path" 2>/dev/null
    return 0
  fi

  sudo dos2unix "$bootini_path" 2>/dev/null

  local new_paths=()
  while IFS= read -r line; do
    new_paths+=("$line")
  done < <(sudo grep -Ei '^(multi|scsi)\([0-9]+\)' "$ini_src")

  [[ ${#new_paths[@]} -eq 0 ]] && return 1

  local modified_lines=()
  for newline in "${new_paths[@]}"; do
    # Strip existing disk/part metadata from string before appending updated info
    local clean_line=$(echo "$newline" | sed -E 's/ *\(disk [0-9]+ part [0-9]+\)//g')
    local mod_line=$(echo "$clean_line" | sed -E "s/partition\([0-9]+\)/partition($part_num)/" | \
      sed -E "s/\"([^\"]+)\"/\"\1 (disk $disk_num part $part_num)\"/")

    if [[ "$SETUP_TYPE" -eq 1 ]]; then
      # Update target system directory right after the partition index safely
      mod_line=$(echo "$mod_line" | sed -E "s#(partition\([0-9]+\)\\[^\"]*=)#\1\\\\$SYS_DIR=#i")
    fi
    modified_lines+=("$mod_line")
  done

  local tmp_file=$(mktemp)
  local inside_os=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}

    if [[ "${line,,}" == "[operating systems]" ]]; then
      inside_os=1
      echo "$line" | sudo tee -a "$tmp_file" >/dev/null
      # Prepend NEW modified lines right at the top of [operating systems]
      for mod in "${modified_lines[@]}"; do
        echo "$mod" | sudo tee -a "$tmp_file" >/dev/null
      done
      continue
    fi

    # If we encounter another section header, exit [operating systems] scope
    if [[ $inside_os -eq 1 && "$line" =~ ^\[.*\]$ ]]; then
      inside_os=0
    fi

    echo "$line" | sudo tee -a "$tmp_file" >/dev/null
  done < "$bootini_path"

  # 2. Strict Full-Line Deduplication Engine: Keep topmost entries, purge identical lines
  local clean_tmp=$(mktemp)
  sudo awk '
    BEGIN { inside=0; blank_count=0; IGNORECASE=1 }

    /^\[operating systems\]/ { print; inside=1; blank_count=0; next }
    
    inside && /=/ {
      # Normalize full line (lowercase and strip spaces) for accurate line matching
      line_key = tolower($0)
      gsub(/[ \t]/, "", line_key)
      if (seen_line[line_key]++) { next }
      print
      blank_count=0
      next
    }

    /^\[/ { 
      inside=0; 
      print; 
      blank_count=0; 
      next 
    }

    /^[[:space:]]*$/ {
      if (++blank_count > 1) next
      print ""
      next
    }

    { blank_count=0; print }
  ' "$tmp_file" | sudo tee "$clean_tmp" >/dev/null

  sudo cp -f "$clean_tmp" "$bootini_path"
  sudo rm -f "$tmp_file" "$clean_tmp"
  
  # Automatically repair default= entry to point to topmost valid ARC path
  fix_bootini_default "$bootini_path"
  sudo unix2dos "$bootini_path" 2>/dev/null
}

update_existing_freeldr() {
  local freeldr_path="$1"
  local ini_src="$2"
  local part_num=$(get_bootini_number "$OS_PART_NAME")

  # 1. Copy template and modify partition if target file does not exist
  if [[ ! -f "$freeldr_path" ]]; then
    sudo cp -f "$ini_src" "$freeldr_path"
    sudo dos2unix "$freeldr_path" 2>/dev/null
    sudo sed -i -E "s/partition\([0-9]+\)/partition($part_num)/g" "$freeldr_path"
    sudo unix2dos "$freeldr_path" 2>/dev/null
    return 0
  fi

  sudo dos2unix "$freeldr_path" 2>/dev/null
  sudo dos2unix "$ini_src" 2>/dev/null

  local new_titles=()
  local new_blocks=()
  local src_sections=$(sudo grep -Ei '^\[.*\]$' "$ini_src" | grep -vEi '\[(Operating Systems|FreeLoader)\]')

  # Helper: Extract clean normalized block content from target file
  get_block_body() {
    local sec_name="$1"
    local file_path="$2"
    sudo awk -v sec="[$sec_name]" '
      BEGIN { IGNORECASE=1; found=0 }
      tolower($0) == tolower(sec) { found=1; next }
      /^\[/ && found { found=0 }
      found && !/^[[:space:]]*$/ { 
        line = tolower($0)
        gsub(/[ \t]/, "", line)
        print line 
      }
    ' "$file_path"
  }

  # Helper: Generate unique section name ONLY if contents are DIFFERENT
  get_target_sec_name() {
    local orig_name="$1"
    local new_content="$2"
    local target_file="$3"
    local candidate="$orig_name"
    local counter=1

    # FIXED: Replaced non-existent 'tolower' command with 'tr'
    local new_norm=$(echo "$new_content" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r')

    # First check: Does original section name match identical content?
    if sudo grep -Ei "^\[${orig_name}\]$" "$target_file" >/dev/null 2>&1; then
      local existing_norm=$(get_block_body "$orig_name" "$target_file" | tr -d '\r')
      if [[ "$new_norm" == "$existing_norm" ]]; then
        echo "$orig_name"
        return 0
      fi
    fi

    # Content differs from exact base section name! Find next available unique name
    while sudo grep -Ei "^\[${candidate}\]$" "$target_file" >/dev/null 2>&1; do
      candidate="${orig_name}_${counter}"
      ((counter++))
    done

    echo "$candidate"
  }

  # 2. Extract section headers, titles, and block contents safely with auto-renaming
  if [[ -n "$src_sections" ]]; then
    while read -r section_hdr || [[ -n "$section_hdr" ]]; do
      local orig_sec_name=$(echo "$section_hdr" | tr -d '[]\r')

      # Extract block body first to compare content
      local raw_block_body=$(sudo awk -v sec="[$orig_sec_name]" '
        BEGIN { IGNORECASE=1; found=0 }
        tolower($0) == tolower(sec) { found=1; next }
        /^\[/ && found { found=0 }
        found { print $0 }
      ' "$ini_src" | sudo sed -E "s/partition\([0-9]+\)/partition($part_num)/g")

      # Resolve section name (reuses name if identical, renames to _1, _2 if content differs)
      local sec_name=$(get_target_sec_name "$orig_sec_name" "$raw_block_body" "$freeldr_path")

      # Extract title line from source
      local os_title_line=$(sudo grep -Ei "^[[:space:]]*$orig_sec_name[[:space:]]*=" "$ini_src" | head -n1)
      if [[ -n "$os_title_line" ]]; then
        local title_val="${os_title_line#*=}"
        new_titles+=("${sec_name}=${title_val}")
      fi

      if [[ -n "$raw_block_body" ]]; then
        local full_block=$(echo -e "[$sec_name]\n$raw_block_body")
        new_blocks+=("$full_block")
      fi
    done <<< "$src_sections"
  fi

  # 3. Merge: Place NEW titles inside [Operating Systems] and NEW blocks immediately after
  local tmp_file=$(mktemp)
  local inside_os=0
  local blocks_inserted=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}

    if [[ "${line,,}" == "[operating systems]" ]]; then
      inside_os=1
      echo "$line" | sudo tee -a "$tmp_file" >/dev/null
      for title in "${new_titles[@]}"; do
        echo "$title" | sudo tee -a "$tmp_file" >/dev/null
      done
      continue
    fi

    if [[ $inside_os -eq 1 && "$line" =~ ^\[.*\]$ ]]; then
      inside_os=0
      for blk in "${new_blocks[@]}"; do
        echo "" | sudo tee -a "$tmp_file" >/dev/null
        echo "$blk" | sudo tee -a "$tmp_file" >/dev/null
      done
      blocks_inserted=1
    fi

    echo "$line" | sudo tee -a "$tmp_file" >/dev/null
  done < "$freeldr_path"

  # Fallback: Handle edge-case where [Operating Systems] is at the absolute EOF
  if [[ $blocks_inserted -eq 0 && ${#new_blocks[@]} -gt 0 ]]; then
    for blk in "${new_blocks[@]}"; do
      echo "" | sudo tee -a "$tmp_file" >/dev/null
      echo "$blk" | sudo tee -a "$tmp_file" >/dev/null
    done
  fi

  # 4. Strict Deduplication Engine: Purge duplicate sections (keeps topmost) & clean blank lines
  local clean_tmp=$(mktemp)
  sudo awk '
    BEGIN { in_os=0; skip=0; blank_count=0; IGNORECASE=1 }

    /^\[Operating Systems\]/ { print; in_os=1; blank_count=0; next }
    in_os && /=/ {
      split($0, a, "=")
      key = tolower(a[1])
      gsub(/[ \t]/, "", key)
      if (seen_os[key]++) { next }
      print
      blank_count=0
      next
    }

    /^\[/ {
      in_os=0
      sec = tolower($0)
      gsub(/[ \t]/, "", sec)
      
      if (sec == "[freeloader]" || sec == "[operatingsystems]") {
        skip=0
        print
        blank_count=0
        next
      }

      if (seen_sec[sec]++) {
        skip=1
      } else {
        skip=0
        print
        blank_count=0
      }
      next
    }

    skip { next }

    /^[[:space:]]*$/ {
      if (++blank_count > 1) next
      print ""
      next
    }

    { blank_count=0; print }
  ' "$tmp_file" | sudo tee "$clean_tmp" >/dev/null

  sudo cp -f "$clean_tmp" "$freeldr_path"
  sudo rm -f "$tmp_file" "$clean_tmp"
  
  # 5. Fix DefaultOS pointer to topmost entry & re-encode CRLF format
  fix_freeldr_default "$freeldr_path"
  sudo unix2dos "$freeldr_path" 2>/dev/null
}

update_bootmgr_bcd() {
  local target_bcd="$1"
  local bcd_src="$2"

  if [[ -z "$bcd_src" || ! -f "$bcd_src" ]]; then
    return 1
  fi

  sudo mkdir -p /tmp

  # --- 1. Master Disk Device & Partition Resolution ---
  local real_part_dev
  real_part_dev=$(realpath "$OS_PART_NAME" 2>/dev/null || readlink -f "$OS_PART_NAME" 2>/dev/null)
  [[ -z "$real_part_dev" ]] && real_part_dev="$OS_PART_NAME"

  local parent_disk_name
  parent_disk_name=$(sudo lsblk -no PKNAME "$real_part_dev" 2>/dev/null | head -n1 | xargs)
  
  local target_disk_dev="/dev/$parent_disk_name"
  [[ ! -b "$target_disk_dev" ]] && target_disk_dev="$DISK"

  # --- 2. Extract NEW Disk Signature (4-Byte Hex) ---
  local new_sig_hex
  new_sig_hex=$(sudo dd if="$target_disk_dev" bs=1 skip=440 count=4 2>/dev/null | hexdump -v -e '/1 "%02x "' | xargs)
  
  if [[ "$new_sig_hex" == "00 00 00 00" || -z "$new_sig_hex" ]]; then
    printf '\x12\x34\x56\x78' | sudo dd of="$target_disk_dev" bs=1 seek=440 count=4 conv=notrunc >/dev/null 2>&1
    new_sig_hex="12 34 56 78"
  fi

  # --- 3. Calculate NEW Partition Start Offset (8-Byte Hex) ---
  local start_sector
  start_sector=$(sudo lsblk -bno START "$real_part_dev" 2>/dev/null | head -n1 | xargs)

  local sector_size
  sector_size=$(sudo lsblk -bno PHY-SEC "$real_part_dev" 2>/dev/null | head -n1 | xargs)
  [[ -z "$sector_size" || "$sector_size" -le 0 ]] && sector_size=512

  if [[ -z "$start_sector" ]]; then
    local part_node
    part_node=$(basename "$real_part_dev")
    local parent_node
    parent_node=$(basename "$target_disk_dev")
    start_sector=$(sudo cat "/sys/block/$parent_node/$part_node/start" 2>/dev/null)
  fi

  local offset=$((start_sector * sector_size))
  local new_off_hex=""
  for ((i=0; i<8; i++)); do
    local byte=$(((offset >> (8*i)) & 0xFF))
    new_off_hex+=$(printf "%02x " "$byte")
  done
  new_off_hex=$(echo "$new_off_hex" | xargs)

  # --- 4. PREPARE TEMPLATE BINARY PATCH ---
  local old_off_clean="000000c010000000"
  local old_sig_clean="20de6a0e"

  local new_off_clean
  new_off_clean=$(echo "$new_off_hex" | tr -d ' ')
  local new_sig_clean
  new_sig_clean=$(echo "$new_sig_hex" | tr -d ' ')

  local patched_src="/tmp/bcd_patched_source"
  sudo cp -f "$bcd_src" "$patched_src"

  local hex_stream="/tmp/bcd_stream.hex"
  sudo hexdump -v -e '/1 "%02x"' "$patched_src" > "$hex_stream"

  sudo sed -i "s/$old_off_clean/$new_off_clean/gI" "$hex_stream"
  sudo sed -i "s/$old_sig_clean/$new_sig_clean/gI" "$hex_stream"

  if command -v xxd >/dev/null 2>&1; then
    sudo xxd -r -p "$hex_stream" "$patched_src"
  else
    sudo perl -e 'print pack "H*", <STDIN>' < "$hex_stream" > "$patched_src" 2>/dev/null || \
    sudo awk '{
      for (i=1; i<length($0); i+=2)
        printf "%c", strtonum("0x" substr($0,i,2))
    }' "$hex_stream" > "$patched_src"
  fi
  sudo rm -f "$hex_stream"

  # --- 5. DIRECT COPY DEPLOYMENT ---
  sudo mkdir -p "$(sudo dirname "$target_bcd")"
  sudo cp -f "$patched_src" "$target_bcd"
  sudo rm -f "$patched_src"
}

# ==============================================================================
# FREELDR & BOOT.INI HARDWARE FILTER & DEFAULT ENTRY REBUILDERS
# ==============================================================================

clean_freeldr_tag() {
  local ini_file="$1"
  local tag="$2"

  [[ ! -f "$ini_file" ]] && return 0
  [[ -z "$tag" ]] && return 0

  local tmp_file=$(mktemp)

  sudo awk -v tag="$tag" '
    BEGIN { in_freeloader=0; in_os=0; skip=0; IGNORECASE=1 }

    /^\[FreeLoader\]/ { 
      in_freeloader=1; in_os=0; skip=0; print; next 
    }
    
    /^\[Operating Systems\]/ { 
      in_freeloader=0; in_os=1; skip=0; print; next 
    }

    /^\[/ {
      in_freeloader=0
      in_os=0
      
      sec = $0
      gsub(/[\[\]\r]/, "", sec)
      gsub(/[ \t]/, "", sec)
      
      if (sec ~ tag && !(tag ~ /PAE/i && sec ~ /NOPAE/i)) {
        skip=1
      } else {
        skip=0
        print
      }
      next
    }

    skip { next }

    {
      if (in_freeloader && /^DefaultOS=/i) {
        print
        next
      }

      if (in_os && /=/) {
        split($0, a, "=")
        key = a[1]
        gsub(/[ \t]/, "", key)
        if (key ~ tag && !(tag ~ /PAE/i && key ~ /NOPAE/i)) {
          next
        }
      }

      if (/=/ && $0 ~ tag && !(tag ~ /PAE/i && $0 ~ /NOPAE/i)) {
        next
      }

      print
    }
  ' "$ini_file" | sudo tee "$tmp_file" >/dev/null

  sudo cp -f "$tmp_file" "$ini_file"
  sudo rm -f "$tmp_file"
}

fix_bootini_default() {
  local bootini_file="$1"
  [[ ! -f "$bootini_file" ]] && return 0

  local first_arc=$(sudo awk -F'=' '
    BEGIN { in_os=0; IGNORECASE=1 }
    /^\[operating systems\]/ { in_os=1; next }
    /^\[/ { in_os=0 }
    in_os && /=/ {
      path = $1
      gsub(/[ \t]/, "", path)
      if (length(path) > 0) {
        print path
        exit
      }
    }
  ' "$bootini_file")

  if [[ -n "$first_arc" ]]; then
    # Ensure partition index is properly followed by a backslash (\)
    if [[ "$first_arc" =~ partition\([0-9]+\)[^\\] ]]; then
      first_arc=$(echo "$first_arc" | sed -E 's/(partition\([0-9]+\))([^\\])/\1\\\2/')
    fi

    # Escape backslashes for safe sed substitution
    local safe_arc=$(echo "$first_arc" | sed 's/\\/\\\\/g')
    sudo sed -i -E "s|^(default=).*|default=$safe_arc|i" "$bootini_file"
  fi
}

fix_freeldr_default() {
  local ini_file="$1"
  [[ ! -f "$ini_file" ]] && return 0

  # Extract the very first valid key under [Operating Systems]
  local first_os=$(sudo awk '
    BEGIN { in_os=0; IGNORECASE=1 }
    /^\[Operating Systems\]/ { in_os=1; next }
    /^\[/ { in_os=0 }
    in_os && /=/ {
      split($0, a, "=")
      key = a[1]
      gsub(/[ \t\r]/, "", key)
      if (length(key) > 0) {
        print key
        exit
      }
    }
  ' "$ini_file")

  [[ -z "$first_os" ]] && return 0

  # Check if DefaultOS directive exists (with optional spaces around '=')
  if sudo grep -q -i "^[[:space:]]*DefaultOS[[:space:]]*=" "$ini_file"; then
    # Update existing DefaultOS line safely, maintaining clean syntax
    sudo sed -i -E "s|^([[:space:]]*DefaultOS[[:space:]]*=).*|DefaultOS=$first_os|i" "$ini_file"
  else
    # If DefaultOS line does not exist, insert it right under [FreeLoader]
    local tmp_file=$(mktemp)
    sudo awk -v os="$first_os" '
      BEGIN { IGNORECASE=1; inserted=0 }
      /^\[FreeLoader\]/ {
        print $0
        print "DefaultOS=" os
        inserted=1
        next
      }
      { print $0 }
      END {
        if (!inserted) {
          print "[FreeLoader]"
          print "DefaultOS=" os
        }
      }
    ' "$ini_file" | sudo tee "$tmp_file" >/dev/null

    sudo cp -f "$tmp_file" "$ini_file"
    sudo rm -f "$tmp_file"
  fi
}

# ==============================================================================
# MAIN INSTALLATION ENGINE FUNCTIONS
# ==============================================================================

detect_os_root() {
  sudo dialog --infobox "Detecting Windows System Root Directory..." 3 48
  if [[ "$SETUP_TYPE" -eq 0 ]]; then
    case "$OS_CODE" in
      NT31)   SYS_DIR="WINNT31" ;;
      NT350)  SYS_DIR="WINNT350" ;;
      NT351)  SYS_DIR="WINNT351" ;;
      NT40)   SYS_DIR="WINNT4" ;;
      2000)   SYS_DIR="WINNT" ;;
      XP86)   SYS_DIR="WINDOWS" ;;
      XP64)   SYS_DIR="WINDOWS" ;;
      *)      SYS_DIR="Windows" ;;
    esac
  else
    local match_dir
    match_dir=$(sudo find "$MOUNT_POINT" -maxdepth 2 -type d -iname "system32" 2>/dev/null | head -n1)
    if [[ -n "$match_dir" ]]; then
      SYS_DIR=$(sudo basename "$(sudo dirname "$match_dir")")
    else
      sudo dialog --msgbox "ERROR: No Windows System root folder found!\n\nInstaller aborted!" 7 47
      unmount_all
      exit 1
    fi
  fi
  SYS_DIR=$(echo "$SYS_DIR" | tr -d '/' | tr -d '\\')
}

backup_old_boot_files() {
  local old_base="$TEMP_BOOT/Boot.old"

  # Find all existing boot directory variations excluding Boot.old / Boot.XXX
  mapfile -t target_boot_dirs < <(sudo find "$TEMP_BOOT" -maxdepth 1 -type d -iname "boot" ! -iname "Boot.*" 2>/dev/null)

  # 1. Check if there are any existing boot files/dirs to back up first
  local has_files_to_backup=0

  # Check for standalone boot files at root of TEMP_BOOT
  for boot_file in "NTLDR" "BOOTMGR" "NTDETECT.COM" "freeldr.sys" "freeldr.ini" "boot.ini" "rosload.exe" "menu.lst"; do
    local found_file
    found_file=$(sudo find "$TEMP_BOOT" -maxdepth 1 -iname "$boot_file" 2>/dev/null | head -n1)
    if [[ -n "$found_file" && -f "$found_file" ]]; then
      has_files_to_backup=1
      break
    fi
  done

  # Check if any detected boot directories have content
  if [[ $has_files_to_backup -eq 0 && ${#target_boot_dirs[@]} -gt 0 ]]; then
    for b_dir in "${target_boot_dirs[@]}"; do
      if [[ -d "$b_dir" ]]; then
        local boot_dir_contents
        boot_dir_contents=$(sudo find "$b_dir" -maxdepth 1 ! -path "$b_dir" 2>/dev/null)
        if [[ -n "$boot_dir_contents" ]]; then
          has_files_to_backup=1
          break
        fi
      fi
    done
  fi

  # If NO files exist to backup, exit early without creating Boot.old
  [[ $has_files_to_backup -eq 0 ]] && return

  # --- BACKUP EXECUTION ---
  sudo dialog --infobox "Backing up old bootloader files..." 3 42

  # 2. Rotate previous Boot.old to Boot.001, Boot.002, etc. if it exists
  if [[ -d "$old_base" ]]; then
    local i=1
    local suffix
    while true; do
      if (( i <= 999 )); then
        suffix=$(printf "%03d" "$i")
      else
        suffix="$i"
      fi
      local new_dir="$TEMP_BOOT/Boot.$suffix"
      if [[ ! -d "$new_dir" ]]; then
        sudo mv "$old_base" "$new_dir"
        break
      fi
      ((i++))
    done
  fi

  sudo mkdir -p "$old_base/Boot"

  # 3. MOVE and MERGE all existing 'boot' / 'Boot' folders into Boot.old/Boot
  if [[ ${#target_boot_dirs[@]} -gt 0 ]]; then
    for b_dir in "${target_boot_dirs[@]}"; do
      if [[ -d "$b_dir" ]]; then
        sudo cp -rf "$b_dir/." "$old_base/Boot/" 2>/dev/null
        sudo rm -rf "$b_dir" 2>/dev/null
      fi
    done
  fi

  # 4. COPY root bootloader binaries and config files
  for boot_file in "NTLDR" "BOOTMGR" "NTDETECT.COM" "freeldr.sys" "freeldr.ini" "boot.ini" "rosload.exe" "menu.lst"; do
    local found_file
    found_file=$(sudo find "$TEMP_BOOT" -maxdepth 1 -iname "$boot_file" 2>/dev/null | head -n1)
    if [[ -n "$found_file" && -f "$found_file" ]]; then
      sudo cp -f "$found_file" "$old_base/" 2>/dev/null
    fi
  done
}

# Ensures clean active partition state: Keeps topmost active partition, 
# or falls back to first Primary FAT/NTFS partition if active FS is unsupported.
sanitize_active_partitions() {
  local disk="$1"
  
  # 1. Gather all currently active partition numbers
  mapfile -t active_parts < <(sudo parted -sm "$disk" print | awk -F: '$7 ~ /boot/ {print $1}')

  # If multiple partitions are marked active, keep only the FIRST one and strip others
  if (( ${#active_parts[@]} > 1 )); then
    for ((i=1; i<${#active_parts[@]}; i++)); do
      sudo parted "$disk" set "${active_parts[$i]}" boot off >/dev/null 2>&1
    done
  fi

  # Re-evaluate the remaining single active partition (if any)
  local current_active=$(sudo parted -sm "$disk" print | awk -F: '$7 ~ /boot/ {print $1}' | head -n1)
  local active_is_valid=0

  if [[ -n "$current_active" && "$current_active" -le 4 ]]; then
    local act_part_name=$(make_partition_path "$disk" "$current_active")
    local act_fs=$(get_fs_type "$act_part_name")
    if [[ "$act_fs" =~ fat || "$act_fs" == "ntfs" ]]; then
      active_is_valid=1
    fi
  fi

  # 2. Fallback: If active partition is missing or NOT (FAT12/16/32/NTFS), set the first Primary FAT/NTFS partition as active
  if [[ $active_is_valid -eq 0 ]]; then
    local fallback_num=""
    for pnum in 1 2 3 4; do
      local p_name=$(make_partition_path "$disk" "$pnum")
      if [[ -b "$p_name" ]]; then
        local p_fs=$(get_fs_type "$p_name")
        if [[ "$p_fs" =~ fat || "$p_fs" == "ntfs" ]]; then
          fallback_num="$pnum"
          break
        fi
      fi
    done

    if [[ -n "$fallback_num" ]]; then
      # Strip active flag from invalid partition
      [[ -n "$current_active" ]] && sudo parted "$disk" set "$current_active" boot off >/dev/null 2>&1
      # Set first valid Primary FAT/NTFS partition as active
      sudo parted "$disk" set "$fallback_num" boot on >/dev/null 2>&1
    fi
  fi
}

apply_boot_records() {
  local loader_type="$1"
  local chain_file="$2"
  sudo dialog --yesno "WARNING!\n\nInstaller will update Disk MBR and Partition Boot Record on $DISK.\nThis may overwrite existing boot code.\n\nNOTE: If you choose 'No', you must update MBR/PBR manually!\n\nDo you want to continue?" 13 75
  
  if [[ $? -eq 0 ]]; then
    sudo dialog --infobox "Updating MBR and Partition Boot Records..." 3 55

    # ALWAYS run sanitize engine first (enforces single active & FAT/NTFS primary fallback)
    sanitize_active_partitions "$DISK"

    local target_active_num="$BOOT_PART_NUM"

    # FREELDR or GRLDR chaining FREELDR Requirement: Must boot from Primary FAT12/16/32 (ONLY applies to Default Installations)
    if [[ "$SETUP_TYPE" -eq 0 ]] && [[ "$loader_type" == "FREELDR" || ("$loader_type" == "GRLDR" && "$chain_file" =~ freeldr) ]]; then
      local active_is_fat=0
      local current_active_num=$(sudo parted -sm "$DISK" print | awk -F: '$7 ~ /boot/ {print $1; exit}')

      if [[ -n "$current_active_num" && "$current_active_num" -le 4 ]]; then
        local active_part_name=$(make_partition_path "$DISK" "$current_active_num")
        local active_fs=$(get_fs_type "$active_part_name")
        if [[ "$active_fs" =~ fat ]]; then
          active_is_fat=1
          target_active_num="$current_active_num"
        fi
      fi

      # Active partition is NOT FAT! Find the very FIRST Primary FAT12/16/32 partition on disk
      if [[ $active_is_fat -eq 0 ]]; then
        local first_fat_num=""
        for pnum in 1 2 3 4; do
          local p_name=$(make_partition_path "$DISK" "$pnum")
          if [[ -b "$p_name" ]]; then
            local p_fs=$(get_fs_type "$p_name")
            if [[ "$p_fs" =~ fat ]]; then
              first_fat_num="$pnum"
              break
            fi
          fi
        done

        if [[ -n "$first_fat_num" ]]; then
          target_active_num="$first_fat_num"
        fi
      fi
    fi

    # Strip active flag from previous partition if different, and activate target partition
    local current_active=$(sudo parted -sm "$DISK" print | awk -F: '$7 ~ /boot/ {print $1}')
    for act_p in $current_active; do
      if [[ "$act_p" != "$target_active_num" ]]; then
        sudo parted "$DISK" set "$act_p" boot off >/dev/null 2>&1
      fi
    done

    sudo parted "$DISK" set "$target_active_num" boot on >/dev/null 2>&1

    # Update dynamic boot partition paths for PBR and files deployment
    BOOT_PART_NUM="$target_active_num"
    local BOOT_PART_NAME=$(make_partition_path "$DISK" "$BOOT_PART_NUM")
    local part_fs=$(get_fs_type "$BOOT_PART_NAME")
  
    if [[ -f "./scripts/applypbr.sh" ]]; then
      sudo ./scripts/applypbr.sh "$BOOT_PART_NAME" "$loader_type" >/dev/null 2>&1
    fi

    local mbr_flag="NT6"
    case "$loader_type" in
      BOOTMGR) mbr_flag="NT6" ;;
      NTLDR)   mbr_flag="NT5" ;;
      FREELDR) mbr_flag="FREELDR" ;;
      GRLDR)   mbr_flag="GRUB4DOS" ;;
    esac

    if [[ -f "./scripts/applymbr.sh" ]]; then
      sudo ./scripts/applymbr.sh "$DISK" "$mbr_flag" >/dev/null 2>&1
    fi

  else
    sudo dialog --msgbox "Skipped MBR/PBR update.\n\nPlease ensure your partition is active and bootloader is updated manually!" 8 60
  fi
}

deploy_setup_complete_script() {
  local src_cmd_dir="$1"

  if [[ -z "$src_cmd_dir" || ! -d "$src_cmd_dir" ]]; then
    return 0
  fi

  # Locate SetupComplete.cmd file in specified directory (case-insensitive)
  local src_cmd_file
  src_cmd_file=$(sudo find "$src_cmd_dir" -maxdepth 1 -type f -iname "SetupComplete.cmd" 2>/dev/null | head -n1)

  if [[ -z "$src_cmd_file" || ! -f "$src_cmd_file" ]]; then
    return 0
  fi

  sudo dialog --infobox "Deploying OOBE script(s) and BCD backup..." 3 48

  # Resolve Windows\Setup\Scripts directory path directly without recursive disk scan
  local win_dir="$MOUNT_POINT/$SYS_DIR"
  [[ ! -d "$win_dir" ]] && win_dir=$(sudo find "$MOUNT_POINT" -maxdepth 1 -type d -iname "Windows" 2>/dev/null | head -n1)
  [[ -z "$win_dir" ]] && win_dir="$MOUNT_POINT/Windows"

  local setup_dir="$win_dir/Setup"
  sudo mkdir -p "$setup_dir"

  local scripts_dir="$setup_dir/Scripts"
  sudo mkdir -p "$scripts_dir"

  # Resolve target SetupComplete.cmd file path
  local target_cmd_file="$scripts_dir/SetupComplete.cmd"

  # Process line endings and perform append or copy operation
  local tmp_src="/tmp/src_setup_complete.cmd"
  sudo cp -f "$src_cmd_file" "$tmp_src"
  sudo dos2unix "$tmp_src" 2>/dev/null

  if [[ -f "$target_cmd_file" ]]; then
    sudo dos2unix "$target_cmd_file" 2>/dev/null

    # Check if ALL non-empty lines of tmp_src exist in target_cmd_file
    local already_exists=true
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Ignore empty lines
      [[ -z "$line" ]] && continue
      if ! sudo grep -F -q -x "$line" "$target_cmd_file" 2>/dev/null; then
        already_exists=false
        break
      fi
    done < "$tmp_src"

    # Append only if missing
    if [[ "$already_exists" == false ]]; then
      echo "" | sudo tee -a "$target_cmd_file" >/dev/null
      sudo cat "$tmp_src" | sudo tee -a "$target_cmd_file" >/dev/null
    fi

    sudo unix2dos "$target_cmd_file" 2>/dev/null
  else
    sudo cp -f "$tmp_src" "$target_cmd_file"
    sudo unix2dos "$target_cmd_file" 2>/dev/null
  fi
  sudo rm -f "$tmp_src" 2>/dev/null

  # ============================================================================
  # OOBE_FINAL.CMD & UNATTEND.XML (STRICTLY FOR ./bootldr/bootmgr)
  # ============================================================================

  if [[ "$src_cmd_dir" == "./bootldr/bootmgr" ]]; then

    # --- 1. OOBE_FINAL.CMD DEPLOYMENT ENGINE ---
    local src_oobe_file
    src_oobe_file=$(sudo find "$src_cmd_dir" -maxdepth 1 -type f -iname "OOBE_Final.cmd" 2>/dev/null | head -n1)

    if [[ -n "$src_oobe_file" && -f "$src_oobe_file" ]]; then
      local target_oobe_file="$scripts_dir/OOBE_Final.cmd"
      local existing_oobe
      existing_oobe=$(sudo find "$scripts_dir" -maxdepth 1 -type f -iname "OOBE_Final.cmd" 2>/dev/null | head -n1)

      # Rotate existing OOBE_Final.cmd to .old, .001, .002 if present
      if [[ -n "$existing_oobe" && -f "$existing_oobe" ]]; then
        local old_oobe="$scripts_dir/OOBE_Final.cmd.old"
        if [[ -e "$old_oobe" ]]; then
          local o_idx=1
          local o_suffix
          while true; do
            if (( o_idx <= 999 )); then
              o_suffix=$(printf "%03d" "$o_idx")
            else
              o_suffix="$o_idx"
            fi
            local new_o_old="$scripts_dir/OOBE_Final.cmd.$o_suffix"
            if [[ ! -e "$new_o_old" ]]; then
              old_oobe="$new_o_old"
              break
            fi
            ((o_idx++))
          done
        fi
        sudo mv -f "$existing_oobe" "$old_oobe" 2>/dev/null
      fi

      # Copy new OOBE_Final.cmd and fix line endings
      sudo cp -f "$src_oobe_file" "$target_oobe_file"
      sudo dos2unix "$target_oobe_file" 2>/dev/null
      sudo unix2dos "$target_oobe_file" 2>/dev/null
    fi

    # --- 2. UNATTEND.XML DEPLOYMENT ENGINE ---
    local src_unattend
    src_unattend=$(sudo find "$src_cmd_dir" -maxdepth 1 -type f -iname "unattend.xml" 2>/dev/null | head -n1)

    if [[ -n "$src_unattend" && -f "$src_unattend" ]]; then
      # Resolve Windows\Panther directory path case-insensitively
      local panther_dir
      panther_dir=$(sudo find "$win_dir" -maxdepth 1 -type d -iname "Panther" 2>/dev/null | head -n1)

      if [[ -z "$panther_dir" ]]; then
        panther_dir="$win_dir/Panther"
        sudo mkdir -p "$panther_dir"
      fi

      local target_unattend="$panther_dir/unattend.xml"
      local existing_unattend
      existing_unattend=$(sudo find "$panther_dir" -maxdepth 1 -type f -iname "unattend.xml" 2>/dev/null | head -n1)

      # Rotate existing unattend.xml to .old, .001, .002 if present
      if [[ -n "$existing_unattend" && -f "$existing_unattend" ]]; then
        local old_unattend="$panther_dir/unattend.xml.old"
        if [[ -e "$old_unattend" ]]; then
          local idx=1
          local suffix
          while true; do
            if (( idx <= 999 )); then
              suffix=$(printf "%03d" "$idx")
            else
              suffix="$idx"
            fi
            local new_old="$panther_dir/unattend.xml.$suffix"
            if [[ ! -e "$new_old" ]]; then
              old_unattend="$new_old"
              break
            fi
            ((idx++))
          done
        fi
        sudo mv -f "$existing_unattend" "$old_unattend" 2>/dev/null
      fi

      # Copy source unattend.xml to target path
      sudo cp -f "$src_unattend" "$target_unattend"
      sudo dos2unix "$target_unattend" 2>/dev/null

      # Architecture check: Replace 'x86' with 'amd64' if 64-bit OS
      if [[ "$OS_CODE" =~ 64 || "$EDITION_DESC" =~ 64 ]]; then
        sudo sed -i -E 's/processorArchitecture="x86"/processorArchitecture="amd64"/gI' "$target_unattend"
      fi

      # Convert back to Windows CRLF line endings
      sudo unix2dos "$target_unattend" 2>/dev/null
    fi

  fi

  # Direct file lookup for BCD instead of recursive system search
  local src_bcd_file="$TEMP_BOOT/boot/bcd"
  [[ ! -f "$src_bcd_file" ]] && src_bcd_file="$TEMP_BOOT/Boot/BCD"
  [[ ! -f "$src_bcd_file" ]] && src_bcd_file=$(sudo find "$TEMP_BOOT" -maxdepth 3 -type f -iname "bcd" 2>/dev/null | head -n1)

  if [[ -n "$src_bcd_file" && -f "$src_bcd_file" ]]; then
    sudo cp -f "$src_bcd_file" "$MOUNT_POINT/BCDBKP" 2>/dev/null
  fi
}

setup_grub4dos() {
  local title="$1"
  local ldr_file="$2"

  sudo dialog --infobox "Configuring Grub4dos Boot Manager..." 3 45
  
  local grldr_src=$(sudo find ./bootldr/grldr -type f -iname "GRLDR" 2>/dev/null | head -n1)
  [[ -z "$grldr_src" ]] && grldr_src=$(sudo find ./bootldr -type f -iname "GRLDR" 2>/dev/null | head -n1)
  [[ -n "$grldr_src" ]] && sudo cp -f "$grldr_src" "$TEMP_BOOT/GRLDR" 2>/dev/null
  
  local g4d_disk=$(get_disk_number)
  local g4d_part=$((BOOT_PART_NUM - 1))
  local menu_lst="$TEMP_BOOT/menu.lst"
  
  local loader_cmd="chainloader"
  if [[ "$ldr_file" =~ freeldr ]]; then
    loader_cmd="kernel"
  fi

  read -r -d '' NEW_ENTRY <<EOF
title $title
root (hd$g4d_disk,$g4d_part)
makeactive
$loader_cmd /$ldr_file
EOF

  if [[ ! -f "$menu_lst" ]]; then
    echo -e "timeout 10\n" | sudo tee "$menu_lst" >/dev/null
  fi

  sudo dos2unix "$menu_lst" 2>/dev/null

  # 1. Insert new entry at the top of title entries (below global settings)
  local tmp_menu=$(mktemp)
  if sudo grep -q -i "^title[[:space:]]" "$menu_lst"; then
    sudo awk -v entry="$NEW_ENTRY" '
      BEGIN { inserted=0; IGNORECASE=1 }
      /^title[[:space:]]/ && !inserted {
        print entry "\n"
        inserted=1
      }
      { print }
    ' "$menu_lst" | sudo tee "$tmp_menu" >/dev/null
  else
    sudo cp -f "$menu_lst" "$tmp_menu"
    echo -e "\n$NEW_ENTRY" | sudo tee -a "$tmp_menu" >/dev/null
  fi

  # 2. Strict Deduplication Engine: Keep topmost title block, purge lower identical/duplicate blocks
  local clean_menu=$(mktemp)
  sudo awk '
    BEGIN { skip=0; blank_count=0; IGNORECASE=1 }

    /^title[[:space:]]/ {
      # Normalize title string to lowercase for key comparison
      title_key = tolower($0)
      gsub(/[ \t]+/, " ", title_key)
      gsub(/^title /, "", title_key)
      
      if (seen_title[title_key]++) {
        skip=1
      } else {
        skip=0
        print
        blank_count=0
      }
      next
    }

    # If inside a duplicated title block, drop all lines until next title
    skip { next }

    # Squeeze consecutive empty lines
    /^[[:space:]]*$/ {
      if (++blank_count > 1) next
      print ""
      next
    }

    { blank_count=0; print }
  ' "$tmp_menu" | sudo tee "$clean_menu" >/dev/null

  sudo cp -f "$clean_menu" "$menu_lst"
  sudo rm -f "$tmp_menu" "$clean_menu"
  sudo unix2dos "$menu_lst" 2>/dev/null
}

configure_nt6x_boot() {
  sudo dialog --clear --nocancel \
    --title "NT6x Boot Manager Selection" \
    --menu "Choose Bootloader options for $EDITION_DESC:" 12 65 3 \
    1 "BOOTMGR" \
    2 "BOOTMGR with Grub4dos Boot Manager" \
    3 "Skip editing boot entries" \
    3>&1 1>&2 2>&3 | sudo tee /tmp/boot_choice >/dev/null 2>&1

  local choice=$(cat /tmp/boot_choice 2>/dev/null)

  if [[ "$choice" -eq 3 ]]; then
    return 0
  fi

  backup_old_boot_files

  sudo dialog --infobox "Deploying BOOTMGR and updating BCD..." 3 45

  # --- CRITICAL NTFS CASE-SENSITIVITY FIX ---
  # Force unify any existing WIM/system boot folders into a single 'Boot' directory
  local existing_boots
  mapfile -t existing_boots < <(sudo find "$TEMP_BOOT" -maxdepth 1 -type d -iname "boot" ! -iname "Boot.*" 2>/dev/null)
  
  local temp_unified_boot="/tmp/unified_boot_dir"
  sudo rm -rf "$temp_unified_boot" 2>/dev/null
  sudo mkdir -p "$temp_unified_boot"

  # Merge all contents from any 'boot' / 'Boot' folders to temporary staging area
  if [[ ${#existing_boots[@]} -gt 0 ]]; then
    for b_dir in "${existing_boots[@]}"; do
      if [[ -d "$b_dir" ]]; then
        sudo cp -rf "$b_dir/." "$temp_unified_boot/" 2>/dev/null
        sudo rm -rf "$b_dir" 2>/dev/null
      fi
    done
  fi

  # Create clean unified 'Boot' folder on target partition
  sudo mkdir -p "$TEMP_BOOT/Boot"
  if [[ -d "$temp_unified_boot" ]]; then
    sudo cp -rf "$temp_unified_boot/." "$TEMP_BOOT/Boot/" 2>/dev/null
    sudo rm -rf "$temp_unified_boot" 2>/dev/null
  fi
  # ------------------------------------------

  local bootmgr_src=$(sudo find ./bootldr/bootmgr -type f -iname "bootmgr" 2>/dev/null | head -n1)
  [[ -z "$bootmgr_src" ]] && bootmgr_src=$(sudo find ./bootldr -type f -iname "bootmgr" 2>/dev/null | head -n1)
  [[ -n "$bootmgr_src" ]] && sudo cp -f "$bootmgr_src" "$TEMP_BOOT/BOOTMGR"

  # Copy template boot folder files into the clean unified 'Boot' directory
  local src_boot_dir=$(sudo find ./bootldr/bootmgr -type d -iname "boot" 2>/dev/null | head -n1)
  if [[ -n "$src_boot_dir" && -d "$src_boot_dir" ]]; then
    sudo cp -rf "$src_boot_dir/." "$TEMP_BOOT/Boot/"
  fi

  # Target strictly the capitalized 'Boot' directory for BCD update
  local target_bcd="$TEMP_BOOT/Boot/BCD"

  local bcd_name=""

  if [[ "$OS_CODE" =~ VISTA86 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="VISTA86BCDP"
  elif [[ "$OS_CODE" =~ VISTA86 ]]; then bcd_name="VISTA86BCD"
  elif [[ "$OS_CODE" =~ VISTA64 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="VISTA64BCDP"
  elif [[ "$OS_CODE" =~ VISTA64 ]]; then bcd_name="VISTA64BCD"
  elif [[ "$OS_CODE" =~ WIN7_86 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="WIN7_86BCDP"
  elif [[ "$OS_CODE" =~ WIN7_86 ]]; then bcd_name="WIN7_86BCD"
  elif [[ "$OS_CODE" =~ WIN7_64 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="WIN7_64BCDP"
  elif [[ "$OS_CODE" =~ WIN7_64 ]]; then bcd_name="WIN7_64BCD"
  elif [[ "$OS_CODE" =~ WIN80_86 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="WIN80_86BCDP"
  elif [[ "$OS_CODE" =~ WIN80_86 ]]; then bcd_name="WIN80_86BCD"
  elif [[ "$OS_CODE" =~ WIN80_64 && "$EDITION_DESC" =~ Patched ]]; then bcd_name="WIN80_64BCDP"
  elif [[ "$OS_CODE" =~ WIN80_64 ]]; then bcd_name="WIN80_64BCD"
  fi

  # Determine BCD search directory based on PAE/APIC support (Only for 32-bit x86 OS)
  local bcd_search_dir="./bootldr/bootmgr"

  if [[ "$OS_CODE" =~ 86 ]]; then
    local pae_supported=$(check_pae)
    local apic_supported=$(check_apic)

    if [[ "$pae_supported" == "No" && "$apic_supported" == "No" ]]; then
      bcd_search_dir="./bootldr/bootmgr/nopaeapic"
    elif [[ "$pae_supported" == "No" ]]; then
      bcd_search_dir="./bootldr/bootmgr/nopae"
    elif [[ "$apic_supported" == "No" ]]; then
      bcd_search_dir="./bootldr/bootmgr/noapic"
    fi
  fi

  # Fallback: Search in specific directory first; if not found, fallback to root ./bootldr/bootmgr
  local bcd_src=$(sudo find "$bcd_search_dir" -maxdepth 1 -type f -iname "$bcd_name" 2>/dev/null | head -n1)
  [[ -z "$bcd_src" ]] && bcd_src=$(sudo find ./bootldr/bootmgr -maxdepth 1 -type f -iname "$bcd_name" 2>/dev/null | head -n1)

  update_bootmgr_bcd "$target_bcd" "$bcd_src"

  if [[ "$choice" -eq 2 ]]; then
    setup_grub4dos "Windows Vista/7/8/10/11 BOOTMGR" "BOOTMGR"
    apply_boot_records "GRLDR"
  else
    apply_boot_records "BOOTMGR"
  fi
  
  # Fast, depth-limited search for desktop.ini in Startup paths
  local startup_dir
  startup_dir=$(sudo find "$MOUNT_POINT/ProgramData/Microsoft/Windows/Start Menu/Programs" -maxdepth 2 -type d -iname "Startup" 2>/dev/null | head -n1)
  if [[ -n "$startup_dir" ]]; then
    sudo find "$startup_dir" -maxdepth 1 -type f -iname "desktop.ini" -delete 2>/dev/null
  fi

  for username in "User" "User-PC"; do
    local user_startup_dir
    user_startup_dir=$(sudo find "$MOUNT_POINT/Users/$username/AppData/Roaming/Microsoft/Windows/Start Menu/Programs" -maxdepth 2 -type d -iname "Startup" 2>/dev/null | head -n1)
    if [[ -n "$user_startup_dir" ]]; then
      sudo find "$user_startup_dir" -maxdepth 1 -type f -iname "desktop.ini" -delete 2>/dev/null
    fi
  done
  
  deploy_setup_complete_script "./bootldr/bootmgr"
  
  sudo rm -f /tmp/boot_choice 2>/dev/null
}

configure_nt345x_boot() {
  local os_fs=$(get_fs_type "$OS_PART_NAME")
  local is_nt3=false
  local freeldr_ntfs_incompatible=false
  local ntldr_capable=false
  
  local height=13

  if [[ "$EDITION_DESC" =~ NT\ 3 || "$OS_CODE" =~ NT3 ]]; then
    is_nt3=true
  fi
  
  if [[ "$SETUP_TYPE" -eq 0 && "$os_fs" == "ntfs" ]]; then
    local freeldr_ntfs_incompatible=true
  fi
  
  if [[ "$os_fs" == "fat12" || "$os_fs" == "fat16" || "$os_fs" == "fat32" || "$os_fs" == "vfat" || "$os_fs" == "fat" || "$os_fs" == "ntfs" ]]; then
    ntldr_capable=true
  fi

  local MENU_OPTS=()
  if $ntldr_capable; then
    MENU_OPTS+=(1 "NTLDR")
  fi
  if ! $is_nt3 && ! $freeldr_ntfs_incompatible; then
    MENU_OPTS+=(2 "FreeLdr")
  fi
  if $ntldr_capable; then
    MENU_OPTS+=(3 "NTLDR with Grub4dos")
  else
    height=$(( $height - 2 ))
  fi
  if ! $is_nt3 && ! $freeldr_ntfs_incompatible; then
    MENU_OPTS+=(4 "FreeLdr with Grub4dos")
  else
    height=$(( $height - 2 ))
  fi
  MENU_OPTS+=(5 "Skip editing boot entries")

  local count=$(( ${#MENU_OPTS[@]} / 2 ))

  sudo dialog --clear --nocancel \
    --title "Bootloader Selection" \
    --menu "Select bootloader configuration for $EDITION_DESC:" $height 65 $count \
    "${MENU_OPTS[@]}" \
    3>&1 1>&2 2>&3 | sudo tee /tmp/boot_choice >/dev/null

  local choice=$(cat /tmp/boot_choice)

  if [[ "$choice" -eq 5 ]]; then
    return 0
  fi

  backup_old_boot_files

  sudo dialog --infobox "Deploying bootloader and updating configuration..." 3 55

  ldr_src_name="2KLDR"
  loader_pbr_id="NTLDR"
  grub_chain_file="NTLDR"

  if [[ "$OS_CODE" =~ XP ]]; then
    ldr_src_name="XPLDR"
  fi

  if [[ "$choice" -eq 2 || "$choice" -eq 4 ]]; then
    loader_pbr_id="FREELDR"
    grub_chain_file="freeldr.sys"
  fi

  local ini_file="2k.ini"
  if [[ "$OS_CODE" == "NT31" ]]; then ini_file="nt31.ini"
  elif [[ "$OS_CODE" == "NT350" ]]; then ini_file="nt350.ini"
  elif [[ "$OS_CODE" == "NT351" ]]; then ini_file="nt351.ini"
  elif [[ "$OS_CODE" == "NT40" ]]; then ini_file="nt40.ini"
  elif [[ "$EDITION_DESC" =~ 2000 && "$EDITION_DESC" =~ ACPI\+APIC ]]; then ini_file="2kapic.ini"
  elif [[ "$OS_CODE" == "2000" ]]; then ini_file="2000.ini"
  elif [[ "$EDITION_DESC" =~ XP && "$EDITION_DESC" =~ 486 && "$EDITION_DESC" =~ Patched ]]; then ini_file="xp486.ini"
  elif [[ "$EDITION_DESC" =~ XP && "$EDITION_DESC" =~ NT\ 5.2 && "$EDITION_DESC" =~ Patched ]]; then ini_file="xp86nt52.ini"
  elif [[ "$EDITION_DESC" =~ XP && "$EDITION_DESC" =~ Patched ]]; then ini_file="xp86p.ini"
  elif [[ "$OS_CODE" =~ XP64 ]]; then ini_file="xp64.ini"
  elif [[ "$OS_CODE" =~ XP86 || "$EDITION_DESC" =~ XP ]]; then ini_file="xp86.ini"
  fi

  if [[ "$choice" -eq 1 || "$choice" -eq 3 ]]; then
    local src_ldr=$(sudo find ./bootldr/ntldr -type f -iname "$ldr_src_name" 2>/dev/null | head -n1)
    local src_detect=$(sudo find ./bootldr/ntldr -type f -iname "NTDETECT.COM" 2>/dev/null | head -n1)
    [[ -n "$src_ldr" ]] && sudo cp -f "$src_ldr" "$TEMP_BOOT/NTLDR"
    [[ -n "$src_detect" ]] && sudo cp -f "$src_detect" "$TEMP_BOOT/NTDETECT.COM"
  elif [[ "$choice" -eq 2 || "$choice" -eq 4 ]]; then
    local src_free=$(sudo find ./bootldr/freeldr -type f -iname "freeldr.sys" 2>/dev/null | head -n1)
    [[ -n "$src_free" ]] && sudo cp -f "$src_free" "$TEMP_BOOT/freeldr.sys"
  fi

  local target_bootini="$TEMP_BOOT/boot.ini"
  local target_freeldr="$TEMP_BOOT/freeldr.ini"

  if [[ "$choice" -eq 1 || "$choice" -eq 3 ]]; then
    local ini_src=$(sudo find ./bootldr/ntldr -type f -iname "$ini_file" 2>/dev/null | head -n1)
    update_existing_bootini "$target_bootini" "$ini_src"
  elif [[ "$choice" -eq 2 || "$choice" -eq 4 ]]; then
    local ini_src=$(sudo find ./bootldr/freeldr -type f -iname "$ini_file" 2>/dev/null | head -n1)
    update_existing_freeldr "$target_freeldr" "$ini_src"
  fi
  
  # --- Dynamic Hardware Filter Engine ---
  if [[ "$choice" -eq 1 || "$choice" -eq 3 ]] && [[ -f "$target_bootini" ]]; then
    # Standard boot.ini Filter (Single line per OS)
    sudo dos2unix "$target_bootini" 2>/dev/null

    if [[ $(check_apic) == "No" ]]; then
      sudo sed -i -E '/APIC/d; /_APIC/d; /MPS/d; /_MPS/d' "$target_bootini"
    else
      if [[ $(check_mps) == "No" ]] || [[ "$EDITION_DESC" =~ NT\ 3\.50 && $(check_mps) != "Yes" && $(check_mps) != "1.1" ]]; then
	    sudo sed -i -E '/MPS/d; /_MPS/d' "$target_bootini"
	  fi
    fi

    [[ $(check_acpi) == "No" ]] && sudo sed -i -E '/ACPI/d; /_ACPI/d' "$target_bootini"
    
    # Precise PAE Check (Safely protects /NOPAE)
    [[ $(check_pae) == "No" ]]  && sudo sed -i -E '/\+PAE/d; /\/PAE/d; /_PAE/d; /\bPAE\b/d' "$target_bootini"
    
    [[ $(check_avx) == "No" ]]  && sudo sed -i -E '/AVX/d; /_AVX/d' "$target_bootini"

    # Fix default= to point to the top-most remaining valid ARC entry
    fix_bootini_default "$target_bootini"

    sudo unix2dos "$target_bootini" 2>/dev/null

  elif [[ "$choice" -eq 2 || "$choice" -eq 4 ]] && [[ -f "$target_freeldr" ]]; then
    # Advanced Multi-line freeldr.ini Block Filter
    sudo dos2unix "$target_freeldr" 2>/dev/null

    if [[ $(check_apic) == "No" ]]; then
      clean_freeldr_tag "$target_freeldr" "APIC"
      clean_freeldr_tag "$target_freeldr" "MPS"
    else
      [[ $(check_mps) == "No" ]] && clean_freeldr_tag "$target_freeldr" "MPS"
    fi

    [[ $(check_acpi) == "No" ]] && clean_freeldr_tag "$target_freeldr" "ACPI"
    [[ $(check_pae) == "No" ]]  && clean_freeldr_tag "$target_freeldr" "PAE"
    [[ $(check_avx) == "No" ]]  && clean_freeldr_tag "$target_freeldr" "AVX"

    # Fix DefaultOS to point to the top-most remaining valid entry
    fix_freeldr_default "$target_freeldr"

    sudo unix2dos "$target_freeldr" 2>/dev/null
  fi

  if [[ "$choice" -eq 3 || "$choice" -eq 4 ]]; then
    g4d_title="Windows NT3/NT4/2000 NTLDR"
  
    if [[ "$EDITION_DESC" =~ XP ]]; then
	  g4d_title="Windows XP NTLDR"
    fi
  
    setup_grub4dos "$g4d_title" "$grub_chain_file"
    apply_boot_records "GRLDR" "$grub_chain_file"
  else
    apply_boot_records "$loader_pbr_id" "$grub_chain_file"
  fi
}

configure_custom_boot() {
  sudo dialog --clear --nocancel \
    --title "Custom Boot Options" \
    --menu "Select Bootloader Configuration:" 15 65 7 \
    1 "Windows Vista/7/8/10/11 BOOTMGR" \
    2 "Windows Longhorn with BOOTMGR" \
    3 "Windows Longhorn with NTLDR" \
    4 "Windows XP NTLDR" \
    5 "Windows NT3/NT4/2000 NTLDR" \
    6 "FreeLdr" \
    7 "Skip Editing Entries" \
    3>&1 1>&2 2>&3 | sudo tee /tmp/cstm_choice >/dev/null

  local cstm_choice=$(cat /tmp/cstm_choice)

  if [[ "$cstm_choice" -eq 7 ]]; then
    return 0
  fi

  backup_old_boot_files

  sudo dialog --infobox "Setting up custom bootloader files..." 3 50

  local target_ldr="BOOTMGR"
  local loader_id="BOOTMGR"
  local title="Custom Windows OS"

  # Target System32 Directory for Winload Injection
  local target_sys32_dir="$MOUNT_POINT/$SYS_DIR/system32"

  # Custom BCD boot folder copy handler
  local src_custom_boot_dir=""
  if [[ "$cstm_choice" -eq 1 ]]; then
    src_custom_boot_dir=$(sudo find ./bootldr/cstmldr -type d -iname "bmgrboot" 2>/dev/null | head -n1)
  elif [[ "$cstm_choice" -eq 2 ]]; then
    src_custom_boot_dir=$(sudo find ./bootldr/cstmldr -type d -iname "lhmgrboot" 2>/dev/null | head -n1)
  fi

  if [[ -n "$src_custom_boot_dir" && -d "$src_custom_boot_dir" ]]; then
    sudo mkdir -p "$TEMP_BOOT/boot"
    sudo cp -rf "$src_custom_boot_dir/." "$TEMP_BOOT/boot/"
  fi

  case "$cstm_choice" in
    1) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "BOOTMGR" | head -n1)" "$TEMP_BOOT/BOOTMGR" 2>/dev/null
       update_bootmgr_bcd "$TEMP_BOOT/boot/bcd" "$(sudo find ./bootldr/cstmldr -type f -iname "cstmnt6.bcd" | head -n1)"
       
       # # winload.exe injection to OS partition system32
       # local src_winload
       # src_winload=$(sudo find ./bootldr/cstmldr -type f -iname "winload.exe" 2>/dev/null | head -n1)
       # if [[ -n "$src_winload" && -d "$target_sys32_dir" ]]; then
       #   local old_winload
       #   old_winload=$(sudo find "$target_sys32_dir" -maxdepth 1 -type f -iname "winload.exe" 2>/dev/null | head -n1)
       #   [[ -n "$old_winload" && -f "$old_winload" ]] && sudo mv -f "$old_winload" "$target_sys32_dir/winload.exe.old" 2>/dev/null
       #   sudo cp -f "$src_winload" "$target_sys32_dir/winload.exe"
       # fi

       target_ldr="BOOTMGR"; loader_id="BOOTMGR"; title="Windows Vista/7/8/10/11 Custom WIM" ;;

    2) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "LHBMGR" | head -n1)" "$TEMP_BOOT/BOOTMGR" 2>/dev/null
       update_bootmgr_bcd "$TEMP_BOOT/boot/bcd" "$(sudo find ./bootldr/cstmldr -type f -iname "cstmlh.bcd" | head -n1)"
       
       # lhload.exe injection ALWAYS AS winload.exe in system32
       local src_lhload
       src_lhload=$(sudo find ./bootldr/cstmldr -type f -iname "lhload.exe" 2>/dev/null | head -n1)
       if [[ -n "$src_lhload" && -d "$target_sys32_dir" ]]; then
         local old_winload
         old_winload=$(sudo find "$target_sys32_dir" -maxdepth 1 -type f -iname "winload.exe" 2>/dev/null | head -n1)
         [[ -n "$old_winload" && -f "$old_winload" ]] && sudo mv -f "$old_winload" "$target_sys32_dir/winload.exe.old" 2>/dev/null
         sudo cp -f "$src_lhload" "$target_sys32_dir/winload.exe"
       fi

       target_ldr="BOOTMGR"; loader_id="BOOTMGR"; title="Windows Longhorn Custom WIM BOOTMGR" ;;

    3) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "LHNTLDR" | head -n1)" "$TEMP_BOOT/NTLDR" 2>/dev/null
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "LHDETECT.COM" | head -n1)" "$TEMP_BOOT/NTDETECT.COM" 2>/dev/null

       local raw_bootini
       raw_bootini=$(sudo find ./bootldr/cstmldr -type f -iname "cstmlh.ini" 2>/dev/null | head -n1)
       
       if [[ -n "$raw_bootini" && -f "$raw_bootini" ]]; then
         local patched_bootini="/tmp/cstm_patched_boot.ini"
         sudo cp -f "$raw_bootini" "$patched_bootini"
         
         sudo dos2unix "$patched_bootini" 2>/dev/null
         
         sudo sed -i -E '/[mM][uU][lL][tT][iI]|[sS][cC][sS][iI]/ s|[wW][iI][nN][dD][oO][wW][sS]|'"$SYS_DIR"'|' "$patched_bootini"
         
         sudo unix2dos "$patched_bootini" 2>/dev/null
         
         update_existing_bootini "$TEMP_BOOT/boot.ini" "$patched_bootini"
         sudo rm -f "$patched_bootini" 2>/dev/null
       fi

       target_ldr="NTLDR"; loader_id="NTLDR"; title="Windows Longhorn Custom WIM NTLDR" ;;

    4) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "XPLDR" | head -n1)" "$TEMP_BOOT/NTLDR" 2>/dev/null
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "NTDETECT.COM" | head -n1)" "$TEMP_BOOT/NTDETECT.COM" 2>/dev/null

       local raw_bootini
       raw_bootini=$(sudo find ./bootldr/cstmldr -type f -iname "cstmxp.ini" 2>/dev/null | head -n1)
       
       if [[ -n "$raw_bootini" && -f "$raw_bootini" ]]; then
         local patched_bootini="/tmp/cstm_patched_boot.ini"
         sudo cp -f "$raw_bootini" "$patched_bootini"
         
         sudo dos2unix "$patched_bootini" 2>/dev/null
         
         sudo sed -i -E '/[mM][uU][lL][tT][iI]|[sS][cC][sS][iI]/ s|[wW][iI][nN][dD][oO][wW][sS]|'"$SYS_DIR"'|' "$patched_bootini"
         
         sudo unix2dos "$patched_bootini" 2>/dev/null
         
         update_existing_bootini "$TEMP_BOOT/boot.ini" "$patched_bootini"
         sudo rm -f "$patched_bootini" 2>/dev/null
       fi

       target_ldr="NTLDR"; loader_id="NTLDR"; title="Windows XP Custom WIM" ;;

    5) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "2KLDR" | head -n1)" "$TEMP_BOOT/NTLDR" 2>/dev/null
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "NTDETECT.COM" | head -n1)" "$TEMP_BOOT/NTDETECT.COM" 2>/dev/null
	   
       local raw_bootini
       raw_bootini=$(sudo find ./bootldr/cstmldr -type f -iname "cstm2k.ini" 2>/dev/null | head -n1)
       
       if [[ -n "$raw_bootini" && -f "$raw_bootini" ]]; then
         local patched_bootini="/tmp/cstm_patched_boot.ini"
         sudo cp -f "$raw_bootini" "$patched_bootini"
         
         sudo dos2unix "$patched_bootini" 2>/dev/null
         
         sudo sed -i -E '/[mM][uU][lL][tT][iI]|[sS][cC][sS][iI]/ s|[wW][iI][nN][nN][tT]|'"$SYS_DIR"'|' "$patched_bootini"
         
         sudo unix2dos "$patched_bootini" 2>/dev/null
         
         update_existing_bootini "$TEMP_BOOT/boot.ini" "$patched_bootini"
         sudo rm -f "$patched_bootini" 2>/dev/null
       fi
	   
       target_ldr="NTLDR"; loader_id="NTLDR"; title="Windows NT3/NT4/2000 Custom WIM" ;;

    6) 
       sudo cp -f "$(sudo find ./bootldr/cstmldr -type f -iname "freeldr.sys" | head -n1)" "$TEMP_BOOT/freeldr.sys" 2>/dev/null
       
       local raw_freeldr
       raw_freeldr=$(sudo find ./bootldr/cstmldr -type f -iname "freeldr.ini" 2>/dev/null | head -n1)
       
       if [[ -n "$raw_freeldr" && -f "$raw_freeldr" ]]; then
         local patched_freeldr="/tmp/cstm_patched_freeldr.ini"
         sudo cp -f "$raw_freeldr" "$patched_freeldr"
         
         sudo dos2unix "$patched_freeldr" 2>/dev/null
         
         sudo sed -i -E '/[mM][uU][lL][tT][iI]|[sS][cC][sS][iI]/ s|[wW][iI][nN][dD][oO][wW][sS]|'"$SYS_DIR"'|' "$patched_freeldr"
         
         sudo unix2dos "$patched_freeldr" 2>/dev/null
         
         update_existing_freeldr "$TEMP_BOOT/freeldr.ini" "$patched_freeldr"
         sudo rm -f "$patched_freeldr" 2>/dev/null
       fi
       
       target_ldr="freeldr.sys"; loader_id="FREELDR"; title="FreeLdr Custom WIM" ;;
  esac
  
  if [[ "$cstm_choice" -eq 1 || "$cstm_choice" -eq 2 ]]; then
    deploy_setup_complete_script "./bootldr/cstmldr"
  fi

  sudo dialog --clear --nocancel \
    --title "Grub4dos Boot Manager Option" \
    --menu "Do you want to install Grub4dos Boot Manager?" 10 60 2 \
    1 "Do Not Install Grub4dos Boot Manager" \
    2 "Install Grub4dos Boot Manager" \
    3>&1 1>&2 2>&3 | sudo tee /tmp/g4d_choice >/dev/null

  if [[ $(cat /tmp/g4d_choice) -eq 2 ]]; then
    setup_grub4dos "$title" "$target_ldr"
    apply_boot_records "GRLDR"
  else
    apply_boot_records "$loader_id"
  fi
}

patch_alternative_fs_drive_letters() {
  local sys_hive=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type f -iname "system" -ipath "*/config/system" -not -ipath "*/RegBack/*" 2>/dev/null | head -n 1)
  [[ -z "$sys_hive" || ! -f "$sys_hive" ]] && return 0

  if [[ ! "$EDITION_DESC" =~ Patched || "$EDITION_DESC" =~ 486 ]]; then
    return 0
  fi

  sudo dialog --infobox "Mapping alternative filesystems in registry..." 3 50

  local allow_ext=false
  local allow_btrfs=false
  local allow_reiser=false

  if [[ "$EDITION_DESC" =~ NT\ 4 || "$EDITION_DESC" =~ 2000 || "$EDITION_DESC" =~ XP || "$EDITION_DESC" =~ Vista || "$EDITION_DESC" =~ WIN7 || "$EDITION_DESC" =~ WIN8 ]]; then
    allow_ext=true
  fi

  if [[ "$EDITION_DESC" =~ XP || "$EDITION_DESC" =~ Vista || "$EDITION_DESC" =~ WIN7 || "$EDITION_DESC" =~ WIN8 ]]; then
    allow_btrfs=true
  fi

  if [[ "$EDITION_DESC" =~ 2000 || "$EDITION_DESC" =~ XP ]]; then
    allow_reiser=true
  fi

  local reg_file="/tmp/dosdev_alt_fs.reg"
  cat <<EOF | sudo tee "$reg_file" >/dev/null
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Session Manager\DOS Devices]
EOF

  local current_ascii=80
  local patched_entries=0

  for disk_dev in /dev/sd* /dev/nvme*n* /dev/mmcblk*; do
    [[ ! -b "$disk_dev" ]] && continue
    local d_type=$(sudo lsblk -dn -o TYPE "$disk_dev" 2>/dev/null)
    [[ "$d_type" != "disk" ]] && continue

    local disk_basename=$(sudo basename "$disk_dev")
    local disk_idx=0
    if [[ "$disk_basename" =~ ^sd([a-z])$ ]]; then
      disk_idx=$(( $(printf '%d' "'${BASH_REMATCH[1]}") - 97 ))
    elif [[ "$disk_basename" =~ ^nvme([0-9]+)n[0-9]+$ ]]; then
      disk_idx="${BASH_REMATCH[1]}"
    elif [[ "$disk_basename" =~ ^mmcblk([0-9]+)$ ]]; then
      disk_idx="${BASH_REMATCH[1]}"
    fi

    while read -r part_name part_fs; do
      [[ -z "$part_name" ]] && continue
      local part_dev="/dev/$part_name"
      local part_fs_lower=$(echo "$part_fs" | tr '[:upper:]' '[:lower:]')
      local is_target_fs=false

      if [[ "$part_fs_lower" == "ext2" || "$part_fs_lower" == "ext3" ]] && $allow_ext; then is_target_fs=true; fi
      if [[ "$part_fs_lower" == "btrfs" ]] && $allow_btrfs; then is_target_fs=true; fi
      if [[ "$part_fs_lower" == "reiserfs" ]] && $allow_reiser; then is_target_fs=true; fi

      if $is_target_fs; then
        local letter=""
        if [[ "$part_dev" == "$OS_PART_NAME" ]]; then
          letter="C:"
        else
          if (( current_ascii <= 90 )); then
            letter="$(printf "\\x$(printf %x $current_ascii)"): "
            ((current_ascii++))
          fi
        fi

        if [[ -n "$letter" ]]; then
          local part_idx=$(get_bootini_number "$part_dev")
          echo "\"$letter\"=\"\\\\Device\\\\Harddisk${disk_idx}\\\\Partition${part_idx}\"" | sudo tee -a "$reg_file" >/dev/null
          ((patched_entries++))
        fi
      fi
    done < <(sudo lsblk -ln -o NAME,FSTYPE "$disk_dev" 2>/dev/null | awk '$2!="" {print $1, $2}')
  done

  if (( patched_entries > 0 )); then
    local tmp_hive="/tmp/SYSTEM_hive_copy"
    sudo cp "$sys_hive" "$tmp_hive"
    
    sudo dos2unix "$reg_file" 2>/dev/null
    sudo reged -I "$tmp_hive" "HKEY_LOCAL_MACHINE\SYSTEM" "$reg_file" -C >/dev/null 2>&1
    sudo cp "$tmp_hive" "$sys_hive"
  fi
}

patch_non_ntfs_setup_nt6x() {
  # 1. Skip if OS partition is NTFS or OS version is below Vista
  local os_fs
  os_fs=$(get_fs_type "$OS_PART_NAME")

  if [[ "$os_fs" == "ntfs" ]]; then
    return 0
  fi

  if [[ ! ("$OS_CODE" =~ VISTA || "$OS_CODE" =~ WIN7 || "$OS_CODE" =~ WIN8 || "$OS_CODE" =~ WIN10 || "$OS_CODE" =~ WIN11) ]]; then
    return 0
  fi

  # 2. Locate SYSTEM Registry Hive Path
  local sys_hive
  sys_hive=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type f -iname "system" -ipath "*/config/system" -not -ipath "*/RegBack/*" 2>/dev/null | head -n 1)

  if [[ -z "$sys_hive" || ! -f "$sys_hive" ]]; then
    return 0
  fi

  sudo dialog --infobox "Patching Windows Setup registry flags for non-NTFS boot..." 4 58

  local tmp_hive="/tmp/SYSTEM_hive_setup_patch"
  sudo cp -f "$sys_hive" "$tmp_hive"

  # 3. Modify existing registry values directly via reged interactive pipe
  {
    echo "cd Setup"
    echo "ed CmdLine"
    echo "cmd.exe /c C:\Windows\Setup\Scripts\oobefix.cmd"
    echo "q"
    echo "y"
  } | sudo reged -e "$tmp_hive" >/dev/null 2>&1

  sudo cp -f "$tmp_hive" "$sys_hive"
  sudo rm -f "$tmp_hive" 2>/dev/null
  
  # 4. Copy oobefix.cmd to C:\Windows\Setup\Scripts\ directory
  local src_cmd="./bootldr/bootmgr/oobefix.cmd"
  
  if [[ -f "$src_cmd" ]]; then
    # Target directory path: $MOUNT_POINT/Windows/Setup/Scripts
    local win_scripts_dir
    win_scripts_dir=$(sudo find "$MOUNT_POINT" -maxdepth 3 -type d -iname "Scripts" -ipath "*/Windows/Setup/Scripts" 2>/dev/null | head -n 1)

    # If the directory doesn't exist, create it (case-insensitive fallback)
    if [[ -z "$win_scripts_dir" ]]; then
      local win_dir
      win_dir=$(sudo find "$MOUNT_POINT" -maxdepth 1 -type d -iname "Windows" 2>/dev/null | head -n 1)
      [[ -z "$win_dir" ]] && win_dir="$MOUNT_POINT/Windows"
      
      win_scripts_dir="$win_dir/Setup/Scripts"
      sudo mkdir -p "$win_scripts_dir"
    fi

    # Copy the file to OS partition
    sudo cp -f "$src_cmd" "$win_scripts_dir/oobefix.cmd"
  fi
}

patch_registry_drive_letter() {
  local TARGET_DRIVE="C"

  if [[ "$SETUP_TYPE" -eq 1 ]]; then
    sudo dialog --clear --nocancel \
      --title "Registry Drive Letter Patch" \
      --menu "Select Target OS for Drive Letter Patching:" 12 68 4 \
      1 "Windows Vista, 7, 8, 10 or 11" \
      2 "Windows 2000, XP or 2003" \
      3 "Windows NT 3.5x or NT 4.0" \
      4 "Windows NT 3.1 or Skip Patching" \
      3>&1 1>&2 2>&3 | sudo tee /tmp/reg_choice >/dev/null 2>&1

    local reg_sel=$(cat /tmp/reg_choice)
    case "$reg_sel" in
      1) OS_CODE="VISTA" ;;
      2) OS_CODE="XP" ;;
      3) OS_CODE="NT40" ;;
      4) OS_CODE="NT31" ;;
    esac

    # Option 4 selected: Immediately exit without asking for a drive letter
    if [[ "$OS_CODE" == *NT31* ]]; then
      sudo rm -f "/tmp/reg_choice" 2>/dev/null
      return 0
    fi

    # Loop until a valid single alphabet letter (A-Z) is provided
    while true; do
      local input_letter
      input_letter=$(sudo dialog --clear --nocancel \
        --title "Target Drive Letter" \
        --inputbox "Enter target drive letter for the OS (A-Z):" 8 50 "$TARGET_DRIVE" \
        3>&1 1>&2 2>&3)

      # Strip spaces and convert input to uppercase
      input_letter=$(echo "$input_letter" | tr -d ' ' | tr '[:lower:]' '[:upper:]')

      # Validate single letter regex ([A-Z])
      if [[ "$input_letter" =~ ^[A-Z]$ ]]; then
        TARGET_DRIVE="$input_letter"
        break
      else
        sudo dialog --title "Invalid Drive Letter" \
          --msgbox "Error: '$input_letter' is not a valid drive letter.\nPlease enter a single letter from A to Z." 7 55
      fi
    done
  fi

  if [[ "$OS_CODE" == *NT31* ]]; then
    return 0
  fi

  local sys_hive=$(sudo find "$MOUNT_POINT/$SYS_DIR" -type f -iname "system" -ipath "*/config/system" -not -ipath "*/RegBack/*" 2>/dev/null | head -n 1)

  if [[ -z "$sys_hive" || ! -f "$sys_hive" ]]; then
    sudo dialog --msgbox "Could not locate SYSTEM registry hive!\nSkipping drive letter patch." 6 60
    return 0
  fi

  sudo dialog --infobox "Assigning drive letter ($TARGET_DRIVE:) in registry..." 3 55

  local sig_hex=$(sudo dd if="$DISK" bs=1 skip=440 count=4 2>/dev/null | hexdump -v -e '/1 "%02x "' | sed 's/ $//')
  if [[ "$sig_hex" == "00 00 00 00" || -z "$sig_hex" ]]; then
    printf '\x12\x34\x56\x78' | sudo dd of="$DISK" bs=1 seek=440 count=4 conv=notrunc >/dev/null 2>&1
    sig_hex="12 34 56 78"
  fi

  local start_sector=$(sudo cat /sys/block/$(sudo basename "$DISK")/$(sudo basename "$OS_PART_NAME")/start 2>/dev/null)
  local sector_size=$(sudo cat /sys/block/$(sudo basename "$DISK")/queue/logical_block_size 2>/dev/null)
  [[ -z "$sector_size" || "$sector_size" -le 0 ]] && sector_size=512

  local offset=$((start_sector * sector_size))
  local offset_hex=""
  for ((i=0; i<8; i++)); do
    local byte=$(((offset >> (8*i)) & 0xFF))
    offset_hex+=$(printf "%02x " "$byte")
  done

  local full_hex="$(echo "$sig_hex" | sed 's/ /,/g'),$(echo "$offset_hex" | sed 's/ /,/g')"
  full_hex="${full_hex%,}"

  local tmp_hive="/tmp/SYSTEM_hive_copy"
  sudo cp "$sys_hive" "$tmp_hive"
  local disk_num=$(get_disk_number)
  
  local reg_file="/tmp/mntdev.reg"

  if [[ "$OS_CODE" == *NT3* || "$OS_CODE" == *NT4* ]]; then
    local part_idx=$(get_bootini_number "$OS_PART_NAME")
    reg_file="/tmp/ntdosdev.reg"
    cat <<EOF | sudo tee "$reg_file" >/dev/null
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Session Manager\DOS Devices]
"${TARGET_DRIVE}:"="\\\\Device\\\\Harddisk${disk_num}\\\\Partition${part_idx}"
EOF
    sudo dos2unix "$reg_file" 2>/dev/null
    sudo reged -I "$tmp_hive" "HKEY_LOCAL_MACHINE\SYSTEM" "$reg_file" -C >/dev/null 2>&1

  elif [[ "$OS_CODE" == *2000* || "$OS_CODE" == *XP* ]]; then
    cat <<EOF | sudo tee "$reg_file" >/dev/null
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\MountedDevices]
"\\\\DosDevices\\\\${TARGET_DRIVE}:"=hex:$full_hex

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"BootDiskSig"=dword:00000000
EOF
    sudo dos2unix "$reg_file" 2>/dev/null
    sudo reged -I "$tmp_hive" "HKEY_LOCAL_MACHINE\SYSTEM" "$reg_file" -C >/dev/null 2>&1

  elif [[ "$OS_CODE" =~ VISTA || "$OS_CODE" =~ WIN7 || "$OS_CODE" =~ WIN8 || "$OS_CODE" =~ WIN10 || "$OS_CODE" =~ WIN11 ]]; then
    cat <<EOF | sudo tee "$reg_file" >/dev/null
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\MountedDevices]
"\\\\DosDevices\\\\${TARGET_DRIVE}:"=hex:$full_hex

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"BootDiskSig"=dword:00000000
EOF
    sudo dos2unix "$reg_file" 2>/dev/null
    sudo reged -I "$tmp_hive" "HKEY_LOCAL_MACHINE\SYSTEM" "$reg_file" -C >/dev/null 2>&1
  fi

  sudo cp "$tmp_hive" "$sys_hive"
  sudo rm -f "$reg_file" "$tmp_hive" "/tmp/reg_choice" 2>/dev/null
}

install_csmwrap() {
  # Prompt user confirmation
  sudo dialog --clear --title "CSMWrap Installation" \
    --yesno "Do you want to install CSMWrap EFI application?" 6 63 3>&1 1>&2 2>&3
  local confirm=$?
  
  if [[ $confirm -ne 0 ]]; then
    return 0
  fi
  
  sudo dialog --infobox "Installing CSMWrap EFI application..." 3 52
  
  # Identify target disk device
  local real_part_dev
  real_part_dev=$(realpath "$OS_PART_NAME" 2>/dev/null || readlink -f "$OS_PART_NAME" 2>/dev/null)
  [[ -z "$real_part_dev" ]] && real_part_dev="$OS_PART_NAME"

  local parent_disk_name
  parent_disk_name=$(sudo lsblk -no PKNAME "$real_part_dev" 2>/dev/null | head -n1 | xargs)
  
  local target_disk_dev="/dev/$parent_disk_name"
  [[ ! -b "$target_disk_dev" ]] && target_disk_dev="$DISK"

  # Find the first FAT12/16/32 partition on the disk
  local fat_part=""
  while read -r part fstype; do
    local clean_fstype=$(echo "$fstype" | tr '[:upper:]' '[:lower:]')
    if [[ "$clean_fstype" =~ ^fat || "$clean_fstype" == "vfat" || "$clean_fstype" == "msdos" ]]; then
      fat_part="/dev/$part"
      break
    fi
  done < <(sudo lsblk -lno NAME,FSTYPE "$target_disk_dev" 2>/dev/null | tail -n +2)
  
  # Display error if no suitable FAT partition is found
  if [[ -z "$fat_part" || ! -b "$fat_part" ]]; then
    sudo dialog --clear --title "CSMWrap Installation" \
      --msgbox "ERROR: Suitable partition (FAT12/16/32) not found for CSMWrap." 7 60
    return 0
  fi

  # Mount target FAT partition temporarily
  local csm_mount="/tmp/csmwrap_mount"
  sudo mkdir -p "$csm_mount"
  
  if ! sudo mount "$fat_part" "$csm_mount" 2>/dev/null; then
    sudo dialog --clear --title "Error" \
      --msgbox "Failed to mount partition: $fat_part" 6 50
    sudo rm -rf "$csm_mount"
    return 1
  fi

  # Resolve EFI directory with case-insensitivity
  local target_efi_dir
  target_efi_dir=$(sudo find "$csm_mount" -maxdepth 1 -type d -iname "efi" 2>/dev/null | head -n1)

  # Incremental backup logic for existing EFI directory (EFI.old, EFI.001, EFI.002...)
  if [[ -n "$target_efi_dir" && -d "$target_efi_dir" ]]; then
    local backup_name="$csm_mount/EFI.old"
    if [[ -e "$backup_name" ]]; then
      local counter=1
      while true; do
        local formatted_counter
        formatted_counter=$(printf "%03d" "$counter")
        backup_name="$csm_mount/EFI.$formatted_counter"
        [[ ! -e "$backup_name" ]] && break
        ((counter++))
      done
    fi
    sudo mv -f "$target_efi_dir" "$backup_name" 2>/dev/null
  fi

  # Create clean EFI/Boot directory structure
  sudo mkdir -p "$csm_mount/EFI/Boot"

  # Locate source files and copy as bootia32.efi and bootx64.efi
  local src_ia32
  src_ia32=$(sudo find ./bootldr/csmwrap -type f -iname "csmwrapia32.efi" 2>/dev/null | head -n1)
  
  local src_x64
  src_x64=$(sudo find ./bootldr/csmwrap -type f -iname "csmwrapx64.efi" 2>/dev/null | head -n1)

  if [[ -n "$src_ia32" && -f "$src_ia32" ]]; then
    sudo cp -f "$src_ia32" "$csm_mount/EFI/Boot/bootia32.efi"
  fi

  if [[ -n "$src_x64" && -f "$src_x64" ]]; then
    sudo cp -f "$src_x64" "$csm_mount/EFI/Boot/bootx64.efi"
  fi

  # Sync and clean up mount point
  sudo sync
  sudo umount "$csm_mount" 2>/dev/null
  sudo rm -rf "$csm_mount"
}

# ==============================================================================
# MAIN INSTALLATION EXECUTION FLOW
# ==============================================================================

BOOT_PART_NAME=$(make_partition_path "$DISK" "$BOOT_PART_NUM")
unhide_partition "$DISK" "$OS_PART_NUM"

[[ "$OS_PART_NAME" == "$BOOT_PART_NAME" ]] && TEMP_BOOT="$MOUNT_POINT"

sudo dialog --infobox "Checking filesystem(s) and mounting partition(s)..." 3 57

[[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && check_mount_partition "$BOOT_PART_NAME" "$TEMP_BOOT"
check_mount_partition "$OS_PART_NAME" "$MOUNT_POINT"

[[ ! -f "$WIM_FILE_PATH" ]] && sudo dialog --msgbox "WIM file not found:\n$WIM_FILE_PATH" 7 50 && unmount_all && exit 1

# --- 1. Backup Old OS Directories to Windows.old ---
backup_old_windows_folders

# --- WIM Extraction with Phase Header Display ---
sudo wimlib-imagex apply "$WIM_FILE_PATH" "$WIM_FILE_INDEX" "$MOUNT_POINT" --no-acls --no-attributes --include-invalid-names 2>&1 |
sudo tr '\r' '\n' |
while read -r line; do
  phase=$(echo "$line" | grep -oE '^[^:]+' | xargs)
  percent=$(echo "$line" | sed -n 's/.*(\([0-9]\+\)%).*/\1/p')

  # Replace "Creating files" phase text with "Preparing files"
  if [[ "${phase,,}" == *"creating files"* ]]; then
    phase="Preparing files"
  fi
  
  # Replace "Extracting file data" phase text with "Copying files"
  if [[ "${phase,,}" == *"extracting file"* ]]; then
    phase="Copying files"
  fi

  if [[ -n "$phase" && -n "$percent" ]]; then
    echo "XXX"
    echo "$percent"
    echo "$phase..."
    echo "XXX"
  elif [[ -n "$percent" ]]; then
    echo "$percent"
  fi
done | sudo dialog --title "Installing OS" --gauge "Installer is preparing to copy files..." 7 70 0

RET=${PIPESTATUS[0]}
if [ "$RET" -ne 0 ]; then
  sudo dialog --title "Installer Error" --msgbox "ERROR: Files could not be extracted!\n\nInstaller has failed!" 8 60
  unmount_all
  exit 1
fi
sudo sync

# --- System Root Folder Detection ---
detect_os_root

# --- Apply Patched acpi.sys Driver ---
apply_patched_acpi_driver

# --- Apply Patched uniata.sys Driver ---
apply_patched_uniata_driver

# --- Apply nvme2k Driver ---
apply_nvme2k_driver

# --- Bootloader Setup Trigger ---
if [[ "$SETUP_TYPE" -eq 1 ]]; then
  configure_custom_boot
elif [[ "$OS_CODE" =~ VISTA || "$OS_CODE" =~ WIN7 || "$OS_CODE" =~ WIN8 || "$OS_CODE" =~ WIN10 || "$OS_CODE" =~ WIN11 ]]; then
  configure_nt6x_boot
else
  configure_nt345x_boot
fi

# --- Alternative Filesystem Drive Letter Patching ---
patch_alternative_fs_drive_letters

# --- Non-NTFS Windows NT 6.x Setup Registry Patch ---
patch_non_ntfs_setup_nt6x

# --- Registry Drive Letter Patch ---
patch_registry_drive_letter

# --- CSMWrap Installer ---
install_csmwrap

# --- Unmount Partitions & Exit ---
unmount_all

while true; do
  sudo dialog --nocancel --menu "Installation completed successfully on $OS_PART_NAME.\n\nChoose next action:" 11 60 2 \
    1 "Reboot the Computer" \
    2 "Go Back to Main Menu" 2>/tmp/final_choice

  FINAL_CHOICE=$(cat /tmp/final_choice)
  case "$FINAL_CHOICE" in
    1) exit 5 ;;
    2) exit 0 ;;
  esac
done
