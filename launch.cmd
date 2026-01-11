@echo off
setlocal

set BASE=%~dp0
if not exist "%BASE%current.txt" (
  echo [ERROR] current.txt not found. Run update.ps1 first.
  exit /b 1
)

set /p VER=<"%BASE%current.txt"

set CODE="%BASE%versions\%VER%\Code.exe"
if not exist %CODE% (
  echo [ERROR] Code.exe not found: %CODE%
  echo Check versions folder or rerun update.ps1.
  exit /b 1
)

start "" /B %CODE% ^
  --user-data-dir "%BASE%data\current\user-data" ^
  --extensions-dir "%BASE%data\current\extensions"

endlocal
