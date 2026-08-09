@echo off

bcdedit /import C:\BCDBKP
attrib -h -r -s C:\BCDBKP
del /f /q C:\BCDBKP
attrib -h -r -s C:\BCDBKP.LOG
del /f /q C:\BCDBKP.LOG
