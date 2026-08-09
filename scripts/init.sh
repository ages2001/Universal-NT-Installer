#!/bin/bash

# Check for dialog
command -v dialog >/dev/null 2>&1 || {
  echo "This script requires 'dialog'."
  exit 1
}

INSTLR_DEVICE="$1"
OSFILES_DIR="/mnt/uwifiles/osfiles"
OS_CFG="./configs/os_list.cfg"
EDITION_CFG="./configs/edition_list.cfg"
SCRIPTS_DIR="./scripts"

source "./scripts/sysinfo.sh"

# Helper function to dynamically compute dialog geometry
calc_menu_dimensions() {
  local items_count="$1"
  local max_str_len="$2"

  local menu_rows=$items_count
  [[ $menu_rows -lt 3 ]] && menu_rows=3
  [[ $menu_rows -gt 12 ]] && menu_rows=12

  local menu_height=$((items_count + 7))
  [[ $menu_height -lt 10 ]] && menu_height=10
  [[ $menu_height -gt 20 ]] && menu_height=20

  local menu_width=$((max_str_len + 9))
  [[ $menu_width -lt 50 ]] && menu_width=50
  [[ $menu_width -gt 80 ]] && menu_width=80

  echo "$menu_height $menu_width $menu_rows"
}

# Check if OS archives exist
if [[ ! -d "$OSFILES_DIR" || -z "$(ls -A "$OSFILES_DIR" 2>/dev/null)" ]]; then
  echo "Installation files not found in $OSFILES_DIR."
  exit 1
fi

while true; do
  # === Main Menu ===
  ACTION=$(dialog --clear --backtitle "Welcome to the Universal Windows Installer!" \
    --title "Main Menu" \
    --nocancel \
    --menu "Please choose an option:" 12 50 5 \
    1 "Install OS" \
    2 "Tools" \
    3 "Command Line" \
    4 "Reboot" \
    5 "About" \
    3>&1 1>&2 2>&3)

  case "$ACTION" in
    1)
      while true; do
        INSTALL_MODE=$(dialog --clear --backtitle "Install OS" \
          --title "Installation Mode" \
          --menu "Choose which installation file(s) will be scanned:" 10 50 2 \
          1 "Default Installation" \
          2 "Custom Installation" \
          3>&1 1>&2 2>&3)

        [[ $? -ne 0 || -z "$INSTALL_MODE" ]] && break
        
        case "$INSTALL_MODE" in        
          1)        
            while true; do
              # === Architecture/Type Selection ===
              OS_TYPE=$(dialog --clear --backtitle "Default Installation" \
                --title "Select OS Architecture/Type" \
                --menu "Choose the OS architecture type you want to browse:" 11 50 3 \
                1 "Install NT-based x64 Windows OS" \
                2 "Install NT-based x86 Windows OS" \
                3 "Install DOS-based Windows OS" \
                3>&1 1>&2 2>&3)

              [[ $? -ne 0 || -z "$OS_TYPE" ]] && break

              case "$OS_TYPE" in
                1) OS_CFG="./configs/nt64_os_list.cfg" DESIRED_OS="NT-based x64 Windows OS" ARCH_INFO=" x64" ;;
                2) OS_CFG="./configs/nt86_os_list.cfg" DESIRED_OS="NT-based x86 Windows OS" ARCH_INFO=" x86" ;;
                3) OS_CFG="./configs/dos_os_list.cfg" DESIRED_OS="DOS-based Windows OS" ARCH_INFO=" " ;;
              esac

              # === NT64 Immediate Hardware Checks ===
              if [[ "$OS_TYPE" -eq 1 ]]; then
                dialog --infobox "Checking 64-bit system requirements..." 3 40
                CPU_MODE=$(check_cpu_arch)
                ACPI_SUPPORT=$(check_acpi)
                APIC_SUPPORT=$(check_apic)

                if [[ "$CPU_MODE" != *64-bit* ]]; then
                  dialog --msgbox "Any NT-based x64 Windows OS requires a 64-bit capable CPU.\n\nYour system does not support 64-bit." 8 60
                  continue
                fi
                if [[ "$ACPI_SUPPORT" == "No" ]]; then
                  dialog --msgbox "Any NT-based x64 Windows OS requires an ACPI compliant system.\n\nEither your system does not support ACPI or ACPI is disabled." 8 70
                  continue
                fi
                if [[ "$APIC_SUPPORT" == "No" ]]; then
                  dialog --msgbox "Any NT-based x64 Windows OS requires an APIC compliant system.\n\nEither your system does not support APIC or APIC is disabled." 8 70
                  continue
                fi
              fi

              while true; do
                # === OS Selection ===
                dialog --infobox "Scanning files..." 3 21
        
                declare -a OS_MENU=()
                declare -A INDEX_TO_OSCODE=()
                declare -A INDEX_TO_OSDESC=()
                declare -A INDEX_TO_EXIST=()
                index=1
                max_len=0

                while IFS='=' read -r os_code os_desc; do          
                  if [[ ! -f "$OSFILES_DIR/${os_code}.WIM" ]]; then
                    continue
                  fi
                  
                  INDEX_TO_EXIST["$index"]=1
        
                  OS_MENU+=("$index" "$os_desc")
                  INDEX_TO_OSCODE["$index"]="$os_code"
                  INDEX_TO_OSDESC["$index"]="$os_desc"
                  
                  [[ ${#os_desc} -gt $max_len ]] && max_len=${#os_desc}
                  ((index++))
                done < "$OS_CFG"
                
                if [[ "$OS_TYPE" -eq 3 ]]; then
                  dialog --msgbox "DOS-based Windows OS support will be coming soon!" 6 60
                  break
                fi

                if [[ ${#OS_MENU[@]} -eq 0 ]]; then
                  dialog --msgbox "No matching WIM/ESD files found for this architecture in $OSFILES_DIR." 6 60
                  break
                fi

                # Dynamic Geometry Calculation
                items_count=$((${#OS_MENU[@]} / 2))
                read -r H W R < <(calc_menu_dimensions "$items_count" "$max_len")

                OS_SELECTED_INDEX=$(dialog --clear --backtitle "Default Installation" \
                  --title "Select Operating System" \
                  --menu "Choose $DESIRED_OS to install:" $H $W $R "${OS_MENU[@]}" 3>&1 1>&2 2>&3)

                [[ $? -ne 0 || -z "$OS_SELECTED_INDEX" ]] && break
                
                dialog --infobox "Please wait..." 3 18

                OS_CHOICE="${INDEX_TO_OSCODE[$OS_SELECTED_INDEX]}"
                OS_DESC="${INDEX_TO_OSDESC[$OS_SELECTED_INDEX]}"
                OS_SELECTED_WIM="${OS_CHOICE}.WIM"
                
                # === NT86 Specific Checks ===
                if [[ "$OS_TYPE" -eq 2 ]]; then
                  dialog --infobox "Checking OS requirements..." 3 31
                  ACPI_SUPPORT=$(check_acpi)
                  APIC_SUPPORT=$(check_apic)
                  
                  # Dynamic 486 CPU detection
                  IS_486=0
                  if lscpu 2>/dev/null | grep -q "486"; then
                    IS_486=1
                  fi
                  
                  case "$OS_CHOICE" in
                    *WIN81*|*WIN10*)
                      if [[ "$ACPI_SUPPORT" == "No" ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) requires an ACPI compliant system.\n\nEither your system does not support ACPI or ACPI is disabled." 8 70
                        continue
                      fi
                      if [[ "$APIC_SUPPORT" == "No" ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) requires an APIC compliant system.\n\nEither your system does not support APIC or APIC is disabled." 8 70
                        continue
                      fi
                      if [[ "$IS_486" -eq 1 ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) doesn't support 486 processors." 7 70
                        continue
                      fi
                      ;;
                    *VISTA*|*WIN7*|*WIN80*)
                      if [[ "$ACPI_SUPPORT" == "No" ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) requires an ACPI compliant system.\n\nEither your system does not support ACPI or ACPI is disabled." 8 70
                        continue
                      fi
                      if [[ "$IS_486" -eq 1 ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) doesn't support 486 processors." 7 70
                        continue
                      fi
                      ;;
                  esac          
                fi
                
                # Minimum memory requirements check
                if [[ "$OS_TYPE" -eq 1 || "$OS_TYPE" -eq 2 ]]; then
                  if [[ "$OS_CHOICE" == *"VISTA"* || "$OS_CHOICE" == *"WIN7"* || "$OS_CHOICE" == *"WIN8"* || "$OS_CHOICE" == *"WIN10"* || "$OS_CHOICE" == *"WIN11"* ]]; then
                    MIN_RAM=256  # 256 MiB is minimum for Vista/7 and later OSes
                    MIN_RAM_WITH_TOLERANCE=$((MIN_RAM - 8))  # 8 MiB tolerance
                    
                    CHECK_RAM=$(check_total_ram $MIN_RAM_WITH_TOLERANCE)  # -8 MiB is for tolerance
                    
                    if [[ -z "$CHECK_RAM" || "$CHECK_RAM" -eq 0 ]]; then
                        dialog --msgbox "The selected OS ($OS_DESC) requires at least $MIN_RAM MiB RAM!" 5 69
                        continue
                    fi
                  fi
                fi
                
                dialog --infobox "Please wait..." 3 18

                while true; do
                  # === Edition Selection ===
                  declare -a ED_MENU=()
                  declare -A INDEX_TO_WIM=()
                  declare -A INDEX_TO_DESC=()
                  index=1
                  max_len=0

                  while IFS='=' read -r os_code editions; do
                    if [[ "$os_code" == "$OS_CHOICE" ]]; then
                      IFS=',' read -ra ed_arr <<< "$editions"
                      for ed in "${ed_arr[@]}"; do
                        IFS=':' read -r ed_code ed_wim ed_desc <<< "$ed"
                        ED_MENU+=("$index" "$ed_desc")
                        INDEX_TO_WIM["$index"]="$ed_wim"
                        INDEX_TO_DESC["$index"]="$ed_desc"
                        
                        [[ ${#ed_desc} -gt $max_len ]] && max_len=${#ed_desc}
                        ((index++))
                      done
                    fi
                  done < "$EDITION_CFG"

                  # Dynamic Geometry Calculation
                  items_count=$((${#ED_MENU[@]} / 2))
                  read -r H W R < <(calc_menu_dimensions "$items_count" "$max_len")

                  EDITION_SELECTED_INDEX=$(dialog --clear --backtitle "Default Installation" \
                    --title "Select OS Edition" \
                    --menu "Choose edition for $OS_DESC$ARCH_INFO to install:" $H $W $R "${ED_MENU[@]}" 3>&1 1>&2 2>&3)
                    
                  [[ $? -ne 0 || -z "$EDITION_SELECTED_INDEX" ]] && break
            
                  selected_desc="${INDEX_TO_DESC[$EDITION_SELECTED_INDEX]}"
            
                  if [[ "$selected_desc" =~ Patched ]] && [[ "$selected_desc" =~ ACPI\+APIC ]]; then
                    if [[ "$selected_desc" =~ Windows\ 2000 ]]; then
                      if [[ "$ACPI_SUPPORT" == "No" ]]; then
                        dialog --msgbox "The selected OS ($selected_desc) requires an ACPI compliant system.\n\nEither your system does not support ACPI or ACPI is disabled." 8 70
                        continue
                      elif [[ "$APIC_SUPPORT" == "No" ]]; then
                        dialog --msgbox "The selected OS ($selected_desc) requires an APIC compliant system.\n\nEither your system does not support APIC or APIC is disabled." 8 70
                        continue
                      fi
                    fi
                  fi
                  
                  CPU_MODE=$(check_cpu_arch)
                  ACPI_SUPPORT=$(check_acpi)
                  APIC_SUPPORT=$(check_apic)
            
                  if [[ "$selected_desc" =~ 64 ]]; then
                    if [[ "$CPU_MODE" != *"64-bit"* ]]; then
                      dialog --msgbox "The selected OS ($selected_desc) requires a 64-bit capable CPU.\n\nYour system does not support 64-bit." 8 60
                      continue
                    elif [[ "$ACPI_SUPPORT" == "No" ]]; then
                      dialog --msgbox "The selected OS ($selected_desc) requires an ACPI compliant system.\n\nEither your system does not support ACPI or ACPI is disabled." 8 70
                      continue
                    elif [[ "$APIC_SUPPORT" == "No" ]]; then
                      dialog --msgbox "The selected OS ($selected_desc) requires an APIC compliant system.\n\nEither your system does not support APIC or APIC is disabled." 8 70
                      continue
                    fi
                  fi    
            
                  OS_SELECTED_WIM_INDEX="${INDEX_TO_WIM[$EDITION_SELECTED_INDEX]}"
                  SETUP_TYPE=0
                  WIM_IMAGE_INFO="-"

                  # === Disk and Partition Selection ===
                  bash "$SCRIPTS_DIR/selpart.sh" "$INSTLR_DEVICE" "$OS_SELECTED_WIM" "$OS_SELECTED_WIM_INDEX" "$OS_CHOICE" "$SETUP_TYPE" "$WIM_IMAGE_INFO" "$OS_TYPE"
                  SELPART_EXIT=$?

                  if [[ $SELPART_EXIT -eq 2 ]]; then
                    continue  # back to edition selection
                  fi
            
                  if [[ $SELPART_EXIT -eq 5 ]]; then
                    dialog --infobox "Rebooting..." 3 16 && exec > /dev/null 2>&1 && exec setsid reboot
                  fi

                  break 4  # break out of edition, OS, type and mode loops completely
                done
              done
            done
            ;;
            
          2)
            CUSTOM_DIR="/mnt/uwifiles/osfiles/custom"
            while true; do
              mapfile -t CUSTOM_WIMS < <(find "$CUSTOM_DIR" -maxdepth 1 -type f \( -iname "*.wim" -o -iname "*.esd" \) | sort)

              if [[ ${#CUSTOM_WIMS[@]} -eq 0 ]]; then
                dialog --msgbox "No custom WIM/ESD file(s) found in the installer 'custom' folder." 6 66
                break
              fi

              declare -a CUSTOM_MENU=()
              declare -A INDEX_TO_FILE=()
              index=1
              max_len=0

              for f in "${CUSTOM_WIMS[@]}"; do
                fname=$(basename "$f")
                CUSTOM_MENU+=("$index" "$fname")
                INDEX_TO_FILE["$index"]="$f"
                
                [[ ${#fname} -gt $max_len ]] && max_len=${#fname}
                ((index++))
              done

              # Dynamic Geometry Calculation
              items_count=$((${#CUSTOM_MENU[@]} / 2))
              read -r H W R < <(calc_menu_dimensions "$items_count" "$max_len")

              FILE_SELECTED_INDEX=$(dialog --clear --backtitle "Custom Installation" \
                --title "Select WIM/ESD File" \
                --menu "Choose a custom WIM/ESD file to install:" $H $W $R "${CUSTOM_MENU[@]}" \
                3>&1 1>&2 2>&3)

              [[ $? -ne 0 || -z "$FILE_SELECTED_INDEX" ]] && break

              SELECTED_FILE="${INDEX_TO_FILE[$FILE_SELECTED_INDEX]}"

              WIMINFO_OUTPUT=$(wiminfo "$SELECTED_FILE" 2>&1)
              if echo "$WIMINFO_OUTPUT" | grep -q "ERROR"; then
                dialog --msgbox "The selected WIM/ESD file is invalid or corrupt:\n\n$(basename "$SELECTED_FILE")" 7 60
                continue
              fi

              declare -a IMAGE_MENU=()
              declare -A INDEX_TO_WIMINDEX=()
              declare -A INDEX_TO_NAME=()
              img_idx=1
              max_len=0
              
              WIM_IMAGE_INFO=""

              while read -r line; do
                if [[ "$line" =~ ^Index:\ +([0-9]+) ]]; then
                  current_index="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^Name:\ +(.*) ]]; then
                  current_name="${BASH_REMATCH[1]}"
                  
                  WIM_IMAGE_INFO="Image $current_index - $current_name"
                  IMAGE_MENU+=("$img_idx" "$WIM_IMAGE_INFO")
                  INDEX_TO_WIMINDEX["$img_idx"]="$current_index"
                  INDEX_TO_NAME["$img_idx"]="$current_name"
                  
                  [[ ${#WIM_IMAGE_INFO} -gt $max_len ]] && max_len=${#WIM_IMAGE_INFO}
                  ((img_idx++))
                fi
              done <<< "$WIMINFO_OUTPUT"

              if [[ ${#IMAGE_MENU[@]} -eq 0 ]]; then
                dialog --msgbox "No valid images found in the selected WIM/ESD file." 7 60
                continue
              fi

              # Dynamic Geometry Calculation
              items_count=$((${#IMAGE_MENU[@]} / 2))
              read -r H W R < <(calc_menu_dimensions "$items_count" "$max_len")

              while true; do
                IMAGE_SELECTED_INDEX=$(dialog --clear --backtitle "Custom Installation" \
                  --title "Select WIM/ESD Image" \
                  --menu "Choose an image to install from $(basename "$SELECTED_FILE"):" $H $W $R "${IMAGE_MENU[@]}" \
                  3>&1 1>&2 2>&3)

                [[ $? -ne 0 || -z "$IMAGE_SELECTED_INDEX" ]] && break

                OS_SELECTED_WIM="$(basename "$SELECTED_FILE")"
                OS_SELECTED_WIM_INDEX="${INDEX_TO_WIMINDEX[$IMAGE_SELECTED_INDEX]}"
                OS_SELECTED_WIM_IMAGE_NAME="${INDEX_TO_NAME[$IMAGE_SELECTED_INDEX]}"
                OS_CHOICE="Custom"
                SETUP_TYPE=1
                SELECTED_WIM_IMAGE_INFO="Image $OS_SELECTED_WIM_INDEX - $OS_SELECTED_WIM_IMAGE_NAME"
                DEFAULT_OS_TYPE=0

                # === Partition Selection ===
                bash "$SCRIPTS_DIR/selpart.sh" "$INSTLR_DEVICE" "$OS_SELECTED_WIM" "$OS_SELECTED_WIM_INDEX" "$OS_CHOICE" "$SETUP_TYPE" "$SELECTED_WIM_IMAGE_INFO" "$DEFAULT_OS_TYPE"
                SELPART_EXIT=$?

                if [[ $SELPART_EXIT -eq 2 ]]; then
                  continue
                fi

                if [[ $SELPART_EXIT -eq 5 ]]; then
                  dialog --infobox "Rebooting..." 3 16 && exec > /dev/null 2>&1 && exec setsid reboot
                fi
                
                break 3  # break out of both image + WIM/ESD selection + install type selection
              done
            done
            ;;
        esac
      done
      ;;
    2)
      bash "$SCRIPTS_DIR/tools.sh" "$INSTLR_DEVICE"
      ;;
    3)
      clear
      sudo -u tc bash
      ;;
    4)
      dialog --yesno "Do you want to reboot the computer now?" 7 50
      [[ $? -eq 0 ]] && dialog --infobox "Rebooting..." 3 16 && exec > /dev/null 2>&1 && exec setsid reboot
      ;;
      
    5)
      dialog --backtitle "Universal Windows Installer (2026)" \
        --title "About" \
        --msgbox "\
Version: v0.3.0-beta\n\
Made by: ages2001\n\
Website: https://www.github.com/ages2001/Universal-Windows-Installer \n\n\
A lightweight Linux-based installer for all\n\
Windows NT-based and DOS-based versions; supporting partitioning,\n\
formatting, sysprepped image deployment and more!\n\
Installs in seconds on both modern and legacy systems." 13 70
      ;;
  esac
done
