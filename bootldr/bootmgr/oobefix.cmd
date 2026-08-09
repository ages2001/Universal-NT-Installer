@echo off

reg add "HKLM\SYSTEM\Setup" /v OOBEInProgress /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v SetupPhase /t REG_DWORD /d 0 /f
reg delete "HKLM\SYSTEM\Setup" /v SetupShutdownRequired /f >nul 2>&1
reg add "HKLM\SYSTEM\Setup" /v SetupType /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v SystemSetupInProgress /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\Setup" /v CmdLine /t REG_SZ /d "" /f

bcdedit /import C:\BCDBKP
attrib -h -r -s C:\BCDBKP
del /f /q C:\BCDBKP
attrib -h -r -s C:\BCDBKP.LOG
del /f /q C:\BCDBKP.LOG

shutdown -r -t 0
