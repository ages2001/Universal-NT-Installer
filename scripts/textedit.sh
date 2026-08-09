#!/bin/bash

# ==============================================================================
# textedit.sh - Partition File Browser & Native Dialog Text Editor Engine
# ==============================================================================

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing installer device argument!" 7 40
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
declare -A PART_SIZE_KB_MAP=()
declare -A PART_NUM_MAP=()

source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"

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

mount_rw_partition() {
  local part="$1"
  local mountpoint="$2"
  local fs=$(get_fs_type "$part")

  sudo mkdir -p "$mountpoint"
  sudo umount -l "$mountpoint" >/dev/null 2>&1

  # NTFS Case Logic
  if [[ "$fs" == "ntfs" ]]; then
    sudo ntfsfix -b -d "$part" >/dev/null 2>&1
    sudo mount -t ntfs3 -o rw,force "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo ntfs-3g -o rw,force "$part" "$mountpoint" >/dev/null 2>&1 \
      || sudo mount -t ntfs -o rw "$part" "$mountpoint" >/dev/null 2>&1
  else
    # General Case: Any other filesystem attempts standard -o rw
    sudo mount -o rw "$part" "$mountpoint" >/dev/null 2>&1
  fi

  # Check if partition is actually mounted
  if sudo mountpoint -q "$mountpoint" 2>/dev/null || grep -qs "$mountpoint" /proc/mounts; then
    sudo chmod 777 "$mountpoint" 2>/dev/null
    local test_file="$mountpoint/.rw_test_file_$$"
    if sudo touch "$test_file" 2>/dev/null; then
      sudo rm -f "$test_file" 2>/dev/null
      return 0
    fi
  fi

  return 1
}

# --- DISK SELECTION LOOP ---
scan_disks "$INSTLR_DEVICE"

while true; do
  DISK_SELECTED=$(dialog --clear --backtitle "Text Editor - Disk Selection" \
    --title "Select Disk" \
    --menu "Choose the target disk to browse:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  # Cancel/ESC in Disk menu -> exit 2 (Returns back to Tools Menu)
  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2

  scan_partitions "$DISK_SELECTED"

  # --- PARTITION SELECTION LOOP ---
  while true; do
    if [[ ${#PART_MENU[@]} -eq 0 ]]; then
      dialog --msgbox "No partitions found on $DISK_SELECTED." 7 50
      break
    fi

    PART_SELECTED_INDEX=$(dialog --clear --backtitle "Text Editor - Partition Selection" \
      --title "Select Partition" \
      --menu "Choose the partition to mount:" 19 80 13 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    local menu_res=$?
    # Cancel/ESC in Partition menu -> returns back to Disk Selection
    if [[ $menu_res -ne 0 || -z "$PART_SELECTED_INDEX" ]]; then
      break
    fi

    # Explicit Partition Path Resolution from Maps
    OS_PART_NAME=""
    if [[ -b "$PART_SELECTED_INDEX" ]]; then
      OS_PART_NAME="$PART_SELECTED_INDEX"
    elif [[ -n "${PART_INDEX_MAP[$PART_SELECTED_INDEX]}" ]]; then
      OS_PART_NAME="${PART_INDEX_MAP[$PART_SELECTED_INDEX]}"
    else
      OS_PART_NAME="$PART_SELECTED_INDEX"
    fi

    if [[ ! -b "$OS_PART_NAME" ]]; then
      dialog --msgbox "Invalid partition device selected:\n$OS_PART_NAME" 7 50
      continue
    fi

    # Clean fixed mountpoint
    TMP_EDIT_MOUNT="/mnt/edit_part"

    dialog --infobox "Attempting Read/Write mount on $OS_PART_NAME..." 3 55
    sleep 1

    # Check R/W mount availability
    if ! mount_rw_partition "$OS_PART_NAME" "$TMP_EDIT_MOUNT"; then
      sudo umount -l "$TMP_EDIT_MOUNT" >/dev/null 2>&1
      sudo rm -rf "$TMP_EDIT_MOUNT" >/dev/null 2>&1
      dialog --msgbox "ERROR: Filesystem on $OS_PART_NAME cannot be mounted as Read/Write or is unsupported!" 8 65
      continue
    fi

    # Initialize current path at the mount root
    CURRENT_BROWSE_PATH="$TMP_EDIT_MOUNT/"

    # --- NATIVE DIALOG FILE SELECTOR LOOP (--fselect) ---
    while true; do
      TARGET_FILE=$(dialog --clear --backtitle "Text Editor - File Selection (Press Space and then Enter to select a file/dir)" \
        --title "Browse Files on $OS_PART_NAME" \
        --fselect "$CURRENT_BROWSE_PATH" 10 60 3>&1 1>&2 2>&3)

      fselect_res=$?
      # Cancel/ESC in File Selection -> returns back to Partition Selection
      if [[ $fselect_res -ne 0 || -z "$TARGET_FILE" ]]; then
        break
      fi

      # Prevent user from escaping the mounted partition tree
      if [[ ! "$TARGET_FILE" =~ ^"$TMP_EDIT_MOUNT" ]]; then
        CURRENT_BROWSE_PATH="$TMP_EDIT_MOUNT/"
        continue
      fi

      # If user selected/entered a directory, normalize path to remove '..' or '.' clutter
      if [[ -d "$TARGET_FILE" ]]; then
        # Resolve path cleanly to get rid of /../ and /./ segments
        REAL_DIR=$(realpath "$TARGET_FILE" 2>/dev/null || readlink -f "$TARGET_FILE" 2>/dev/null)
        
        # Fallback safety if resolution fails
        [[ -z "$REAL_DIR" ]] && REAL_DIR="$TARGET_FILE"
        
        # Ensure trailing slash for directory navigation
        [[ "$REAL_DIR" != */ ]] && REAL_DIR="${REAL_DIR}/"
        
        CURRENT_BROWSE_PATH="$REAL_DIR"
        continue
      fi

      # Check if file exists
      if [[ ! -f "$TARGET_FILE" ]]; then
        dialog --msgbox "The specified file does not exist:\n\n$TARGET_FILE" 7 60
        continue
      fi

      # --- FILE PERMISSION & CONVERSION ENGINE ---
      sudo chmod 777 "$TARGET_FILE" 2>/dev/null

      if [[ ! -w "$TARGET_FILE" ]]; then
        dialog --msgbox "ERROR: File is Read-Only and write permissions (chmod 777) could not be granted!" 7 65
        continue
      fi

      # Check if file originally uses DOS/Windows (CRLF) line endings
      WAS_DOS=0
      if file "$TARGET_FILE" 2>/dev/null | grep -q "CRLF" || grep -q $'\r' "$TARGET_FILE" 2>/dev/null; then
        WAS_DOS=1
        sudo dos2unix "$TARGET_FILE" 2>/dev/null
      fi

      # Open file in Nano editor safely
      sudo nano "$TARGET_FILE"

      # Only convert back to DOS (CRLF) if it was originally a DOS file
      if [[ $WAS_DOS -eq 1 ]]; then
        sudo unix2dos "$TARGET_FILE" 2>/dev/null
      fi
    done

    # Clean unmount on exiting file selector
    sudo umount -l "$TMP_EDIT_MOUNT" >/dev/null 2>&1
    sudo rm -rf "$TMP_EDIT_MOUNT" >/dev/null 2>&1
  done
done
