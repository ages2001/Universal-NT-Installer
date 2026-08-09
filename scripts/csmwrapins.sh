#!/bin/bash

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

declare -a DISK_MENU=()
declare -A DISK_INFO=()

source "./scripts/diskinfo.sh"

while true; do
  DISK_MENU=()
  DISK_INFO=()
  
  scan_disks "$INSTLR_DEVICE"

  # 1. Target Disk Selection
  DISK_SELECTED=$(dialog --clear --backtitle "CSMWrap Installer" \
    --title "Select Target Disk" \
    --menu "Choose target disk to install CSMWrap boot payload:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)
  
  # Return gracefully to previous menu (tools.sh) on Cancel / ESC
  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 0
  
  # --- CRITICAL CHECK: Verify if the disk label type is strictly MBR or GPT via diskinfo.sh map ---
  IS_MBR_OR_GPT="${DISK_INFO["$DISK_SELECTED,type"]}"

  if [[ "$IS_MBR_OR_GPT" != "MBR" && "$IS_MBR_OR_GPT" != "MSDOS" && "$IS_MBR_OR_GPT" != "GPT" ]]; then
    dialog --msgbox "Error: The selected disk format is ${IS_MBR_OR_GPT:-UNKNOWN}!\n\nCSMWrap Installer Tool can only be performed on MBR or GPT partition tables." 8 67
    continue
  fi

  # 2. Verify Presence of FAT12 / FAT16 / FAT32 Partition on Selected Disk
  part_prefix="$DISK_SELECTED"
  [[ "$DISK_SELECTED" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]] && part_prefix="${DISK_SELECTED}p"

  # Safe device lookup for blkid
  FAT_PARTITION=$(sudo blkid -o device -t TYPE="vfat" ${part_prefix}[0-9]* 2>/dev/null | head -n1)
  [[ -z "$FAT_PARTITION" ]] && FAT_PARTITION=$(sudo blkid -o device ${part_prefix}[0-9]* 2>/dev/null | grep -iE "fat12|fat16|fat32|vfat" | head -n1)

  if [[ -z "$FAT_PARTITION" ]]; then
    dialog --clear --backtitle "CSMWrap Installer" \
      --title "Error: No FAT Partition" \
      --msgbox "No FAT12/FAT16/FAT32 partition found on disk ($DISK_SELECTED)!\n\nCSMWrap requires a FAT12/16/32 partition to deploy boot files." 9 65
    continue # Prompt error and loop back to target disk selection
  fi

  # 3. Confirmation Dialog
  dialog --clear --backtitle "CSMWrap Installer" \
    --title "Confirm Installation" \
    --yesno "Are you sure you want to install CSMWrap on disk $DISK_SELECTED?\n\nTarget FAT Partition: $FAT_PARTITION\n\nExisting files will be preserved. Do you want to proceed?" 11 70
  
  # Return to disk selection if 'No' or Cancel is selected
  [[ $? -ne 0 ]] && continue

  # 4. Installation & EFI Backup Sequence
  dialog --infobox "Deploying CSMWrap payload on $FAT_PARTITION..." 3 50

  target_mount="/tmp/csmwrap_target_mnt"
  sudo mkdir -p "$target_mount"
  
  INSTALL_STATUS=1

  if sudo mount "$FAT_PARTITION" "$target_mount" 2>/dev/null; then
    
    # --- EFI FOLDER ROTATION BACKUP ENGINE ---
    efi_dir=$(sudo find "$target_mount" -maxdepth 1 -type d -iname "EFI" 2>/dev/null | head -n1)

    if [[ -n "$efi_dir" && -d "$efi_dir" ]]; then
      old_efi="$target_mount/EFI.old"
      if [[ -e "$old_efi" ]]; then
        idx=1
        while true; do
          if (( idx <= 999 )); then
            suffix=$(printf "%03d" "$idx")
          else
            suffix="$idx"
          fi
          new_old="$target_mount/EFI.$suffix"
          if [[ ! -e "$new_old" ]]; then
            old_efi="$new_old"
            break
          fi
          ((idx++))
        done
      fi
      sudo mv -f "$efi_dir" "$old_efi" 2>/dev/null
    fi

    # Create target EFI/Boot directory structure
    sudo mkdir -p "$target_mount/EFI/Boot" 2>/dev/null

    # --- CSMWRAP PAYLOAD DEPLOYMENT BLOCK ---
    csm_src_dir="./bootldr/csmwrap"
    copy_success=false

    # 1. IA32 Architecture Payload
    if [[ -f "$csm_src_dir/csmwrapia32.efi" ]]; then
      if sudo cp -f "$csm_src_dir/csmwrapia32.efi" "$target_mount/EFI/Boot/bootia32.efi" 2>/dev/null; then
        copy_success=true
      fi
    fi

    # 2. X64 Architecture Payload
    if [[ -f "$csm_src_dir/csmwrapx64.efi" ]]; then
      if sudo cp -f "$csm_src_dir/csmwrapx64.efi" "$target_mount/EFI/Boot/bootx64.efi" 2>/dev/null; then
        copy_success=true
      fi
    fi

    if [[ "$copy_success" == true ]]; then
      INSTALL_STATUS=0
    else
      INSTALL_STATUS=1
    fi
    # ----------------------------------------

    sudo umount "$target_mount" 2>/dev/null
  fi
  sudo rm -rf "$target_mount" 2>/dev/null

  if [[ $INSTALL_STATUS -eq 0 ]]; then
    dialog --msgbox "Success: CSMWrap installed successfully on $FAT_PARTITION!" 7 60
  else
    dialog --msgbox "Error: Failed to write CSMWrap payload or mount $FAT_PARTITION!" 7 65
  fi

  break
done
