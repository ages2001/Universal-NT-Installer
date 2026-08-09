#!/bin/bash

# tools.sh - Tools menu
INSTLR_DEVICE="$1"
SCRIPTS_DIR="./scripts"

if [[ -z "$INSTLR_DEVICE" ]]; then
  dialog --msgbox "Missing required argument(s)!" 7 50
  exit 1
fi

while true; do
  ACTION=$(dialog --clear --backtitle "Tools" \
    --title "Tools" \
    --menu "Choose an option:" 16 60 9 \
    1 "System Information" \
    2 "Disk/Partition Manager" \
    3 "Partition Formatter" \
    4 "MBR/PBR Boot Record Manager" \
    5 "Disk MBR/GPT Converter" \
    6 "Partition (MBR) CHS/LBA Converter" \
    7 "Disk (MBR) Partition ID Repair Tool" \
    8 "CSMWrap Installer" \
    9 "Text Editor" 3>&1 1>&2 2>&3)
  
  # Safe check execution immediately following the dialog pipe closure
  [[ $? -ne 0 || -z "$ACTION" ]] && break

  case "$ACTION" in
    1)
      bash -c "source '$SCRIPTS_DIR/sysinfo.sh'; show_system_info"
      ;;
    2)
      bash "$SCRIPTS_DIR/partedit.sh" "$INSTLR_DEVICE"
      ;;
    3)
      bash "$SCRIPTS_DIR/partfrmt.sh" "$INSTLR_DEVICE"
      ;;
    4)
      while true; do
        BR_ACTION=$(dialog --clear --backtitle "MBR/PBR Boot Record Manager" \
          --title "Select Target Layer" \
          --menu "Choose boot signature deployment area:" 9 55 2 \
          1 "Fix Disk MBR (Master Boot Record)" \
          2 "Fix Partition PBR (Partition Boot Record)" 3>&1 1>&2 2>&3)

        [[ $? -ne 0 || -z "$BR_ACTION" ]] && break

        case "$BR_ACTION" in
          1) bash "$SCRIPTS_DIR/fixmbr.sh" "$INSTLR_DEVICE" ;;
          2) bash "$SCRIPTS_DIR/fixpbr.sh" "$INSTLR_DEVICE" ;;
        esac
      done
      ;;
    5)
      bash "$SCRIPTS_DIR/mbrgpt.sh" "$INSTLR_DEVICE"
      ;;
    6)
      bash "$SCRIPTS_DIR/chslba.sh" "$INSTLR_DEVICE"
      ;;
	7)
      bash "$SCRIPTS_DIR/fixprtid.sh" "$INSTLR_DEVICE"
      ;;
	8)
      bash "$SCRIPTS_DIR/csmwrapins.sh" "$INSTLR_DEVICE"
      ;;
	9)
      bash "$SCRIPTS_DIR/textedit.sh" "$INSTLR_DEVICE"
      ;;
  esac
done
