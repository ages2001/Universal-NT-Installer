#!/bin/bash

# Check for dialog
command -v dialog >/dev/null 2>&1 || {
  echo "This script requires 'dialog'."
  exit 1
}

MOUNT_DEVICE="$1"
OSFILES_DIR="/mnt/isofiles/osfiles"
OS_CFG="./os_list.cfg"
EDITION_CFG="./edition_list.cfg"
SCRIPTS_DIR="./scripts"

# Check if OS archives exist
if [[ ! -d "$OSFILES_DIR" || -z "$(ls -A "$OSFILES_DIR" 2>/dev/null)" ]]; then
  echo "Installation files not found in $OSFILES_DIR."
  exit 1
fi

while true; do
  # === Main Menu ===
  ACTION=$(dialog --clear --backtitle "Windows NT Installer" \
    --title "Welcome" \
    --nocancel \
    --menu "Welcome to the Windows NT Multi-Installer.\nPlease choose an option:" 12 50 4 \
    1 "Select OS to Install" \
    2 "Partition Manager" \
    3 "Command Line" \
    4 "Exit and Reboot" \
    3>&1 1>&2 2>&3)

  case "$ACTION" in
    1)
      while true; do
        # === OS Selection ===
        declare -a OS_MENU=()
        declare -A INDEX_TO_OSCODE=()
        declare -A INDEX_TO_OSDESC=()
        index=1

        while IFS='=' read -r os_code os_desc; do
          OS_MENU+=("$index" "$os_desc")
          INDEX_TO_OSCODE["$index"]="$os_code"
          INDEX_TO_OSDESC["$index"]="$os_desc"
          ((index++))
        done < "$OS_CFG"

        OS_SELECTED_INDEX=$(dialog --clear --backtitle "Windows NT Installer" \
          --title "Select Operating System" \
          --menu "Choose an OS to install:" 15 50 7 "${OS_MENU[@]}" 3>&1 1>&2 2>&3)

        [[ $? -ne 0 || -z "$OS_SELECTED_INDEX" ]] && break

        OS_CHOICE="${INDEX_TO_OSCODE[$OS_SELECTED_INDEX]}"
        
		# === CPU Compatibility Check for x64 OS codes ===
  	    if [[ "$OS_CHOICE" == *"64"* ]]; then
		  CPU_MODE=$(lscpu | grep -i 'CPU op-mode' | awk -F: '{print $2}' | xargs)
	      if [[ "$CPU_MODE" != *"64-bit"* ]]; then
	        dialog --msgbox "The selected OS (${INDEX_TO_OSDESC[$OS_SELECTED_INDEX]}) requires a 64-bit capable CPU.\nYour system does not support 64-bit." 8 60
	        continue
	      fi
	    fi

        while true; do
          # === Edition Selection ===
          declare -a ED_MENU=()
          declare -A INDEX_TO_ZIP=()
          index=1

          while IFS='=' read -r os_code editions; do
            if [[ "$os_code" == "$OS_CHOICE" ]]; then
              IFS=',' read -ra ed_arr <<< "$editions"
              for ed in "${ed_arr[@]}"; do
                IFS=':' read -r ed_code ed_zip ed_desc <<< "$ed"
                ED_MENU+=("$index" "$ed_desc")
                INDEX_TO_ZIP["$index"]="$ed_zip"
                ((index++))
              done
            fi
          done < "$EDITION_CFG"

          EDITION_SELECTED_INDEX=$(dialog --clear --backtitle "Windows NT Installer" \
            --title "Select Edition" \
            --menu "Choose edition:" 10 60 4 "${ED_MENU[@]}" 3>&1 1>&2 2>&3)

          [[ $? -ne 0 || -z "$EDITION_SELECTED_INDEX" ]] && break

          EDITION_SELECTED_ZIP="${INDEX_TO_ZIP[$EDITION_SELECTED_INDEX]}.tar.gz"

          if [[ ! -f "$OSFILES_DIR/$EDITION_SELECTED_ZIP" ]]; then
            dialog --msgbox "File not found: $OSFILES_DIR/$EDITION_SELECTED_ZIP" 7 60
            continue
          fi

          # === Partition Selection ===
          bash "$SCRIPTS_DIR/selpart.sh" "$EDITION_SELECTED_ZIP" "$OS_CHOICE"
          SELPART_EXIT=$?

          if [[ $SELPART_EXIT -eq 2 ]]; then
            continue  # back to edition selection
          fi
          
          if [[ $SELPART_EXIT -eq 5 ]]; then
            dialog --infobox "Rebooting..." 3 16 && exec > /dev/null 2>&1 && exec setsid reboot
          fi

          break 2  # break out of both edition + OS selection
        done
      done
      ;;
    2)
      while true; do
        PM_ACTION=$(dialog --clear --backtitle "Partition Manager" \
          --title "Partition Manager" \
          --menu "Choose an option:" 12 50 2 \
          1 "Partition Editor" \
          2 "Partition Formatter" \
          3>&1 1>&2 2>&3)

        # If cancel pressed or empty input, exit from menu
        if [[ $? -ne 0 || -z "$PM_ACTION" ]]; then
          break
        fi

        case "$PM_ACTION" in
          1)
            bash "$SCRIPTS_DIR/partedit.sh"
            ;;
          2)
            bash "$SCRIPTS_DIR/partfrmt.sh"
            ;;
        esac
      done
      ;;
    3)
      clear
      bash
      ;;
    4)
      dialog --yesno "Do you want to reboot the system now?" 7 50
      [[ $? -eq 0 ]] && dialog --infobox "Rebooting..." 3 16 && exec > /dev/null 2>&1 && exec setsid reboot
      ;;
  esac
done

