@echo off

bcdedit /import C:\BCDBKP
attrib -h -r -s C:\BCDBKP.LOG
del /f /q C:\BCDBKP.LOG

attrib -h -r -s C:\Windows\System32\drivers\acpi.sys
takeown /f "C:\Windows\System32\drivers\acpi.sys" /d y
icacls "C:\Windows\System32\drivers\acpi.sys" /grant administrators:F /q
move /y "C:\acpi.sys" "C:\Windows\System32\drivers\acpi.sys"
