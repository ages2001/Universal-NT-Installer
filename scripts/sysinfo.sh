#!/bin/bash

# sysinfo.sh - System Information

check_cpu_arch() {
  local cpu_arch
  cpu_arch=$(lscpu | grep -i 'CPU op-mode' | awk -F: '{print $2}' | xargs)
  echo "$cpu_arch"
}

check_total_ram() {
  local min_ram_mb="$1"
  local total_ram_mb=""

  local dmidecode_out
  dmidecode_out=$(sudo dmidecode 2>/dev/null | grep -i "Range Size" | awk '{print $3, $4}' | sort -nr -k1 | head -n1)

  if [[ -n "$dmidecode_out" ]]; then
    local value unit
    value=$(echo "$dmidecode_out" | awk '{print $1}')
    unit=$(echo "$dmidecode_out" | awk '{print toupper($2)}')

    case "$unit" in
      MB) total_ram_mb="$value" ;;
      GB) total_ram_mb=$((value * 1024)) ;;
      TB) total_ram_mb=$((value * 1024 * 1024)) ;;
    esac
  else
    local total_ram_kb
    total_ram_kb=$(sudo dmesg | grep Memory: | awk -F'[/K]' '{print $3}')
    total_ram_mb=$((total_ram_kb / 1024))
  fi

  if [[ "$total_ram_mb" -ge "$min_ram_mb" ]]; then echo 1; else echo 0; fi
}

check_acpi() {
  local acpi_rev
  if grep -qw "acpi=off" /proc/cmdline 2>/dev/null; then
    echo "Yes"
    return
  fi
 
  # Define ACPI table file path (check FADT first, fallback to FACP)
  acpi_file=""
  if [ -f "/sys/firmware/acpi/tables/FADT" ]; then
    acpi_file="/sys/firmware/acpi/tables/FADT"
  elif [ -f "/sys/firmware/acpi/tables/FACP" ]; then
    acpi_file="/sys/firmware/acpi/tables/FACP"
  fi

  # 1st Priority: Read revision byte using xxd from FADT/FACP
  if [ -n "$acpi_file" ]; then
    # Read 1 byte at offset 8 in plain hex format
    hex_rev=$(sudo xxd -p -s 8 -l 1 "$acpi_file" 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$hex_rev" ]; then
      # Convert hex to decimal (e.g., '05' -> 5, '0A' -> 10)
      dec_rev=$((16#$hex_rev))
        
      # Directly format as X.0
      acpi_rev="${dec_rev}.0"
    fi
  fi

  # Fallback: Use biosdecode if xxd failed
  if [ -z "$acpi_rev" ]; then
    acpi_rev=$(sudo biosdecode 2>/dev/null | grep -i 'ACPI' | awk '{print $2}' | head -n1)
  fi

  if [[ -z "$acpi_rev" ]]; then
    if ls /sys/firmware/acpi/tables/* &>/dev/null; then echo "Yes"; else echo "No"; fi
  else
    echo "$acpi_rev"
  fi
}

check_apic() {
  if grep -qE -w "noapic|nolapic" /proc/cmdline 2>/dev/null; then
    echo "Yes"
    return
  fi
  if [[ -f /sys/firmware/acpi/tables/APIC ]]; then echo "Yes"; else echo "No"; fi
}

check_mps() {
    local rev
    rev=$(sudo biosdecode 2>/dev/null | grep -A1 'Multiprocessor' | grep 'Specification' | awk '{print $NF}')
    if [[ -n "$rev" ]]; then
        echo "$rev"
    elif sudo dmesg 2>/dev/null | grep -qi "MP-table"; then
        echo "Yes"
    else
        echo "No"
    fi
}

check_pae() {
  # 1. Check if PAE is explicitly disabled via Kernel Command Line
  if grep -qwE "disablepae|no-pae|nopae" /proc/cmdline 2>/dev/null; then
    echo "No"
    return
  fi

  # 2. Check hardware CPU flags via lscpu or /proc/cpuinfo
  if lscpu 2>/dev/null | grep -i flags | grep -qw "pae" || grep -m1 "^flags" /proc/cpuinfo 2>/dev/null | grep -qw "pae"; then
    echo "Yes"
  else
    echo "No"
  fi
}

check_nx() {     lscpu | grep -i flags | grep -qw nx;     if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_ht() {     lscpu | grep -i flags | grep -qw ht;     if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_mmx() {    lscpu | grep -i flags | grep -qw mmx;    if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_avx() {    lscpu | grep -i flags | grep -qw avx;    if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_avx2() {   lscpu | grep -i flags | grep -qw avx2;   if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_popcnt() { lscpu | grep -i flags | grep -qw popcnt; if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }

check_sse() {    lscpu | grep -i flags | grep -qw sse;    if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_sse2() {   lscpu | grep -i flags | grep -qw sse2;   if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_sse3() {   lscpu | grep -i flags | grep -qw pni;    if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_ssse3() {  lscpu | grep -i flags | grep -qw ssse3;  if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_sse4_1() { lscpu | grep -i flags | grep -qw sse4_1; if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }
check_sse4_2() { lscpu | grep -i flags | grep -qw sse4_2; if [[ $? -eq 0 ]]; then echo "Yes"; else echo "No"; fi; }

get_video_resolution() {
    local fb_modes fb_mode res refresh bpp
    if [[ ! -r /sys/class/graphics/fb0/modes ]]; then echo "Default"; return; fi
    fb_modes=$(cat /sys/class/graphics/fb0/modes | head -n1)
    [[ -z "$fb_modes" ]] && { echo "Default"; return; }
    fb_mode=${fb_modes#U:}
    fb_mode=${fb_mode%%-*}
    res=${fb_mode%[pi]}
    refresh=$(echo "$fb_modes" | sed -n 's/.*-\([0-9]\+\).*/\1/p')
    [[ -z "$refresh" ]] && refresh=60
    if [[ -f /sys/class/graphics/fb0/bits_per_pixel ]]; then
        bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel)
    else
        bpp=8
    fi
    echo "${res}x${bpp} (${refresh}Hz)"
}

show_system_info() {
  dialog --infobox "Scanning the system..." 3 27

  local CPU_WIDTH SYSARCH CPU_NAME CPU_CORES CPU_THREADS TOTAL_RAM_KB TOTAL_RAM_MB TOTAL_RAM
  local RAM_TYPE RAM_SPEED RAM_INFO GPU_NAME VIDEO_RES DMIDECODE_OUTPUT SMBIOS_VER SMBIOS_INFO
  local ACPI_REV ACPI_INFO APIC_SUPPORT APIC_INFO MPS_REV MPS_INFO PAE_SUPPORT PAE_INFO
  local HT_INFO NX_INFO MMX_INFO SSE_INFO SSE2_INFO SSE3_INFO SSSE3_INFO SSE41_INFO SSE42_INFO POPCNT_INFO AVX_INFO AVX2_INFO TMP_INF

  CPU_WIDTH=$(lscpu | awk -F: '/CPU op-mode/ {print $2}' | grep -o '64-bit')
  if [[ -n "$CPU_WIDTH" ]]; then
    SYSARCH="System Architecture: x86-64 (64-Bit)"
  else
    SYSARCH="System Architecture: x86-32 (32-Bit)"
  fi
  
  CPU_NAME=$(sudo grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed 's/^[ \t]*//')
  
  local lscpu_out
  lscpu_out=$(LC_ALL=C sudo lscpu 2>/dev/null)

  # Total Threads (Logical Processors) -> CPU(s)
  CPU_THREADS=$(echo "$lscpu_out" | awk -F: '/^CPU\(s\):/ {print $2}' | xargs)

  # Total Physical Cores -> Socket(s) * Core(s) per socket
  local cores_per_socket sockets
  cores_per_socket=$(echo "$lscpu_out" | awk -F: '/^Core\(s\) per socket:/ {print $2}' | xargs)
  sockets=$(echo "$lscpu_out" | awk -F: '/^Socket\(s\):/ {print $2}' | xargs)

  # Calculate total physical cores if both values are valid integers
  if [[ -n "$cores_per_socket" && -n "$sockets" && "$cores_per_socket" =~ ^[0-9]+$ && "$sockets" =~ ^[0-9]+$ ]]; then
    CPU_CORES=$((cores_per_socket * sockets))
  else
    # Fallback to threads count if VM or hypervisor omits socket topology
    CPU_CORES="$CPU_THREADS"
  fi

  # Fallback checks if variables are empty
  [[ -z "$CPU_CORES" ]] && CPU_CORES="Unknown"
  [[ -z "$CPU_THREADS" ]] && CPU_THREADS="Unknown"

  TOTAL_RAM_KB=$(sudo dmesg | grep Memory: | awk -F'[/K]' '{print $3}')
  TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
  ((TOTAL_RAM_MB++))

  if [[ $TOTAL_RAM_MB -ge 1048576 ]]; then
    TOTAL_RAM="$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_MB/1024/1024}") TB (${TOTAL_RAM_MB} MB)"
  elif [[ $TOTAL_RAM_MB -ge 1024 ]]; then
    TOTAL_RAM="$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_MB/1024}") GB (${TOTAL_RAM_MB} MB)"
  else
    TOTAL_RAM="${TOTAL_RAM_MB} MB"
  fi

  RAM_TYPE=$(sudo dmidecode -t memory 2>/dev/null | sudo grep -i "^[[:space:]]*Type:" 2>/dev/null | head -n1 | awk -F': ' '{print $2}')
  RAM_SPEED=$(sudo dmidecode -t memory 2>/dev/null | sudo grep -i "^[[:space:]]*Speed:" 2>/dev/null | head -n1 | awk -F': ' '{print $2}')
  [[ -n "$RAM_TYPE" ]] && RAM_TYPE=" ${RAM_TYPE}"
  [[ -n "$RAM_SPEED" ]] && RAM_SPEED=" ${RAM_SPEED} MHz"
  RAM_INFO="$TOTAL_RAM$RAM_TYPE$RAM_SPEED"

  GPU_NAME=$(sudo lspci 2>/dev/null | grep -i 'VGA' | grep -vi 'non-vga' | head -n1 | cut -d: -f3- | sed 's/^[ \t]*//')
  VIDEO_RES=$(get_video_resolution)
  [[ -z "$VIDEO_RES" ]] && VIDEO_RES="Unknown"

  DMIDECODE_OUTPUT=$(sudo dmidecode)
  SMBIOS_VER=$(echo "$DMIDECODE_OUTPUT" | grep -i "SMBIOS" | grep -i "present" | sed -E 's/.*SMBIOS[[:space:]]+([0-9]+\.[0-9]+).*/\1/')
  if [[ -n "$SMBIOS_VER" ]]; then
    SMBIOS_INFO="System Management BIOS (SMBIOS) Version $SMBIOS_VER"
  elif echo "$DMIDECODE_OUTPUT" | grep -i "No SMBIOS nor DMI entry point found"; then
    SMBIOS_INFO="System Management BIOS (SMBIOS) is Not Supported"
  else
    SMBIOS_INFO="System Management BIOS (SMBIOS) is Supported"
  fi

  ACPI_REV=$(check_acpi)
  if [[ "$ACPI_REV" == "No" ]]; then
    ACPI_INFO="Advanced Configuration and Power Interface (ACPI) is Not Supported"
  elif [[ "$ACPI_REV" == "Yes" ]]; then
    ACPI_INFO="Advanced Configuration and Power Interface (ACPI) is Supported"
  else
    ACPI_INFO="Advanced Configuration and Power Interface (ACPI) Revision $ACPI_REV"
  fi

  APIC_SUPPORT=$(check_apic)
  if [[ "$APIC_SUPPORT" == "Yes" ]]; then
    APIC_INFO="Advanced Programmable Interrupt Controller (APIC) is Supported"
  else
    APIC_INFO="Advanced Programmable Interrupt Controller (APIC) is Not Supported"
  fi

  MPS_REV=$(check_mps)
  if [[ "$MPS_REV" == "No" ]]; then
    MPS_INFO="Multiprocessor Specification (MPS) is Not Supported"
  elif [[ "$MPS_REV" == "Yes" ]]; then
    MPS_INFO="Multiprocessor Specification (MPS) is Supported"
  else
    MPS_INFO="Multiprocessor Specification (MPS) Revision $MPS_REV"
  fi

  PAE_SUPPORT=$(check_pae)
  if [[ "$PAE_SUPPORT" == "Yes" ]]; then
    PAE_INFO="Physical Address Extension (PAE) is Supported"
  else
    PAE_INFO="Physical Address Extension (PAE) is Not Supported"
  fi

  HT_INFO="Hyper-Threading Technology (HT Flag): $(check_ht)"
  NX_INFO="No-Execute Memory Protection (NX/XD Flag): $(check_nx)"

  MMX_INFO="MultiMedia Extensions Instruction Set (MMX): $(check_mmx)"
  SSE_INFO="Streaming SIMD Extensions 1 (SSE): $(check_sse)"
  SSE2_INFO="Streaming SIMD Extensions 2 (SSE2): $(check_sse2)"
  SSE3_INFO="Streaming SIMD Extensions 3 (SSE3/PNI): $(check_sse3)"
  SSSE3_INFO="Supplemental Streaming SIMD Extensions 3 (SSSE3): $(check_ssse3)"
  SSE41_INFO="Streaming SIMD Extensions 4.1 (SSE4.1): $(check_sse4_1)"
  SSE42_INFO="Streaming SIMD Extensions 4.2 (SSE4.2): $(check_sse4_2)"
  POPCNT_INFO="Population Count Instruction (POPCNT): $(check_popcnt)"
  AVX_INFO="Advanced Vector Extensions 1.0 (AVX): $(check_avx)"
  AVX2_INFO="Advanced Vector Extensions 2.0 (AVX2): $(check_avx2)"

  TMP_INF="/tmp/sysinfo_summary.txt"

  printf "%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n%s\n\n-- CPU Instruction Set Architecture Features --\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n" \
    "$SYSARCH" "$CPU_NAME" "CPU Cores / Threads: $CPU_CORES / $CPU_THREADS" "RAM: $RAM_INFO" "GPU: $GPU_NAME" "Video Resolution: $VIDEO_RES" \
    "$SMBIOS_INFO" "$ACPI_INFO" "$APIC_INFO" "$MPS_INFO" "$PAE_INFO" "$HT_INFO" "$NX_INFO" "$MMX_INFO" "$SSE_INFO" "$SSE2_INFO" \
    "$SSE3_INFO" "$SSSE3_INFO" "$SSE41_INFO" "$SSE42_INFO" "$POPCNT_INFO" "$AVX_INFO" "$AVX2_INFO" > "$TMP_INF"

  dialog --backtitle "System Information (Use Up/Down to Scroll)" --title "Hardware Summary" --textbox "$TMP_INF" 22 80
  sudo rm -f "$TMP_INF"
}
