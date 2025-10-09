#!/bin/bash

dialog --infobox "Setup is in progress..." 3 27

# === Initialization ===
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
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

if [[ "$SETUP_TYPE" -eq 1 ]]; then
  OS_CODE="x"
  EDITION_DESC="x"
fi

if [[ -z "$OS_PART_NAME" || -z "$WIM_FILE" || -z "$WIM_FILE_INDEX" || -z "$OS_PART_NUM" || -z "$BOOT_PART_NUM" || -z "$OS_CODE" || -z "$EDITION_DESC" || -z "$SETUP_TYPE" || -z "$WIM_IMAGE_INFO" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

MOUNT_POINT="/mnt/install_part"
CFG_FILE="/mnt/isofiles/os_dir.cfg"

WIM_FILE_PATH=""

# Enable case-insensitive matching
shopt -s nocasematch
shopt -s nocaseglob

if [[ "$SETUP_TYPE" -eq 0 ]]; then
  WIM_FILE_PATH="/mnt/isofiles/osfiles/$WIM_FILE"
elif [[ "$SETUP_TYPE" -eq 1 ]]; then
  WIM_FILE_PATH="/mnt/isofiles/osfiles/custom/$WIM_FILE"
fi

if [[ "$SETUP_TYPE" -eq 0 ]]; then
  # === Parse OS Config ===
  CFG_LINE=$(grep "^$OS_CODE=" "$CFG_FILE")
  IFS=',' read -r LDR_FILE INI_FILE SYS_DIR TITLE <<< "$(echo "$CFG_LINE" | cut -d'=' -f2)"
fi

# === Detect disk and partition numbers ===
DISK_DEVICE=$(lsblk -no PKNAME "$OS_PART_NAME")
DISK="/dev/$DISK_DEVICE"
DISK_BASENAME=$(basename "$DISK_DEVICE")

check_acpi() {
  local acpi_rev
  acpi_rev=$(sudo biosdecode 2>/dev/null | grep -i 'ACPI' | awk '{print $2}' | head -n1)
    
  if [[ -z "$acpi_rev" ]]; then
    if ls /sys/firmware/acpi/tables/* &>/dev/null; then
      echo "Unknown"
    else
      echo "No"
    fi
  else
    echo "$acpi_rev"
  fi
}

check_apic() {
  if [[ -f /sys/firmware/acpi/tables/APIC ]]; then
    echo "Yes"
  else
    echo "No"
  fi
}

check_pae() {
  lscpu | grep -i flags | grep -qw pae
  
  if [[ $? -eq 0 ]]; then
    echo "Yes"
  else
    echo "No"
  fi
}

check_mps() {
    rev=$(sudo biosdecode 2>/dev/null | grep -A1 'Multiprocessor' | grep 'Specification' | awk '{print $NF}')
	
    if [[ -n "$rev" ]]; then
        echo "$rev"
    elif sudo dmesg 2>/dev/null | grep -qi "MP-table"; then
        echo "1.4"
    else
        echo "No"
    fi
}

# === Helper function to build partition device path correctly for NVMe and others ===
make_partition_path() {
  local disk="$1"
  local partnum="$2"
  if [[ "$disk" =~ ^/dev/nvme[0-9]+n[0-9]+$ || "$disk" =~ mmcblk[0-9]+$ ]]; then
    echo "${disk}p${partnum}"
  else
    echo "${disk}${partnum}"
  fi
}

# === Utility Functions ===
unhide_partition() {
  local disk="$1"
  local partnum="$2"
  local flag=$(sudo parted -sm "$disk" print | awk -F: -v p="$partnum" '$1 == p {print $7}')
  
  if [[ $flag == *hidden* ]]; then
    sudo parted "$disk" set "$partnum" hidden off >/dev/null 2>&1
  fi
}

get_fs_type() {
  lsblk -no FSTYPE "$1" | tr '[:upper:]' '[:lower:]'
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
    *)  # For debugging
      dialog --msgbox --nocancel "No fsck handler available for filesystem type: $fs" 3 59
      ;;
  esac

  if [[ "$fs" == "ntfs" ]]; then
    sudo mount -t ntfs3 -o force "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo ntfs-3g "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo mount -t ntfs -o rw "$part" "$mountpoint" >/dev/null 2>&1
  elif [[ "$fs" == "exfat" ]]; then
    sudo mount -o rw "$part" "$mountpoint" >/dev/null 2>&1
    # sudo mount -t exfat "$part" "$mountpoint" >/dev/null 2>&1
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
  local disk="$1"
  local selected_part="$2"

  local bootini_part_num=0
  local fs_index=0
  # local boot_part_num=0
  # local real_index=0

  while read -r part fs _; do
    # ((real_index++))
    [[ -n "$fs" ]] && ((fs_index++))

    if [[ "/dev/$part" == "$selected_part" ]]; then
      # boot_part_num="$real_index"
      bootini_part_num="$fs_index"
      break
    fi
  done < <(lsblk -ln -o NAME,FSTYPE "$disk")

  echo "$bootini_part_num"
}

check_appletv() {
  if [[ $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null) == "AppleTV1,1" ]]; then
    echo "Yes"
  else
    echo "No"
  fi
}

BOOT_PART_NAME=$(make_partition_path "$DISK" "$BOOT_PART_NUM")

# Unhide partitions if flagged hidden
# unhide_partition "$DISK" "$BOOT_PART_NUM"  // obsolete because boot partition can hidden and system can boot from hidden partition
unhide_partition "$DISK" "$OS_PART_NUM"

# === Mount boot and install partitions ===
TEMP_BOOT="/mnt/boot_part"

# If install partition is first primary, boot partition is the same mount point
[[ "$OS_PART_NAME" == "$BOOT_PART_NAME" ]] && TEMP_BOOT="$MOUNT_POINT"

dialog --infobox "Checking filesystem..." 3 28

# Mount boot partition if different from install partition
[[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && check_mount_partition "$BOOT_PART_NAME" "$TEMP_BOOT"

# Mount installation partition
check_mount_partition "$OS_PART_NAME" "$MOUNT_POINT"

# Check archive exists before extracting
[[ ! -f "$WIM_FILE_PATH" ]] && dialog --msgbox "WIM file not found: $WIM_FILE_PATH" 7 50 && exit 1

# === Move old OS folders to Windows.old if config exists ===
OLD_OS_CFG="/mnt/isofiles/old_os_folders.cfg"
if [[ -f "$OLD_OS_CFG" ]]; then
  IFS=':' read -ra OLD_FOLDERS < "$OLD_OS_CFG"

  has_valid_folder=false
  for folder in "${OLD_FOLDERS[@]}"; do
    match=$(find "$MOUNT_POINT" -maxdepth 1 -type d -iname "$folder" | head -n1)
    if [[ -n "$match" ]]; then
      has_valid_folder=true
      break
    fi
  done

  if $has_valid_folder; then
    dialog --infobox "Moving old OS files and folders to Windows.old folder..." 3 62
    WINDOWS_OLD_DIR=$(find "$MOUNT_POINT" -maxdepth 1 -type d -iname "Windows.old" | head -n1)

    if [[ -n "$WINDOWS_OLD_DIR" ]]; then
      i=1
      while true; do
        if (( i <= 999 )); then
          suffix=$(printf "%03d" "$i")   # 001..999
        else
          suffix="$i"                    # 1000, 1001, ...
        fi
        NEW_DIR="$MOUNT_POINT/Windows.$suffix"

        if [[ ! -d "$NEW_DIR" ]]; then
          sudo mv "$WINDOWS_OLD_DIR" "$NEW_DIR"
          break
        fi
        ((i++))
      done
    fi
	
    sudo mkdir -p "$MOUNT_POINT/Windows.old"

    for folder in "${OLD_FOLDERS[@]}"; do
      SRC=$(find "$MOUNT_POINT" -maxdepth 1 -type d -iname "$folder" | head -n1)
      if [[ -n "$SRC" ]]; then
        DEST="$MOUNT_POINT/Windows.old/$(basename "$SRC")"
        sudo mkdir -p "$(dirname "$DEST")"
        sudo mv "$SRC" "$DEST"
      fi
    done
  fi
fi

# === Show progress dialog while extracting ===
dialog --infobox "Setup is copying OS files to install partition, please wait..." 3 68

if ! wimlib-imagex apply "$WIM_FILE_PATH" "$WIM_FILE_INDEX" "$MOUNT_POINT" --include-invalid-names >/dev/null 2>&1; then
  dialog --title "Setup Error" --msgbox "ERROR: Files could not be copied!\n\nSetup has failed!" 8 60
  
  # === Unmount partitions ===
  [[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount "$TEMP_BOOT" 2>/dev/null
  sudo umount "$MOUNT_POINT" 2>/dev/null
  
  exit 1
fi
sync

if [[ "$SETUP_TYPE" -eq 1 ]]; then
  declare -a SYS_DIRS=()

  # Scan all folders
  for dir in "$MOUNT_POINT"/*/; do
    # Check if it's a directory
    if [[ -d "$dir" ]]; then
      # Find the system32 folder (case-insensitive)
      SYS32_DIR=$(ls -d "$dir/"* 2>/dev/null | grep -i '/system32$' | head -n1)

      # Check if system32 folder exists
      if [[ -n "$SYS32_DIR" ]]; then
        # Loop through kernel and/or hal file(s) (case-insensitive) and break on first match
        for f in "$SYS32_DIR"/*; do
          fname=$(basename "$f" | tr '[:upper:]' '[:lower:]')
          if [[ "$fname" == "ntoskrnl.exe" || "$fname" == "ntkrnlpa.exe" || "$fname" == "ntkrnlmp.exe" || "$fname" == "ntkrpamp.exe" || "$fname" == "hal.dll" ]]; then
            SYS_DIRS+=("$(basename "$dir")")
            break
          fi
        done
      fi
    fi
  done

  # Count found folders
  count=${#SYS_DIRS[@]}

  if [[ $count -eq 0 ]]; then
    dialog --msgbox "ERROR: No Windows System root folder found!\n\nSetup aborted!" 7 47
	
	# === Unmount partitions ===
    [[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount "$TEMP_BOOT" 2>/dev/null
    sudo umount "$MOUNT_POINT" 2>/dev/null
	
    exit 1
  elif [[ $count -eq 1 ]]; then
    SYS_DIR="${SYS_DIRS[0]}"
  else
    # Prepare dialog menu for multiple options
    MENU_OPTIONS=()
    for i in "${!SYS_DIRS[@]}"; do
      MENU_OPTIONS+=("$i" "${SYS_DIRS[$i]}")
    done

    CHOICE=$(dialog --clear --nocancel \
      --title "Choose correct system root folder" \
      --menu "Select the correct Windows system root folder:" 15 50 $count \
      "${MENU_OPTIONS[@]}" \
      3>&1 1>&2 2>&3)

    # Get selected folder
    SYS_DIR="${SYS_DIRS[$CHOICE]}"
  fi
fi

if [[ -z "$SYS_DIR" ]]; then
  dialog --msgbox "ERROR: No Windows system root folder found!\n\nSetup aborted!" 7 47
  
  # === Unmount partitions ===
  [[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount "$TEMP_BOOT" 2>/dev/null
  sudo umount "$MOUNT_POINT" 2>/dev/null
  
  exit 1
fi

IS_APPLETV=$(check_appletv)

if [[ "$IS_APPLETV" == "No" ]]; then
  # === Apply ACPI Patch ==
  ACPI_SRC=""
  BASE_DIR="/mnt/isofiles/drivers/patched/ACPI"

  if [[ "$EDITION_DESC" == *"2000"* && "$EDITION_DESC" == *"Patched"* ]]; then
    ACPI_SRC=$(find "$BASE_DIR/NT50" -maxdepth 1 -type f -iname "acpi.sys" | head -n1)
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 86 && "$EDITION_DESC" == *"NT 5.1 Patched"* ]]; then
    ACPI_SRC=$(find "$BASE_DIR/NT51" -maxdepth 1 -type f -iname "acpi.sys" | head -n1)
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 86 && "$EDITION_DESC" == *"NT 5.2 Patched"* ]]; then
    ACPI_SRC=$(find "$BASE_DIR/NT52x86" -maxdepth 1 -type f -iname "acpi.sys" | head -n1)
  elif [[ "$EDITION_DESC" =~ Windows\ XP && "$EDITION_DESC" =~ 64 && "$EDITION_DESC" == *"Patched"* ]]; then
    ACPI_SRC=$(find "$BASE_DIR/NT52x64" -maxdepth 1 -type f -iname "acpi.sys" | head -n1)
  fi

  if [[ -n "$ACPI_SRC" && -f "$ACPI_SRC" ]]; then
    DRIVERS_DIR=$(find "$MOUNT_POINT/$SYS_DIR" -type d -ipath "*/system32/drivers" | head -n1)

    if [[ -n "$DRIVERS_DIR" ]]; then
      ACPI_FILE=$(find "$DRIVERS_DIR" -maxdepth 1 -type f -iname "acpi.sys" | head -n1)

      if [[ -n "$ACPI_FILE" ]]; then
        sudo mv "$ACPI_FILE" "$DRIVERS_DIR/acpi.rsc" 2>/dev/null
      fi

      sudo cp "$ACPI_SRC" "$DRIVERS_DIR/"
    fi
  fi

  if [[ "$SETUP_TYPE" -eq 1 ]]; then
    # NTLDR selection menu for custom install
    NTLDR_SELECTED=$(dialog --clear --nocancel \
      --title "NTLDR Selection" \
      --menu "Which NTLDR type do you want to use?\n\nNOTE: If you are installing Windows XP or 2003, select 'Windows XP NTLDR'.\nFor Windows 2000 or older NT versions, select 'Windows 2000 NTLDR'." \
      14 72 2 \
      1 "Windows XP NTLDR" \
      2 "Windows 2000 NTLDR" \
      3>&1 1>&2 2>&3)

    if [[ "$NTLDR_SELECTED" -eq 1 ]]; then
      LDR_FILE="cmxpldr"
    TITLE="Windows XP/2003 Custom WIM"
    elif [[ "$NTLDR_SELECTED" -eq 2 ]]; then
      LDR_FILE="cm2kldr"
    TITLE="Windows NT3/NT4/2000 Custom WIM"
    fi
  fi

  # === Copy bootloader files ===
  sudo cp -f "/mnt/isofiles/bootldr/$LDR_FILE" "$TEMP_BOOT/$LDR_FILE"
  sudo cp -f /mnt/isofiles/bootldr/GRLDR "$TEMP_BOOT/"
  sudo cp -f /mnt/isofiles/bootldr/NTDETECT.COM "$TEMP_BOOT/"

  # === Confirmation before bootloader update ===
  dialog --yesno "WARNING!\n\nSetup will be install the Grub4dos MBR on $DISK.\nThis may overwrite the existing MBR.\n\nNOTE: If you choose 'No', you have to install Grub4dos later which is essential for NT booting!\n\nDo you want to continue?" 13 80

  # === Update bootloader ===
  if [[ $? -eq 0 ]]; then
    # User selected Yes → install MBR
    if [[ -f /tmp/files/bootldr/bootlace.com ]]; then
      dialog --infobox "Setup is updating MBR..." 4 27
    
      chmod 777 /tmp/files/bootldr/bootlace.com
      if sudo /tmp/files/bootldr/bootlace.com "$DISK" >/dev/null 2>&1; then
        :
      else
        dialog --msgbox "ERROR: Failed to update MBR on $DISK!\n\nYou have to install Grub4dos manually!" 7 75
      fi
    else
      dialog --msgbox "ERROR: bootlace.com not found!" 5 50
    fi
  fi

  sudo parted "$DISK" set "$BOOT_PART_NUM" boot on >/dev/null 2>&1

  # === Show dialog for boot menu updates ===
  dialog --infobox "Setup is adding/editing boot menu entries..." 4 45

  # === Update boot.ini ===
  BOOTINI_EXISTING="$TEMP_BOOT/$INI_FILE"
  BOOTINI_NEW="/mnt/isofiles/bootldr/$INI_FILE"
  DISK_NUM=$(get_disk_number)
  BOOTINI_PART_NUM=0

  if [[ "$OS_CODE" =~ XP ]] || [[ "$SETUP_TYPE" -eq 1 ]]; then
    BOOTINI_EXISTING="$TEMP_BOOT/boot.ini"
  fi

  if [[ "$SETUP_TYPE" -eq 1 ]]; then
    BOOTINI_NEW="/mnt/isofiles/bootldr/cmbt.ini"
  elif [[ "$SETUP_TYPE" -eq 0 ]]; then
    if [[ "$EDITION_DESC" == *"2000"* && "$EDITION_DESC" == *"Patched"* ]]; then
      BOOTINI_NEW="/mnt/isofiles/bootldr/bt2kp.ini"
    elif [[ "$OS_CODE" == "XP86" && "$EDITION_DESC" == *"NT 5.1 Patched"* ]]; then
      BOOTINI_NEW="/mnt/isofiles/bootldr/xp86p51p.ini"
    elif [[ "$OS_CODE" == "XP86" && "$EDITION_DESC" == *"NT 5.2 Patched"* ]]; then
      BOOTINI_NEW="/mnt/isofiles/bootldr/xp86p52p.ini"
    elif [[ "$OS_CODE" == "XP64" && "$EDITION_DESC" == *"Patched"* ]]; then
      BOOTINI_NEW="/mnt/isofiles/bootldr/xp64pp.ini"
    fi
  fi

  # Get partition number for the boot.ini path
  read BOOTINI_PART_NUM < <(get_bootini_number "$DISK" "$OS_PART_NAME")

  if [[ -f "$BOOTINI_EXISTING" ]]; then
    # Read all ARC paths from the new file
    NEW_PATHS=()
    while IFS= read -r line; do
      NEW_PATHS+=("$line")
    done < <(sudo grep -Ei '^(multi|scsi)\([0-9]+\)' "$BOOTINI_NEW")

    if (( ${#NEW_PATHS[@]} == 0 )); then
      dialog --msgbox "ERROR: Setup could not add/edit boot entries!\n\nSetup aborted!" 7 75
    
      # === Unmount partitions ===
      [[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount "$TEMP_BOOT" 2>/dev/null
      sudo umount "$MOUNT_POINT" 2>/dev/null
    
      exit 1
    fi

    # Delete old OS paths from existing ini file
    sudo sed -i -E "/^(multi\(0\)|scsi\(0\))disk\(0\)rdisk\($DISK_NUM\)partition\($BOOTINI_PART_NUM\)/d" "$BOOTINI_EXISTING"
  
    # Create full list of modified new lines
    MODIFIED_LINES=()
    for newline in "${NEW_PATHS[@]}"; do
      CLEAN_LINE=$(echo "$newline" | sed -E 's/ *\(disk [0-9]+ part [0-9]+\)//')
      MOD_LINE=$(echo "$CLEAN_LINE" | sed -E "s/partition\([0-9]+\)/partition($BOOTINI_PART_NUM)/" | \
        sed -E "s/\"(.*)\"/\1 (disk $DISK_NUM part $BOOTINI_PART_NUM)\"/")

      if [[ "$SETUP_TYPE" -eq 1 ]]; then
        MOD_LINE=$(echo "$MOD_LINE" | sed -E "s#(\\\\)[^=]*=(.*)#\1$SYS_DIR=\"\2#")
      fi

      MODIFIED_LINES+=("$MOD_LINE")
    done

    TMP_FILE=$(mktemp)
    INSIDE_OS_SECTION=0
    OLD_OS_LINES=()

    while IFS= read -r line; do
      # Remove CR character if present (from Windows line endings)
      line=${line%$'\r'}
    
      # Write the new default system path to the default line 
      if [[ "${line,,}" == default=* ]]; then
        line="${line%%\\*}\\$SYS_DIR"
      fi

      # Detect [operating systems] section header (case-insensitive)
      if [[ "${line,,}" == "[operating systems]" ]]; then
        INSIDE_OS_SECTION=1
        printf '%s\r\n' "$line" >> "$TMP_FILE"

        # Write new lines first
        for mod in "${MODIFIED_LINES[@]}"; do
          printf '%s\r\n' "$mod" >> "$TMP_FILE"
        done

        # Then old lines directly after new ones (same block)
        for old in "${OLD_OS_LINES[@]}"; do
          printf '%s\r\n' "$old" >> "$TMP_FILE"
        done

        continue
      fi

      # If inside [operating systems] section but a new section begins
      if [[ $INSIDE_OS_SECTION -eq 1 && "$line" =~ ^\[.*\]$ ]]; then
        INSIDE_OS_SECTION=0
        printf '%s\r\n' "$line" >> "$TMP_FILE"
        continue
      fi

      # Collect existing lines inside the [operating systems] section
      if [[ $INSIDE_OS_SECTION -eq 1 ]]; then
        OLD_OS_LINES+=("$line")
        continue
      fi

        # All other lines are copied directly
      printf '%s\r\n' "$line" >> "$TMP_FILE"
    done < "$BOOTINI_EXISTING"

    # In case file ends inside OS section, append old lines
    if [[ $INSIDE_OS_SECTION -eq 1 ]]; then
      for old in "${OLD_OS_LINES[@]}"; do
        printf '%s\r\n' "$old" >> "$TMP_FILE"
      done
    fi

    # Apply the updated file
    sudo cp "$TMP_FILE" "$BOOTINI_EXISTING"
    rm "$TMP_FILE"
  else
    TMP_BOOTINI=$(mktemp)
    sudo cp "$BOOTINI_NEW" "$TMP_BOOTINI"

    if [[ "$SETUP_TYPE" -eq 1 ]]; then
    sudo sed -i -E "s#(default=.*\\\\)[^[:space:]]*#\1${SYS_DIR//\\/\\\\}#g" "$TMP_BOOTINI"
      sudo sed -i -E "s#^(.*\\\\)[^=]*=#\1${SYS_DIR//\\/\\\\}=\"#g" "$TMP_BOOTINI"
    elif [[ "$SETUP_TYPE" -eq 0 ]]; then
      :
    fi
    
    sudo cp -f "$TMP_BOOTINI" "$BOOTINI_EXISTING"
    sudo rm -f "$TMP_BOOTINI"
    
    sudo sed -i -E "s/partition\([0-9]+\)/partition($BOOTINI_PART_NUM)/g" "$BOOTINI_EXISTING"
    sudo sed -i -E "s/\"(.*)\"/\1 (disk $DISK_NUM part $BOOTINI_PART_NUM)\"/" "$BOOTINI_EXISTING"
  fi

  awk -v partnum="$BOOTINI_PART_NUM" '
  { if ($0 ~ /^default=.*partition\([0-9]+\)/) gsub(/partition\([0-9]+\)/, "partition(" partnum ")"); print }
  ' "$BOOTINI_EXISTING" > /tmp/bootini.tmp && sudo mv /tmp/bootini.tmp "$BOOTINI_EXISTING"

  # Get system support status
  ACPI_SUPPORT=$(check_acpi)
  APIC_SUPPORT=$(check_apic)
  PAE_SUPPORT=$(check_pae)
  MPS_SUPPORT=$(check_mps)

  # Remove MPS lines if system does not support MPS (NT 3.50 supports only MPS Revision 1.1)
  if [[ "$MPS_SUPPORT" == "No" || ( "$OS_CODE" == "NT350" && "$MPS_SUPPORT" != "1.1" ) ]]; then
    sed -i '/MPS/d' "$BOOTINI_EXISTING"
  fi

  # Remove ACPI lines if system does not support ACPI
  if [[ "$ACPI_SUPPORT" == "No" ]]; then
    sed -i '/ACPI/d' "$BOOTINI_EXISTING"
  fi

  # Remove APIC and MPS lines if system does not support APIC
  if [[ "$APIC_SUPPORT" == "No" ]]; then
    sed -i '/APIC/d' "$BOOTINI_EXISTING"
    sed -i '/MPS/d' "$BOOTINI_EXISTING"
  fi

  # Remove PAE lines if system does not support PAE
  if [[ "$PAE_SUPPORT" == "No" ]]; then
    sed -i '/\/PAE/d' "$BOOTINI_EXISTING"
  fi

  # Convert to Windows-style line endings (CRLF)
  sudo unix2dos "$BOOTINI_EXISTING"

  # === Update GRUB menu.lst ===
  G4D_ROOT_DISK_NUM=0
  G4D_ROOT_PART_NUM=$((BOOT_PART_NUM - 1))
  MENU_LST="$TEMP_BOOT/menu.lst"
  ROOT_LINE="root (hd$G4D_ROOT_DISK_NUM,$G4D_ROOT_PART_NUM)"
  MAKEACTIVE_LINE="makeactive"
  CHAINLOADER_LINE="chainloader /$LDR_FILE"

  read -r -d '' NEW_ENTRY <<EOF

title $TITLE
$ROOT_LINE
$MAKEACTIVE_LINE
$CHAINLOADER_LINE

EOF

  [[ ! -f "$MENU_LST" ]] && echo -e "timeout 10\n" | sudo tee "$MENU_LST" >/dev/null

  if ! grep -i -q "^title[[:space:]]\+$TITLE[[:space:]]*$" <(tr -d '\r' < "$MENU_LST"); then
    echo -e "$NEW_ENTRY\n" | sudo tee -a "$MENU_LST" >/dev/null
  fi

  sudo sed -i 's/$/\r/' "$MENU_LST"

fi
if [[ "$IS_APPLETV" == "Yes" ]]; then
  # On Apple TV, we have a bundled 'freeldr.ini' and FreeLoader, so we don't need to do any configuration. We also only have one HAL option because we only need one.
  dialog --infobox "Setup is copying Apple TV files..." 4 45
  sudo cp -fr /mnt/isofiles/bootldr/appletv/* $TEMP_BOOT
  
  # Set the OS partition to bootable so that FreeLoader can find it.
  sudo parted "$DISK" set "$OS_PART_NUM" boot on >/dev/null 2>&1
  
fi # IS_APPLETV

if [[ "$SETUP_TYPE" -eq 1 ]]; then
  # Registry Assign Drive Letter Patch - OS Selection for Custom Install
  REG_OS_SELECTED=$(dialog --clear --nocancel \
    --title "Registry Drive Letter Patch" \
    --menu "Please select the target OS for Registry Assign Drive Letter patching." \
    11 70 3 \
    1 "Windows 2000, XP or 2003" \
    2 "Windows NT 3.5x or NT 4.0" \
    3 "Windows NT 3.1 or Skip Patching" \
    3>&1 1>&2 2>&3)

  # Assign variable based on selection
  if [[ "$REG_OS_SELECTED" -eq 1 ]]; then
    OS_CODE="XP"
  elif [[ "$REG_OS_SELECTED" -eq 2 ]]; then
    OS_CODE="NT4"
  elif [[ "$REG_OS_SELECTED" -eq 3 ]]; then
    OS_CODE="NT31"
  fi
fi

# === Registry patch ===
SYSTEM_HIVE=$(find "$MOUNT_POINT/$SYS_DIR" -type f -iname "system" -ipath "*/config/*" -ipath "*/system32/*" 2>/dev/null | head -n 1)

if [[ -z "$SYSTEM_HIVE" || ! -f "$SYSTEM_HIVE" ]]; then
  dialog --msgbox "Could not locate SYSTEM registry hive (system32/config/system)!\nSetup will skip letter assigning." 6 60
else
  # Skip registry patch steps silently for NT 3.1
  if [[ "$OS_CODE" == *NT31* ]]; then
    :
  else
    dialog --infobox "Setup is assigning correct letter for selected partition in registry..." 4 68
	
	#  printf '\xD1\xAD\xD1\xAD' | dd of="$DISK" bs=1 seek=440 count=4 conv=notrunc
    sync
	sleep 0.1

    SIG_HEX=$(dd if="$DISK" bs=1 skip=440 count=4 2>/dev/null | hexdump -v -e '/1 "%02x "' | sed 's/ $//')
    START_SECTOR=$(cat /sys/block/$(basename "$DISK")/$(basename "$OS_PART_NAME")/start)
    SECTOR_SIZE=$(sudo cat /sys/block/$(basename "$DISK")/queue/logical_block_size 2>/dev/null)
	[[ -z "$SECTOR_SIZE" || "$SECTOR_SIZE" -le 0 ]] && SECTOR_SIZE=512  # Default fallback
    OFFSET=$((START_SECTOR * SECTOR_SIZE))

    OFFSET_HEX=""
    for ((i=0; i<8; i++)); do
      BYTE=$(((OFFSET >> (8*i)) & 0xFF))
      OFFSET_HEX+=$(printf "%02x " "$BYTE")
    done

    SIG_HEX_CSV=$(echo "$SIG_HEX" | sed 's/ /,/g')
    OFFSET_HEX_CSV=$(echo "$OFFSET_HEX" | sed 's/ /,/g')
    FULL_HEX="${SIG_HEX_CSV},${OFFSET_HEX_CSV}"
    FULL_HEX="${FULL_HEX%,}"

    TMP_HIVE="/tmp/SYSTEM_hive_copy"
    sudo cp "$SYSTEM_HIVE" "$TMP_HIVE"

    BOOT_PART=$(make_partition_path "/dev/$DISK_DEVICE" "$BOOT_PART_NUM")
    INSTALL_PART="$OS_PART_NAME"

    if [[ "$OS_CODE" == *NT3* || "$OS_CODE" == *NT4* ]]; then
      DISK_INDEX=0
      PART_INDEX="$BOOTINI_PART_NUM"
      HARD_DISK="\\\\Device\\\\Harddisk${DISK_INDEX}\\\\Partition${PART_INDEX}"

      cat <<EOF > /tmp/ntdosdev.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Control\\Session Manager\\DOS Devices]
"C:"="$HARD_DISK"
EOF

      if [[ "$BOOT_PART" != "$INSTALL_PART" ]]; then
        cat <<EOF >> /tmp/ntdosdev.reg
"W:"="\\\\Device\\\\Harddisk0\\\\Partition1"
EOF
      fi

      reged -I "$TMP_HIVE" "HKEY_LOCAL_MACHINE\\SYSTEM" /tmp/ntdosdev.reg -C >/dev/null 2>&1

    elif [[ "$OS_CODE" == *2000* || "$OS_CODE" == *XP* ]]; then
	
      cat <<EOF > /tmp/mntdev.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\MountedDevices]
"\\\\DosDevices\\\\C:"=hex:$FULL_HEX

[HKEY_LOCAL_MACHINE\\SYSTEM\\Setup]
"BootDiskSig"=dword:00000000
EOF

      reged -I "$TMP_HIVE" "HKEY_LOCAL_MACHINE\\SYSTEM" /tmp/mntdev.reg -C >/dev/null 2>&1
    fi

    sudo cp "$TMP_HIVE" "$SYSTEM_HIVE"
  fi
fi

# === Unmount partitions ===
[[ "$TEMP_BOOT" != "$MOUNT_POINT" ]] && sudo umount "$TEMP_BOOT" 2>/dev/null
sudo umount "$MOUNT_POINT" 2>/dev/null

# === Final dialog ===
while true; do
  dialog --nocancel --menu "Installation completed successfully on $OS_PART_NAME.\n\nChoose next action:" 11 60 2 \
    1 "Reboot the Computer" \
    2 "Go Back to Main Menu" 2>/tmp/choice

  CHOICE=$(cat /tmp/choice)
  case "$CHOICE" in
    1) exit 5 ;;
    2) exit 0 ;;
  esac
done
