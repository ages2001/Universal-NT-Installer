#!/bin/bash

dialog --infobox "Setup is in progress..." 3 27

# === Initialization ===
OS_PART_NAME="$1"
ARCHIVE_FILE="$2"
OS_PART_NUM="$3"
BOOT_PART_NUM="$4"
OS_CODE="$5"
EDITION_DESC="$6"

if [[ -z "$OS_PART_NAME" || -z "$ARCHIVE_FILE" || -z "$OS_PART_NUM" || -z "$BOOT_PART_NUM" || -z "$OS_CODE" || -z "$EDITION_DESC" ]]; then
  dialog --msgbox "Missing required arguments!" 7 50
  exit 1
fi

MOUNT_POINT="/mnt/install_part"
ARCHIVE_PATH="/mnt/isofiles/osfiles/$ARCHIVE_FILE"
CFG_FILE="/mnt/isofiles/os_dir.cfg"

# === Parse OS Config ===
CFG_LINE=$(grep "^$OS_CODE=" "$CFG_FILE")
IFS=',' read -r LDR_FILE INI_FILE SYS_DIR TITLE <<< "$(echo "$CFG_LINE" | cut -d'=' -f2)"

# === Detect disk and partition numbers ===
DISK_DEVICE=$(lsblk -no PKNAME "$OS_PART_NAME")
DISK="/dev/$DISK_DEVICE"
DISK_BASENAME=$(basename "$DISK_DEVICE")

# === Helper function to build partition device path correctly for NVMe and others ===
make_partition_path() {
  local disk="$1"
  local partnum="$2"
  if [[ "$disk" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
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
    sudo mount -t ntfs3 "$part" "$mountpoint" >/dev/null 2>&1
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

BOOT_PART_NAME=$(make_partition_path "$DISK" "$BOOT_PART_NUM")

# Unhide partitions if flagged hidden
# unhide_partition "$DISK" "$BOOT_PART_NUM" // obsolete because boot partition can hidden and system can boot from hidden partition
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
[[ ! -f "$ARCHIVE_PATH" ]] && dialog --msgbox "Archive not found: $ARCHIVE_PATH" 7 50 && exit 1

# === Move old OS folders to Windows.old if config exists ===
OLD_OS_CFG="/mnt/isofiles/old_os_folders.cfg"
if [[ -f "$OLD_OS_CFG" ]]; then
  IFS=':' read -ra OLD_FOLDERS < "$OLD_OS_CFG"

  has_valid_folder=false
  for folder in "${OLD_FOLDERS[@]}"; do
    if [[ -d "$MOUNT_POINT/$folder" ]]; then
      has_valid_folder=true
      break
    fi
  done

  if $has_valid_folder; then
    WINDOWS_OLD_DIR="$MOUNT_POINT/Windows.old"
    sudo mkdir -p "$WINDOWS_OLD_DIR"
    dialog --infobox "Moving old OS files and folders to Windows.old folder..." 3 62

    for folder in "${OLD_FOLDERS[@]}"; do
      SRC="$MOUNT_POINT/$folder"
      DEST="$WINDOWS_OLD_DIR/$folder"
      if [[ -d "$SRC" ]]; then
        sudo mkdir -p "$(dirname "$DEST")"
        sudo mv "$SRC" "$DEST"
      fi
    done
  fi
fi

# === Show progress dialog while extracting ===
dialog --infobox "Setup is copying OS files to install partition, please wait..." 3 68

sudo tar -xzf "$ARCHIVE_PATH" -C "$MOUNT_POINT"
sync

if [[ "$OS_CODE" == "XP86P" && "$EDITION_DESC" =~ Patched ]]; then
  PATCH_ARCHIVE="/mnt/isofiles/osfiles/XP86PP.tar.gz"
  if [[ -f "$PATCH_ARCHIVE" ]]; then
    #  dialog --infobox "Applying additional XP x86 patch files..." 3 50
    sudo tar -xzf "$PATCH_ARCHIVE" -C "$MOUNT_POINT"
    sudo rm -f "$MOUNT_POINT/$SYS_DIR/setupapi.log"
    sync
  fi
elif [[ "$OS_CODE" == "XP64P" && "$EDITION_DESC" =~ Patched ]]; then
  PATCH_ARCHIVE="/mnt/isofiles/osfiles/XP64PP.tar.gz"
  if [[ -f "$PATCH_ARCHIVE" ]]; then
    #  dialog --infobox "Applying additional XP x64 patch files..." 3 50
    sudo tar -xzf "$PATCH_ARCHIVE" -C "$MOUNT_POINT"
    sudo rm -f "$MOUNT_POINT/$SYS_DIR/setupapi.log"
    sync
  fi
fi

# === Show dialog for bootloader update ===
dialog --infobox "Setup is updating disk boot record and adding/editing menu entries..." 4 70

# === Copy bootloader files ===
sudo cp -f "/mnt/isofiles/bootldr/$LDR_FILE" "$TEMP_BOOT/$LDR_FILE"
sudo cp -f /mnt/isofiles/bootldr/GRLDR "$TEMP_BOOT/"
sudo cp -f /mnt/isofiles/bootldr/NTDETECT.COM "$TEMP_BOOT/"
[[ -f /mnt/isofiles/bootldr/bootlace.com ]] && sudo /mnt/isofiles/bootldr/bootlace.com "$DISK" >/dev/null 2>&1
sudo parted "$DISK" set "$BOOT_PART_NUM" boot on >/dev/null 2>&1

# === Update boot.ini ===
BOOTINI_EXISTING="$TEMP_BOOT/$INI_FILE"
BOOTINI_NEW="/mnt/isofiles/bootldr/$INI_FILE"
DISK_NUM=$(get_disk_number)
BOOTINI_PART_NUM=0

if [[ "$OS_CODE" =~ XP ]]; then
  BOOTINI_EXISTING="$TEMP_BOOT/boot.ini"
fi

# Enable case-insensitive matching
shopt -s nocasematch

# Get partition number for the boot.ini path
read BOOTINI_PART_NUM < <(get_bootini_number "$DISK" "$OS_PART_NAME")

if [[ -f "$BOOTINI_EXISTING" ]]; then
  # Read all ARC paths from the new file
  mapfile -t NEW_PATHS < <(grep -Ei '^(multi|scsi)\([0-9]+\)' "$BOOTINI_NEW")

  if (( ${#NEW_PATHS[@]} == 0 )); then
    exit 1
  fi

  # Prepare WIN_PATH check to avoid duplication
  CLEAN=$(echo "${NEW_PATHS[0]}" | sed -E 's/ *\(disk [0-9]+ partition [0-9]+\)//')
  MODIFIED=$(echo "$CLEAN" | sed -E "s/partition\([0-9]+\)/partition($BOOTINI_PART_NUM)/" | \
    sed -E "s/\"(.*)\"/\1 (disk $DISK_NUM partition $BOOTINI_PART_NUM)\"/")
  WIN_PATH=$(echo "$MODIFIED" | sed -E 's/(^(multi|scsi)\([0-9]+\).*partition\([0-9]+\)\\[^=]+)=.*/\1=/')

  if ! grep -qF "$WIN_PATH" "$BOOTINI_EXISTING"; then
    # Create full list of modified new lines
    MODIFIED_LINES=()
    for newline in "${NEW_PATHS[@]}"; do
      CLEAN_LINE=$(echo "$newline" | sed -E 's/ *\(disk [0-9]+ partition [0-9]+\)//')
      MOD_LINE=$(echo "$CLEAN_LINE" | sed -E "s/partition\([0-9]+\)/partition($BOOTINI_PART_NUM)/" | \
        sed -E "s/\"(.*)\"/\1 (disk $DISK_NUM partition $BOOTINI_PART_NUM)\"/")
      MODIFIED_LINES+=("$MOD_LINE")
    done

    TMP_FILE=$(mktemp)
    INSIDE_OS_SECTION=0
    OLD_OS_LINES=()

    while IFS= read -r line; do
      # Remove CR character if present (from Windows line endings)
      line=${line%$'\r'}

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
  fi
else
  sudo cp -f "$BOOTINI_NEW" "$BOOTINI_EXISTING"
  sudo sed -i -E "s/partition\([0-9]+\)/partition($BOOTINI_PART_NUM)/g" "$BOOTINI_EXISTING"
  sudo sed -i -E "s/\"(.*)\"/\1 (disk $DISK_NUM partition $BOOTINI_PART_NUM)\"/" "$BOOTINI_EXISTING"
fi

awk -v partnum="$BOOTINI_PART_NUM" '
{ if ($0 ~ /^default=.*partition\([0-9]+\)/) gsub(/partition\([0-9]+\)/, "partition(" partnum ")"); print }
' "$BOOTINI_EXISTING" > /tmp/bootini.tmp && sudo mv /tmp/bootini.tmp "$BOOTINI_EXISTING"

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

    SIG_HEX=$(dd if="$DISK" bs=1 skip=440 count=4 2>/dev/null | hexdump -v -e '/1 "%02x "' | sed 's/ $//')
    START_SECTOR=$(cat /sys/block/$(basename "$DISK")/$(basename "$OS_PART_NAME")/start)
    OFFSET=$((START_SECTOR * 512))

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

    elif [[ "$OS_CODE" == *2K* || "$OS_CODE" == *XP* ]]; then
      cat <<EOF > /tmp/mntdev.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\MountedDevices]
"\\\\DosDevices\\\\C:"=hex:$FULL_HEX
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
  dialog --nocancel --menu "Installation completed successfully on $OS_PART_NAME.\n\nChoose next action:" 12 60 3 \
    1 "Reboot the Computer" \
    2 "Command Line" \
    3 "Install Another OS" 2>/tmp/choice

  CHOICE=$(cat /tmp/choice)
  case "$CHOICE" in
    1) exit 5 ;;
    2)
      clear
      bash
      ;;
    3) exit 0 ;;
  esac
done

