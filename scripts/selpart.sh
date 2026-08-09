#!/bin/bash

INSTLR_DEVICE="$1"
WIM_FILE="$2"
WIM_FILE_INDEX="$3"
OSCODE="$4"
SETUP_TYPE="$5"
WIM_IMAGE_INFO="$6"
DEFAULT_INSTALLATION_OS_TYPE="$7"

if [[ -z "$INSTLR_DEVICE" || -z "$WIM_FILE" || -z "$WIM_FILE_INDEX" || -z "$OSCODE" || -z "$SETUP_TYPE" || -z "$WIM_IMAGE_INFO" || -z "$DEFAULT_INSTALLATION_OS_TYPE" ]]; then
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
declare -A PART_SIZE_KB_MAP=()
declare -A PART_NUM_MAP=()

# Source external info scripts AFTER declaring arrays to prevent zeroing them out
source "./scripts/diskinfo.sh"
source "./scripts/partinfo.sh"
source "./scripts/sysinfo.sh"

# Dynamic CPU architecture and instruction matrix check function
check_cpu_instructions() {
  local edition_desc="$1"

  # Gather system instruction flags from sysinfo helpers
  local has_pae=$(check_pae)
  local has_nx=$(check_nx)
  local has_sse2=$(check_sse2)

  # Dynamic 486 CPU detection
  local is_486=0
  if lscpu 2>/dev/null | grep -q "486"; then
    is_486=1
  fi

  # === 1. 486 Legacy CPU Constraints ===
  if [[ "$is_486" -eq 1 ]]; then
    # Vista and later Operating Systems do not support 486 CPUs
    if [[ "$edition_desc" =~ Windows\ Vista || "$edition_desc" =~ Windows\ 7 || "$edition_desc" =~ Windows\ 8 || "$edition_desc" =~ Windows\ 10 || "$edition_desc" =~ Windows\ 11 ]]; then
      dialog --msgbox "$edition_desc doesn't support 486 processors." 6 75
      return 1
    fi
    # Windows XP: Only allowed if the edition string explicitly states '486'
    if [[ "$edition_desc" =~ Windows\ XP ]]; then
      if [[ ! "$edition_desc" =~ 486 ]]; then
        dialog --msgbox "$edition_desc doesn't support 486 processors." 6 75
        return 1
      fi
    fi
    # Windows 2000: Only allowed if the edition string explicitly states 'RTM'
    if [[ "$edition_desc" =~ Windows\ 2000 ]]; then
      if [[ ! "$edition_desc" =~ RTM ]]; then
        dialog --msgbox "$edition_desc doesn't support 486 processors." 6 75
        return 1
      fi
    fi
  fi

  # === 2. SSE2 Instruction Constraints ===
  # Vista and later versions require SSE2, EXCEPT editions explicitly marked as 'RTM'
  if [[ "$edition_desc" =~ Windows\ Vista || "$edition_desc" =~ Windows\ 7 || "$edition_desc" =~ Windows\ 8 || "$edition_desc" =~ Windows\ 10 || "$edition_desc" =~ Windows\ 11 ]]; then
    if [[ ! "$edition_desc" =~ RTM ]]; then
      if [[ "$has_sse2" == "No" ]]; then
        dialog --msgbox "$edition_desc only supports:\n* CPUs equipped with the SSE2 instruction set extension" 7 70
        return 1
      fi
    fi
  fi

  # # === 3. Windows 8.0 Matrix (NX, SSE2, PAE Requirements) ===
  # if [[ "$edition_desc" =~ Windows\ 8\.0 ]]; then
  #   # Non-RTM Windows 8.0 editions strictly demand NX, SSE2, and PAE
  #   if [[ ! "$edition_desc" =~ RTM ]]; then
  #     if [[ "$has_nx" == "No" || "$has_sse2" == "No" || "$has_pae" == "No" ]]; then
  #       dialog --msgbox "$edition_desc only supports:\n* Processors with full enabled PAE, NX (Execute Disable Bit), and SSE2 instruction support" 8 82
  #       return 1
  #     fi
  #   fi
  # fi

  return 0
}

check_partition_compatibility() {
  local part_type="$1"
  local fs_type="$2"
  local disk="$3"
  local start_lba="$4"
  local end_lba="$5"
  local edition_desc="$6"
  
  if [[ "$part_type" == "EXT" ]]; then
    dialog --msgbox "Installation is not possible on an extended partition!\n\nPlease choose a primary or logical partition." 7 60
    return 1
  fi
  if [[ "$fs_type" == "Unformatted" ]]; then
    dialog --msgbox "The selected partition is unformatted.\n\nPlease format it before installing OS." 7 60
    return 1
  fi

  local sector_size=$(cat /sys/block/$(basename "$disk")/queue/logical_block_size 2>/dev/null)
  [[ -z "$sector_size" || "$sector_size" -le 0 ]] && sector_size=512

  local chs_limit_8gb=$(( 7987 * 1024 * 1024 / sector_size ))
  local lba_limit_137gb=$(( 137400000000 / sector_size ))

  if [[ "$edition_desc" =~ Windows\ NT\ 3\.[15] && "$edition_desc" =~ Vanilla ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" ]] || (( end_lba > chs_limit_8gb )); then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12 or FAT16 formatted partition\n* Entire partition must reside within the first 8.3 GB of the disk\n* Must be CHS-accessible" 12 60
      return 1
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.50 && "$edition_desc" =~ Patched ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12 or FAT16 formatted partition" 9 60
      return 1
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.51 && "$edition_desc" =~ Patched ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, or FAT32 formatted partition" 9 60
      return 1
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.0 && "$edition_desc" =~ Vanilla ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "NTFS" ]] || (( end_lba > lba_limit_137gb )); then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, or NTFS formatted partition\n* Entire partition must reside within the first 137.4 GB of the disk" 11 60
      return 1
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.0 && "$edition_desc" =~ Patched ]]; then
    if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" && "$fs_type" != "ext2" && "$fs_type" != "ext3" ]]; then
      dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, FAT32, NTFS, ext2 or ext3 formatted partition" 9 65
      return 1
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ 2000 ]]; then
    if [[ "$edition_desc" =~ Patched ]] && [[ ! "$edition_desc" =~ APIC ]]; then
      if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" && "$fs_type" != "ext2" && "$fs_type" != "ext3" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, FAT32, NTFS, ext2 or ext3 formatted partition" 9 65
        return 1
      fi
    else
      if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, FAT32 or NTFS formatted partition" 9 60
        return 1
      fi
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ XP ]]; then
    if [[ "$edition_desc" =~ Patched ]] && [[ ! "$edition_desc" =~ 486 ]]; then
      if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" && "$fs_type" != "ext2" && "$fs_type" != "ext3" && "$fs_type" != "Btrfs" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, FAT32, NTFS, ext2, ext3 or Btrfs formatted partition" 9 75
        return 1
      fi
    else
      if [[ "$fs_type" != "FAT12" && "$fs_type" != "FAT16 CHS" && "$fs_type" != "FAT16 LBA" && "$fs_type" != "FAT32 CHS" && "$fs_type" != "FAT32 LBA" && "$fs_type" != "NTFS" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* FAT12, FAT16, FAT32 or NTFS formatted partition" 9 60
        return 1
      fi
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ Vista || "$edition_desc" =~ Windows\ 7 ]]; then
    if [[ "$edition_desc" =~ Patched ]]; then
      if [[ "$fs_type" != "NTFS" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* NTFS formatted partition" 9 50
        return 1
      fi
    else
      if [[ "$fs_type" != "NTFS" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* NTFS formatted partition" 9 50
        return 1
      fi
    fi
  fi
  if [[ "$edition_desc" =~ Windows\ 8 || "$edition_desc" =~ Windows\ 10 || "$edition_desc" =~ Windows\ 11 ]]; then
    if [[ "$edition_desc" =~ Patched ]]; then
      if [[ "$fs_type" != "NTFS" && "$fs_type" != "exFAT" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* NTFS or exFAT formatted partition" 9 55
        return 1
      fi
    else
      if [[ "$fs_type" != "NTFS" && "$fs_type" != "exFAT" ]]; then
        dialog --msgbox "Incompatible partition for $edition_desc!\n\nRequirement(s):\n* NTFS or exFAT formatted partition" 9 55
        return 1
      fi
    fi
  fi
  return 0
}

check_partition_compatibility_custom() {
  local part_type="$1"
  local fs_type="$2"
  if [[ "$part_type" == "EXT" ]]; then
    dialog --msgbox "Installation is not possible on an extended partition!\n\nPlease choose a primary or logical partition." 7 60
    return 1
  fi
  if [[ "$fs_type" == "Unformatted" ]]; then
    dialog --msgbox "The selected partition is unformatted.\n\nPlease format it before installing OS." 7 60
    return 1
  fi
  return 0
}

check_ext_btrfs_boot_requirement() {
  local target_fs="$1"

  # Only trigger check if selected FS is ext2, ext3 or Btrfs
  if [[ "$target_fs" == "ext2" || "$target_fs" == "ext3" || "$target_fs" == "Btrfs" ]]; then
    local has_primary_fat=0

    # Scan mapped partitions on the selected disk
    for part_name in "${!PART_FS_MAP[@]}"; do
      local p_num="${PART_NUM_MAP[$part_name]}"
      local p_fs="${PART_FS_MAP[$part_name]}"

      # Check if partition is PRIMARY (Part Num 1 to 4) AND is FAT12/16/32
      if (( p_num >= 1 && p_num <= 4 )); then
        if [[ "$p_fs" == "FAT12" || "$p_fs" == "FAT16 CHS" || "$p_fs" == "FAT16 LBA" || "$p_fs" == "FAT32 CHS" || "$p_fs" == "FAT32 LBA" ]]; then
          has_primary_fat=1
          break
        fi
      fi
    done

    # If no Primary FAT partition exists on disk, prompt warning and block
    if [[ $has_primary_fat -eq 0 ]]; then
      dialog --msgbox "A Primary FAT12, FAT16, or FAT32 partition is required on the disk to boot $target_fs!\n\nPlease create a Primary FAT partition for boot files before proceeding." 9 70
      return 1
    fi
  fi
  return 0
}

# Unified dynamic free space check function for both standard and custom setups
check_free_space() {
  local free_kb="$1"
  local edition_desc="$2"
  local total_bytes=0
  local wim_file_path=""

  # Determine path dynamically based on setup type
  if [[ "$SETUP_TYPE" -eq 1 ]]; then
    wim_file_path="/mnt/uwifiles/osfiles/custom/$WIM_FILE"
  else
    wim_file_path="/mnt/uwifiles/osfiles/$WIM_FILE"
  fi
  
  # Read the actual uncompressed size of the specific WIM index heavily silenced
  total_bytes=$(wimlib-imagex info "$wim_file_path" "$WIM_FILE_INDEX" 2>/dev/null \
    | grep -i -m1 'Total Bytes' | sed -E 's/[^0-9]//g' | tr -d '\r')

  # Fallback if size extraction fails
  if [[ -z "$total_bytes" || "$total_bytes" -eq 0 ]]; then
    dialog --msgbox "Failed to read WIM/ESD file size info!\n\nFile: $WIM_FILE\nIndex: $WIM_FILE_INDEX" 9 60
    return 1
  fi

  # Calculate required space: (Total Bytes / 1024) + 10 MB padding, rounded up
  local required_kb=$(( (((total_bytes / 1024 + 10240) + 1023) / 1024) * 1024 ))

  if (( free_kb < required_kb )); then
    local free_fmt=$(format_size "$free_kb")
    local required_fmt=$(format_size "$required_kb")
    
    if [[ "$SETUP_TYPE" -eq 1 ]]; then
      dialog --msgbox "Not enough free space on selected partition!\n\nRequired: $required_fmt\nAvailable: $free_fmt" 8 50
    else
      dialog --msgbox "Not enough free space on selected partition for $edition_desc!\n\nRequired: $required_fmt\nAvailable: $free_fmt" 10 50
    fi
    return 1
  fi
  return 0
}

get_disk_irq() {
  local disk_base=$(basename "$1")
  local pci_path=$(readlink -f "/sys/block/$disk_base/device" 2>/dev/null)
  [[ -z "$pci_path" ]] && { echo "Unknown"; return; }
  local pci_addr=$(echo "$pci_path" | grep -oE '([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
  [[ -z "$pci_addr" ]] && { echo "Unknown"; return; }
  local short_pci_addr="${pci_addr#0000:}"
  local irq=$(lspci -v -s "$short_pci_addr" 2>/dev/null | awk '/\bIRQ\b/ {print $2; exit}')

  if [[ -z "$irq" ]]; then
    local driver=$(basename "$(readlink -f /sys/bus/pci/devices/$pci_addr/driver)" 2>/dev/null)
    if [[ -n "$driver" ]]; then
      local irq_line=$(grep "$driver" /proc/interrupts | head -n1)
      [[ -n "$irq_line" ]] && irq=$(echo "$irq_line" | awk -F: '{print $1}' | tr -d ' ')
    fi
  fi
  echo "${irq:-Unknown}"
}

controller_OS_check() {
  local controller="$1"
  local edition_desc="$2"
  local irq="$3"

  # === Handle Unknown Controller with a Yes/No Dialogue ===
  if [[ "$controller" == "Unknown" ]]; then
    dialog --yesno "Installer was unable to detect your disk controller type.\n\nInstallation might fail or result in a Blue Screen (BSOD).\n\nDo you want to proceed anyway?" 9 70
    if [[ $? -ne 0 ]]; then
      return 1
    fi
  fi

  # === Block problematic VIA SATA/RAID controllers that lack AHCI or IDE ===
  if [[ "$DEFAULT_INSTALLATION_OS_TYPE" -ne 3 ]]; then 
    if [[ "$controller" == "VIA-SATA/RAID" ]]; then
      dialog --msgbox "Installer doesn't support VIA SATA/RAID controllers for any NT-based x86 and x64 OS!" 7 80
      return 1
    fi
  fi
  
  # If the controller is generic SCSI, determine the exact subtype via lspci
  local scsi_subtype="Generic"
  if [[ "$controller" == "SCSI" ]]; then
    local disk_basename=$(basename "$DISK_SELECTED")
    local sys_path=$(readlink -f "/sys/block/$disk_basename/device" 2>/dev/null)
    local pci_addr=$(echo "$sys_path" | grep -oE '([[:alnum:]]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' | tail -n1)
    local pci_id_short="${pci_addr#0000:}"
    
    if [[ -n "$pci_id_short" ]]; then
      local lspci_detail=$(lspci -s "$pci_id_short" 2>/dev/null | tr '[:upper:]' '[:lower:]')
      if echo "$lspci_detail" | grep -qi "bus logic"; then
        scsi_subtype="BusLogic"
      elif echo "$lspci_detail" | grep -qi "buslogic"; then
        scsi_subtype="BusLogic"
      elif echo "$lspci_detail" | grep -qi "lsi logic"; then
        scsi_subtype="LSI"
      elif echo "$lspci_detail" | grep -qi "lsilogic"; then
        scsi_subtype="LSI"
      fi
    fi
  fi

  # === 1. SCSI Subtype & SAS Core Rules (Across All OS Versions) ===
  # BusLogic SCSI: Only supported on x86 OS from NT 3.1 up to Windows 2000. Never allowed on x64 or XP+.
  if [[ "$scsi_subtype" == "BusLogic" ]]; then
    if [[ "$edition_desc" =~ 64 ]] || [[ "$edition_desc" =~ Windows\ XP || "$edition_desc" =~ Windows\ Vista || "$edition_desc" =~ Windows\ 7 || "$edition_desc" =~ Windows\ 8 || "$edition_desc" =~ Windows\ 10 || "$edition_desc" =~ Windows\ 11 ]]; then
      dialog --msgbox "$edition_desc doesn't support BusLogic SCSI storage." 6 80
      return 1
    fi
  fi

  # LSI Logic SCSI (Non-SAS): Supported by all OS (x86/x64) EXCEPT Windows NT 3.1
  if [[ "$scsi_subtype" == "LSI" ]]; then
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.1 ]]; then
      dialog --msgbox "LsiLogic SCSI doesn't support $edition_desc (LsiLogic SCSI requires Windows NT 3.50 and later)!" 6 85
      return 1
    fi
  fi

  # SAS Disks: Supported on Windows 2000 and all subsequent OS (both x86 and x64)
  if [[ "$controller" == "SAS" ]]; then
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.[0-9] || "$edition_desc" =~ Windows\ NT\ 4\.0 ]]; then
      dialog --msgbox "$edition_desc doesn't support SAS storage (SAS requires Windows 2000 or later)!" 7 75
      return 1
    fi
  fi

  # === 2. Windows NT 3.x Matrix ===
  if [[ "$edition_desc" =~ Windows\ NT\ 3\.[0-9] ]]; then
    # NT 3.1 Vanilla Exceptions
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.1 && "$edition_desc" =~ Vanilla ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* SCSI" 10 50
        return 1
      fi
      if [[ ("$controller" == "IDE" || "$controller" == "SATA (IDE)") && "$irq" != "14" ]]; then
        dialog --msgbox "For $edition_desc, IDE/SATA (IDE) controller IRQ must be 14!\n\nDetected IRQ: $irq" 10 60
        return 1
      fi
    fi

    # NT 3.50 Patched Supported: IDE, SATA (IDE), NVMe, SCSI
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.50 && "$edition_desc" =~ Patched ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "NVMe" && "$controller" != "SCSI" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* NVMe\n* SCSI" 11 55
        return 1
      fi
    fi

    # NT 3.51 Patched Supported: IDE, SATA (IDE), AHCI, NVMe, SCSI
    if [[ "$edition_desc" =~ Windows\ NT\ 3\.51 && "$edition_desc" =~ Patched ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "NVMe" && "$controller" != "SCSI" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* NVMe\n* SCSI" 12 55
        return 1
      fi
    fi

    # Generic NT 3.x Vanilla (Restricted to IDE, SATA (IDE) or compatible SCSI)
    if [[ "$edition_desc" =~ Vanilla && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" ]]; then
      dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* SCSI" 10 55
      return 1
    fi
  fi

  # === 3. Windows NT 4.0 / 2000 / XP Vanilla Rules ===
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.0 || "$edition_desc" =~ Windows\ 2000 || "$edition_desc" =~ Windows\ XP ]]; then  # Windows NT 4.0 doesn't support SAS, it was checked above
    if [[ "$edition_desc" =~ Vanilla || "$edition_desc" =~ Fundamentals || "$edition_desc" =~ RTM ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* SCSI\n* SAS" 11 55
        return 1
      fi
    fi
  fi

  # === 4. Windows NT 4.0 Patched Rules ===
  if [[ "$edition_desc" =~ Windows\ NT\ 4\.0 && "$edition_desc" =~ Patched ]]; then
    if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "NVMe" && "$controller" != "SCSI" ]]; then
      dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* NVMe\n* SCSI" 12 55
      return 1
    fi
  fi

  # === 5. Windows 2000 Patched & [ACPI+APIC] Rules ===
  if [[ "$edition_desc" =~ Windows\ 2000 && "$edition_desc" =~ Patched ]]; then
    if [[ "$edition_desc" =~ ACPI\+APIC ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "NVMe" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* NVMe\n* SCSI\n* SAS" 13 55
        return 1
      fi
    else
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "NVMe" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* NVMe\n* SCSI\n* SAS" 12 55
        return 1
      fi
    fi
  fi	

  # === 6. Windows XP Patched Rules ===
  if [[ "$edition_desc" =~ Windows\ XP && "$edition_desc" =~ Patched ]]; then
    if [[ "$edition_desc" =~ 486 ]]; then
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* SCSI" 10 55
        return 1
      fi
    else
      if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "AHCI" && "$controller" != "RAID" && "$controller" != "eMMC" && "$controller" != "NVMe" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* RAID\n* eMMC\n* NVMe\n* SCSI\n* SAS" 15 55
        return 1
      fi
	fi
  fi

  # === 7. Windows Vista Matrix ===
  if [[ "$edition_desc" =~ Windows\ Vista ]]; then
    if [[ "$edition_desc" =~ RTM || "$edition_desc" =~ Vanilla ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS" 12 55
        return 1
      fi
    elif [[ "$edition_desc" =~ Patched ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" && "$controller" != "NVMe" && "$controller" != "eMMC" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS\n* NVMe\n* eMMC" 14 55
        return 1
      fi
    fi
  fi

  # === 8. Windows 7 Matrix ===
  if [[ "$edition_desc" =~ Windows\ 7 ]]; then
    if [[ "$edition_desc" =~ Updated ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" && "$controller" != "NVMe" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS\n* NVMe" 13 55
        return 1
      fi
    elif [[ "$edition_desc" =~ Patched ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" && "$controller" != "NVMe" && "$controller" != "eMMC" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS\n* NVMe\n* eMMC" 14 55
        return 1
      fi
    elif [[ "$edition_desc" =~ RTM ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS" 12 55
        return 1
      fi
    fi
  fi

  # === 9. Windows 8.0 Matrix ===
  if [[ "$edition_desc" =~ Windows\ 8\.0 ]]; then
    if [[ "$edition_desc" =~ RTM || "$edition_desc" =~ Vanilla ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" && "$controller" != "eMMC" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS\n* eMMC" 13 55
        return 1
      fi
    elif [[ "$edition_desc" =~ Patched ]]; then
      if [[ "$controller" != "AHCI" && "$controller" != "IDE" && "$controller" != "SATA (IDE)" && "$controller" != "SCSI" && "$controller" != "SAS" && "$controller" != "NVMe" && "$controller" != "eMMC" ]]; then
        dialog --msgbox "$edition_desc only supports:\n\n* IDE\n* SATA (IDE)\n* AHCI\n* SCSI\n* SAS\n* NVMe\n* eMMC" 14 55
        return 1
      fi
    fi
  fi

  return 0
}

check_disk_position() {
  local device="$1"
  local edition_desc="$2"
  local controller=$(get_disk_interface_type "$device")
  
  if [[ "$controller" != "IDE" && "$controller" != "SATA (IDE)" ]]; then return 0; fi
  local sys_path="/sys/block/$(basename "$device")"
  if [[ ! -e "$sys_path" ]]; then dialog --msgbox "Sysfs path $sys_path does not exist." 5 50; return 1; fi

  local devpath=$(udevadm info --query=all --path="$sys_path" 2>/dev/null | grep '^E: DEVPATH=' | cut -d= -f2)
  if [[ -z "$devpath" ]]; then dialog --msgbox "Failed to retrieve DEVPATH." 5 50; return 1; fi

  local ata_name=""
  if [[ "$devpath" =~ /ata([0-9]+)/ ]]; then ata_name="ata${BASH_REMATCH[1]}"
  else dialog --msgbox "Could not extract ataX from DEVPATH." 5 50; return 1; fi

  if [[ "$controller" == "IDE" ]]; then
    local channel=""
    while read -r line; do
      if [[ "$line" =~ ($ata_name).*cmd\ (0x[0-9a-f]+) ]]; then
        case "${BASH_REMATCH[2]}" in 0x1f0) channel=0 ;; 0x170) channel=1 ;; *) channel="unknown" ;; esac
        break
      fi
    done < <(dmesg | grep -i "PATA max")
    if [[ -z "$channel" || "$channel" == "unknown" ]]; then dialog --msgbox "Unable to determine IDE channel." 5 50; return 1; fi
  fi

  local position="" local sata_port=""
  if [[ "$devpath" =~ target([0-9]+):[0-9]+:([0-9]+) ]]; then
    sata_port="${BASH_REMATCH[1]}" ; position="${BASH_REMATCH[2]}"
  else dialog --msgbox "Failed to extract device position." 5 50; return 1; fi

  if [[ "$edition_desc" =~ Windows\ NT\ 3\.1 ]] && [[ "$edition_desc" =~ Vanilla ]]; then
    if [[ "$controller" == "IDE" ]]; then
      if (( channel != 0 || position != 0 )); then dialog --msgbox "IDE device must be Primary Master for $edition_desc." 7 60; return 1; fi
    elif [[ "$controller" == "SATA (IDE)" ]]; then
      if (( sata_port != 0 )); then dialog --msgbox "SATA (IDE) disk must be on port 0 for $edition_desc." 7 60; return 1; fi
    else dialog --msgbox "Only IDE and SATA (IDE) are supported for $edition_desc." 7 60; return 1; fi
  fi
  if { [[ "$edition_desc" =~ Windows\ NT\ 3\.50 ]] && { [[ "$edition_desc" =~ Vanilla ]] || [[ "$edition_desc" =~ Patched ]]; }; } || { [[ "$edition_desc" =~ Windows\ NT\ 3\.51 ]] && [[ "$edition_desc" =~ Vanilla ]]; }; then
    if [[ "$controller" == "IDE" ]]; then
      if (( position != 0 )) || (( channel != 0 && channel != 1 )); then
        dialog --msgbox "IDE disk must be Primary or Secondary Master for $edition_desc." 7 60
        return 1
      fi
    fi
  fi
  return 0
}

parse_boot_part_num() {
  local disk="$1" local valid_ids="01 04 06 07 0b 0c 0e 11 14 16 17 1b 1c 1e"
  local active_partnum=$(sudo parted -sm "$disk" print | awk -F: '{ if ($0 ~ /boot/) print $1 }' | head -n1)

  if [[ -n "$active_partnum" ]]; then
    local partname=$([[ "$disk" =~ nvme[0-9]+n[0-9]+$ || "$disk" =~ mmcblk[0-9]+$ ]] && echo "${disk}p${active_partnum}" || echo "${disk}${active_partnum}")
    local parttype=$(lsblk -no PARTTYPE "$partname" 2>/dev/null)
    local fstype=$(lsblk -no FSTYPE "$partname" 2>/dev/null)
    local partsize=$(lsblk -nb -no SIZE "$partname" 2>/dev/null)
	
    if [[ "$parttype" =~ ^0x ]] && [[ "$partsize" -ge 4194304 ]]; then
      local id="${parttype#0x}" ; id="${id,,}" ; [[ ${#id} -eq 1 ]] && id="0$id"
      if [[ "$id" == "07" || "$id" == "17" ]] && [[ "$fstype" != "ntfs" ]]; then active_partnum=""; fi
      if [[ -n "$active_partnum" && "$valid_ids" =~ $id ]]; then echo "$active_partnum"; return 0; fi
    fi
  fi

  readarray -t lines < <(lsblk -lnpo NAME,FSTYPE,PARTTYPE "$disk")
  for line in "${lines[@]}"; do
    local part fstype parttype
    read -r part fstype parttype <<< "$line"
    local partnum=$(echo "$part" | grep -o '[0-9]\+$')
    [[ -z "$partnum" || -z "$fstype" || ! "$parttype" =~ ^0x ]] && continue	
    local partsize=$(lsblk -nb -no SIZE "$part" 2>/dev/null)
    [[ "$partsize" -lt 4194304 ]] && continue

    local id="${parttype#0x}" ; id="${id,,}" ; [[ ${#id} -eq 1 ]] && id="0$id"
    if [[ "$id" == "07" || "$id" == "17" ]] && [[ "$fstype" != "ntfs" ]]; then continue; fi
    if grep -qw "$id" <<< "$valid_ids"; then echo "$partnum"; return 0; fi
  done
  echo -1; return 1
}

is_partition_hidden() {
  local disk="$1" local part_num="$2"
  local flags=$(sudo parted -sm "$disk" print | awk -F: -v p="$part_num" '$1 == p {print $7}')
  [[ "$flags" == *hidden* ]] && return 0 || return 1
}

read_os_edition_names() {
  EDITION_DESC=""
  while IFS='=' read -r os_code editions; do
    if [[ "$os_code" == "$OSCODE" ]]; then
      IFS=',' read -ra ed_arr <<< "$editions"
      for ed in "${ed_arr[@]}"; do
        IFS=':' read -r ed_code ed_index ed_desc <<< "$ed"
        if [[ "$ed_index" == "$WIM_FILE_INDEX" ]]; then EDITION_DESC="$ed_desc"; break 2; fi
      done
    fi
  done < "./configs/edition_list.cfg"
}

read_old_os_folders() {
  OLD_OS_FOLDERS=()
  if [[ -f "./configs/old_os_folders.cfg" ]]; then
    IFS=':' read -ra OLD_OS_FOLDERS <<< "$(cat ./configs/old_os_folders.cfg)"
  fi
}

if [[ "$SETUP_TYPE" -eq 0 ]]; then read_os_edition_names; fi
read_old_os_folders

scan_disks "$INSTLR_DEVICE"

while true; do
  DISK_SELECTED=$(dialog --clear --backtitle "Disk Selection" \
    --title "Select Target Disk" \
    --menu "Choose the target disk for installation:" 19 80 13 "${DISK_MENU[@]}" 3>&1 1>&2 2>&3)

  [[ $? -ne 0 || -z "$DISK_SELECTED" ]] && exit 2
  
  dialog --infobox "Checking OS disk requirements..." 3 37
  
  if [[ "$SETUP_TYPE" -eq 0 ]]; then
    CNTRLR="${DISK_INFO["$DISK_SELECTED,cntrlr"]}"
    IRQ_NUM=$(get_disk_irq "$DISK_SELECTED")
    if ! controller_OS_check "$CNTRLR" "$EDITION_DESC" "$IRQ_NUM"; then continue; fi
    if ! check_disk_position "$DISK_SELECTED" "$EDITION_DESC"; then continue; fi
  fi
  
  [[ "${DISK_INFO[$DISK_SELECTED,type]}" != "MBR" ]] && {
    dialog --msgbox "Only MBR disks are supported!" 6 50; continue
  }
  
  BOOT_PART_NUM=$(parse_boot_part_num "$DISK_SELECTED")
  if [[ "$BOOT_PART_NUM" == "-1" ]]; then
    dialog --msgbox "Installer was unable to find a supported primary partition (FAT12/FAT16/FAT32/NTFS) for booting the OS." 6 70; continue
  fi
  
  scan_partitions "$DISK_SELECTED"

  while true; do
    [[ ${#PART_MENU[@]} -eq 0 ]] && { dialog --msgbox "No partitions found on $DISK_SELECTED." 7 50; break; }

    PART_SELECTED_INDEX=$(dialog --clear --backtitle "Partition Selection" \
      --title "Select Installation Partition" \
      --menu "Choose the partition for installation:" 19 80 13 "${PART_MENU[@]}" 3>&1 1>&2 2>&3)

    [[ $? -ne 0 || -z "$PART_SELECTED_INDEX" ]] && break
    
    dialog --infobox "Checking OS partition requirements..." 3 42

    OS_PART_NAME="$PART_SELECTED_INDEX"
    OS_PART_NUM="${PART_NUM_MAP[$OS_PART_NAME]}"
    PART_FS="${PART_FS_MAP[$OS_PART_NAME]}"
    PART_SIZE="${PART_SIZE_MAP[$OS_PART_NAME]}"
    PART_FREE_KB="${PART_FREE_KB_MAP[$OS_PART_NAME]}"
    
    CNTRLR="${DISK_INFO["$DISK_SELECTED,cntrlr"]}"
    
    active_flag=" "
    fdisk -l "$DISK_SELECTED" | grep "^$OS_PART_NAME" | awk '{ if ($2 == "*") print "*" }' | grep -q '*' && active_flag="A"
    
    hidden_flag=" "
    is_partition_hidden "$DISK_SELECTED" "$OS_PART_NUM" && hidden_flag="H"
    
    part_type=$([[ "$OS_PART_NUM" -ge 5 ]] && echo "LOG" || echo "PRI")
	
	label=$(lsblk -no LABEL "$OS_PART_NAME" 2>/dev/null | xargs)
    
    disk_info_line="Disk: $DISK_SELECTED | ${DISK_INFO[$DISK_SELECTED,size]} | ${DISK_INFO[$DISK_SELECTED,type]} | $CNTRLR"
    free_fmt=$(format_size "$PART_FREE_KB")
    part_info_line=$(printf "Partition: %s | %s%s %s | %s | %s / %s | %s" "$OS_PART_NAME" "$active_flag" "$hidden_flag" "$part_type" "$PART_FS" "$free_fmt" "$PART_SIZE" "${label:-N/A}")

    FDISK_LINE=$(fdisk -l "$DISK_SELECTED" | grep -E "^${OS_PART_NAME}([[:space:]]|\*)")
    
    # Safe multi-column mapping for fdisk output variance
    if [[ "$FDISK_LINE" =~ \* ]]; then
      START_LBA=$(echo "$FDISK_LINE" | awk '{print $3}')
      END_LBA=$(echo "$FDISK_LINE" | awk '{print $4}')
    else
      START_LBA=$(echo "$FDISK_LINE" | awk '{print $2}')
      END_LBA=$(echo "$FDISK_LINE" | awk '{print $3}')
    fi

    # Both default and custom streams route through the new unified check_free_space function
    if [[ "$SETUP_TYPE" -eq 0 ]]; then
	  check_cpu_instructions "$EDITION_DESC" || continue
      check_partition_compatibility "$part_type" "$PART_FS" "$DISK_SELECTED" "$START_LBA" "$END_LBA" "$EDITION_DESC" || continue
      check_free_space "$PART_FREE_KB" "$EDITION_DESC" || continue
	  check_ext_btrfs_boot_requirement "$PART_FS" || continue
      if [[ "$part_type" == "LOG" && "$EDITION_DESC" =~ NT\ 3 ]]; then
        dialog --yesno "$EDITION_DESC might not boot from a logical partition.\n\nContinue?" 15 70 || continue
      fi
    elif [[ "$SETUP_TYPE" -eq 1 ]]; then
      check_partition_compatibility_custom "$part_type" "$PART_FS" || continue
      check_free_space "$PART_FREE_KB" "" || continue
	  # check_ext_btrfs_boot_requirement "$PART_FS" || continue
    fi

    if [[ "$hidden_flag" == "H" ]]; then
      dialog --yesno "Install partition must be unhidden. Installer will fix this. Continue?" 15 70 || continue
    fi

    # === On-Demand Old OS Folders Scanning ===
    HAS_OLD_OS=0
    TMP_MOUNT="/tmp/mnt_sel_$(basename "$OS_PART_NAME")"
    sudo mkdir -p "$TMP_MOUNT"
    sudo umount "$TMP_MOUNT" 2>/dev/null
    
    if sudo mount -o ro "$OS_PART_NAME" "$TMP_MOUNT" >/dev/null 2>&1 \
      || { [[ "$PART_FS" == "NTFS" ]] && sudo ntfs-3g -o ro "$OS_PART_NAME" "$TMP_MOUNT" >/dev/null 2>&1; }
    then
      for folder in "${OLD_OS_FOLDERS[@]}"; do
        if find "$TMP_MOUNT" -maxdepth 1 -type d -iname "$folder" | grep -q .; then
          HAS_OLD_OS=1
          break
        fi
      done
      sudo umount "$TMP_MOUNT" >/dev/null 2>&1
    fi
    rm -rf "$TMP_MOUNT"

    if [[ "$HAS_OLD_OS" -eq 1 ]]; then
      dialog --yesno "Some old Windows OS files detected. If you continue, installer will move them to Windows.old. \n\nDo you want to continue?" 9 60 || continue
    fi

    CONFIRM_MSG=$([[ "$SETUP_TYPE" -eq 0 ]] && echo -e "OS Edition: $EDITION_DESC\n\n$disk_info_line\n$part_info_line\n\nProceed?" || echo -e "Custom Installation: $WIM_FILE -> $WIM_IMAGE_INFO\n\n$disk_info_line\n$part_info_line\n\nProceed?")
	
    dialog --yesno "$CONFIRM_MSG" 10 80 || continue

    bash ./scripts/startins.sh "$OS_PART_NAME" "$WIM_FILE" "$WIM_FILE_INDEX" "$OS_PART_NUM" "$BOOT_PART_NUM" "$OSCODE" "$EDITION_DESC" "$SETUP_TYPE" "$WIM_IMAGE_INFO"
    [[ $? -eq 5 ]] && exit 5
    exit 0
  done
done
