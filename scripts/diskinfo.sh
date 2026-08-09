#!/bin/bash

# Size formatter (Input in KB)
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

  result=$(awk -v v="$result" 'BEGIN {
    split(v, arr, " ")
    val = arr[1]
    unit = arr[2]
    if (val ~ /\./) {
        sub(/\.00$/, "", val)
        if (val ~ /\./) {
            sub(/0$/, "", val)
        }
    }
    if (unit != "") { v = val " " unit } else { v = val }
    print v
  }')
  echo "$result"
}

# Interface type detector using kernel driver tracking as primary method
get_disk_interface_type() {
  local disk="$1"
  local sys_path pci_addr pci_id_short lspci_out kernel_driver final_type
  disk=$(basename "$disk")
  
  if [[ "$disk" == *nvme* ]]; then echo "NVMe"; return; fi
  if [[ "$disk" == *mmc* ]]; then
    if [[ -e "/sys/block/${disk}boot0" || -e "/sys/block/${disk}boot1" ]]; then echo "eMMC"; else echo "SD/MMC"; fi
    return
  fi
  
  sys_path=$(readlink -f "/sys/block/$disk/device" 2>/dev/null)
  [[ -z "$sys_path" ]] && { echo "Unknown"; return; }
  pci_addr=$(echo "$sys_path" | grep -oE '([[:alnum:]]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
  [[ -z "$pci_addr" ]] && { echo "Unknown"; return; }
  pci_id_short="${pci_addr#0000:}"
  
  # Get lspci info once for strict processing
  lspci_out=$(lspci -s "$pci_id_short" -k 2>/dev/null)
  [[ -z "$lspci_out" ]] && { echo "Unknown"; return; }
  
  local lspci_lower=$(echo "$lspci_out" | tr '[:upper:]' '[:lower:]')

  # === Method 1: Primary Check via Kernel Driver in Use ===
  kernel_driver=$(echo "$lspci_out" | grep -i "kernel driver in use:" | awk -F: '{print $2}' | xargs)
  kernel_driver=$(echo "$kernel_driver" | tr '[:upper:]' '[:lower:]')
  
  if [[ -n "$kernel_driver" ]]; then
    case "$kernel_driver" in
      *ahci*)          final_type="AHCI" ;;
      *xhci*)          final_type="USB 3.x" ;;
      *ehci*)          final_type="USB 2.0" ;;
      *ohci*|*uhci*)   final_type="USB 1.x" ;;
      *nvme*)          final_type="NVMe" ;;
      *mpt3sas*|*mpt2sas*|*megaraid*) final_type="RAID" ;;
      *scsi*|*sd_mod*) final_type="SCSI" ;;
      *ata_piix*|*pata*|*ide*) 
        # Fixed: lspci_lower is now correctly used inside Method 1
        if echo "$lspci_lower" | grep -qi "sata"; then
          final_type="SATA (IDE)"
        else
          final_type="IDE"
        fi
        ;;
    esac
  fi

  # === Method 2: Fallback to Text Description Matching if Method 1 missed ===
  if [[ -z "$final_type" ]]; then
    if echo "$lspci_lower" | grep -qi "sata"; then
      if echo "$lspci_lower" | grep -qi "ahci"; then final_type="AHCI"; else final_type="SATA (IDE)"; fi
    elif echo "$lspci_lower" | grep -qi "ide"; then final_type="IDE"
    elif echo "$lspci_lower" | grep -qi "raid"; then final_type="RAID"
    elif echo "$lspci_lower" | grep -qi "bolt"; then final_type="Thunderbolt"
    elif echo "$lspci_lower" | grep -qi "usb"; then
      if echo "$lspci_lower" | grep -qiE "xhci|extensible "; then final_type="USB 3.x"
      elif echo "$lspci_lower" | grep -qiE "ehci|enhanced|[[:space:]]2\.0[[:space:]]"; then final_type="USB 2.0"
      elif echo "$lspci_lower" | grep -qiE "uhci|ohci|universal|open|[[:space:]]1\.1[[:space:]]|[[:space:]]1\.0[[:space:]]"; then final_type="USB 1.x"
      else final_type="USB"; fi
    elif echo "$lspci_lower" | grep -qiE 'firewire|ieee'; then final_type="IEEE 1394"
    elif echo "$lspci_lower" | grep -qi "sas"; then final_type="SAS"
    elif echo "$lspci_lower" | grep -qi "scsi"; then final_type="SCSI"
    elif echo "$lspci_lower" | grep -qiE 'pcmcia|cardbus'; then final_type="PCMCIA"
    else
      final_type="Unknown"
    fi
  fi

  # === CRITICAL VIA INTERCEPTOR LAYER ===
  # If the resolved type is NOT AHCI, SATA (IDE) or IDE, force scan for specific VIA controller maps
  if [[ "$final_type" != "AHCI" && "$final_type" != "SATA (IDE)" && "$final_type" != "IDE" ]]; then
    if echo "$lspci_lower" | grep -qi "via"; then
      if echo "$lspci_lower" | grep -qi "sata" || echo "$lspci_lower" | grep -qi "raid"; then
        final_type="VIA-SATA/RAID"
      fi
    fi
  fi
  
  echo "$final_type"
}

# Main scan function
scan_disks() {
  local instlr="$1"
  local table_type=""
  DISK_MENU=()
  dialog --infobox "Scanning disk(s)..." 3 24

  for disk in /dev/hd* /dev/sd* /dev/nvme*n* /dev/mmcblk*; do
    [[ ! -b "$disk" ]] && continue
    local type=$(lsblk -dn -o TYPE "$disk" 2>/dev/null)
    [[ "$type" != "disk" ]] && continue
    if [[ "$instlr" == "$disk"* && "$instlr" =~ ^${disk}(p?[0-9]+)?$ ]]; then
      continue
    fi

    local part_table=$(sudo parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2 {print $6}')
    case "$part_table" in
      msdos) table_type="MBR" ;;
      gpt)   table_type="GPT" ;;
      *)
        local fdisk_type=$(sudo fdisk -l "$disk" 2>/dev/null | grep "Disklabel type" | awk '{print $3}')
        case "$fdisk_type" in
          dos) table_type="MBR" ;;
          gpt) table_type="GPT" ;;
          *)
            local pttype=$(blkid -p -o value -s PTTYPE "$disk" 2>/dev/null)
            case "$pttype" in
              dos) table_type="MBR" ;;
              gpt) table_type="GPT" ;;
              "")  table_type="Unknown" ;;
              *)   table_type="${pttype^^}" ;;
            esac
            ;;
        esac
        ;;
    esac

    local disk_basename=$(basename "$disk")
    local sector_size=$(cat /sys/block/$disk_basename/queue/hw_sector_size 2>/dev/null || echo 512)
    local sector_count=$(cat /sys/block/$disk_basename/size 2>/dev/null || echo 0)
    local size_bytes=$((sector_count * sector_size))
    local size_kb=$((size_bytes / 1024))
    local size_fmt=$(format_size "$size_kb")
    local CNTRLR=$(get_disk_interface_type "$disk")

    DISK_MENU+=("$disk" " $size_fmt | $table_type | $CNTRLR")
    DISK_INFO["$disk,type"]="$table_type"
    DISK_INFO["$disk,size"]="$size_fmt"
    DISK_INFO["$disk,cntrlr"]="$CNTRLR"
  done
}
