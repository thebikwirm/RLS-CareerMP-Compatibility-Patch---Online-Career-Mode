@echo off
setlocal
cd /d "%~dp0"

rem Standalone RLS West Coast map exporter. Does NOT run build.bat or alter full RLS.
set "SERVER=D:\beamng_server"
set "INFO=%~dp0rls-map-info.json"

echo ==========================================
echo  RLS WEST COAST MAP RESOURCE EXPORT
echo ==========================================
echo.
echo Server: %SERVER%
echo.
if not exist "%~dp0scripts\split_rls_west_coast_map.py" (
  echo ERROR: Map export Python script not found.
  goto :fail
)
if not exist "%SERVER%\Resources\Client\rls_career_overhaul_v2.8.0_beta.zip" (
  echo ERROR: Full server RLS ZIP missing.
  goto :fail
)
if not exist "%INFO%" (
  echo INFO.JSON REQUIRED.
  echo Put a reviewed map info.json at:
  echo   %INFO%
  echo Or enter the full path to an existing reviewed info.json below.
  echo.
  set /p "INFO=Info.json path: "
)
if not exist "%INFO%" (
  echo ERROR: Info.json file not found.
  goto :fail
)
echo.
echo Checking source ZIP and preparing map resource without changes...
python "%~dp0scripts\split_rls_west_coast_map.py" --server-root "%SERVER%" --info-json "%INFO%"
if errorlevel 1 goto :fail

echo.
echo Source check passed. The full RLS ZIP will NOT be modified.
echo The new map ZIP will contain duplicate level assets from RLS.
echo.
choice /C YN /N /M "Install additional rls_west_coast.zip to server Resources\Client? [Y/N]: "
if errorlevel 2 goto :cancel
if errorlevel 1 goto :install
goto :cancel

:install
python "%~dp0scripts\split_rls_west_coast_map.py" --server-root "%SERVER%" --info-json "%INFO%" --install
if errorlevel 1 goto :fail
echo.
echo Map ZIP installed. Restart the BeamMP server to test.
pause
exit /b 0

:cancel
echo Nothing installed.
pause
exit /b 0

:fail
echo.
echo Map export failed. No complete RLS ZIP was modified.
pause
exit /b 1
