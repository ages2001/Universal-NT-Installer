#!/bin/bash

# partedit.sh - Select disk, unmount partitions, run cfdisk

INSTLR_DEVICE="$1"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

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

dialog --infobox "Scanning disks..." 3 22

while true; do
  # Step 1: List suitable disks
  declare -a DISK_MENU=()

  for disk_path in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [[ ! -b "$disk_path" ]] && continue
    disk=$(basename "$disk_path")
    type=$(lsblk -dn -o TYPE "$disk_path" 2>/dev/null)
    [[ "$type" != "disk" ]] && continue
    
    # Installer device skipped
    [[ "$(basename "$disk")" == "$(basename "$INSTLDR_DEVICE")" ]] && continue

    size_bytes=$(lsblk -dn -o SIZE -b "$disk_path" 2>/dev/null)
    size_kb=$((size_bytes / 1024))
    if (( size_kb < 1024 )); then
      size=$(awk -v kb="$size_kb" 'BEGIN { printf "%.2f KB", kb }')
    elif (( size_kb < 1024*1024 )); then
      size=$(awk -v kb="$size_kb" 'BEGIN { printf "%.2f MB", kb/1024 }')
    elif (( size_kb < 1024*1024*1024 )); then
      size=$(awk -v kb="$size_kb" 'BEGIN { printf "%.2f GB", kb/1024/1024 }')
    else
      size=$(awk -v kb="$size_kb" 'BEGIN { printf "%.2f TB", kb/1024/1024/1024 }')
    fi

    table_type_raw=$(sudo parted -sm "$disk_path" print 2>/dev/null | awk -F: 'NR==2 {print $6}')
    case "$table_type_raw" in
      msdos) table_type="MBR" ;;
      gpt) table_type="GPT" ;;
      "") table_type="Unknown" ;;
      *) table_type="$table_type_raw" ;;
    esac

    controller=$(get_disk_interface_type "$disk" 2>/dev/null)

    DISK_MENU+=("$disk_path" "Size: $size | Type: $table_type | Cntrlr: $controller")
  done

  if [[ ${#DISK_MENU[@]} -eq 0 ]]; then
    dialog --msgbox "No suitable disks found." 7 50
    exit 1
  fi

  # Step 2: Disk selection
  DISK_SELECTED=$(dialog --clear --backtitle "Disk Selection" \
    --title "Select Target Disk" \
    --menu "Choose the disk to partition:" 15 70 6 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  if [[ $? -ne 0 || -z "$DISK_SELECTED" ]]; then
    exit 1
  fi

  # Step 3: Unmount all mounted partitions on selected disk
  for p in $(lsblk -ln -o NAME "$DISK_SELECTED" | grep -E '[0-9]+$'); do
    mountpoint=$(lsblk -ln -o NAME,MOUNTPOINT "/dev/$p" | awk '$2 != "" {print $1}')
    [[ -n "$mountpoint" ]] && sudo umount "/dev/$p"
  done

  # Step 4: Launch cfdisk
  cfdisk "$DISK_SELECTED"

  # Step 5: Refresh partition table
  if command -v partprobe &>/dev/null; then
    sudo partprobe "$DISK_SELECTED"
  else
    sudo blockdev --rereadpt "$DISK_SELECTED"
  fi
done
