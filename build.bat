@echo off
setlocal
cd /d "%~dp0"

set "BUILDROOT=C:\Users\Carl\source\repos\thebikwirm\RLS-CareerMP-Compatibility-Patch---Online-Career-Mode\built-039"
set "SERVER=D:\beamng_server"
set "BEAMMP_CLIENT=D:\beamng stuff\current\mods\multiplayer\BeamMP.zip"

rem Prefer the clean source archive, then known compatibility filename,
rem then fall back to any RLS career-overhaul zip in the build folder.
set "RLS="
if exist "%BUILDROOT%\rls_career_overhaul_2.6.7.zip" set "RLS=%BUILDROOT%\rls_career_overhaul_2.6.7.zip"
if not defined RLS if exist "%BUILDROOT%\rls_career_overhaul_2.6.7_careermp_compatible.zip" set "RLS=%BUILDROOT%\rls_career_overhaul_2.6.7_careermp_compatible.zip"
if not defined RLS (
  for %%F in ("%BUILDROOT%\rls_career_overhaul*.zip") do (
    if exist "%%~fF" if not defined RLS set "RLS=%%~fF"
  )
)

set "CAREERMP="
if exist "%BUILDROOT%\CareerMP.zip" set "CAREERMP=%BUILDROOT%\CareerMP.zip"

set "BEAMMP="
if exist "%BUILDROOT%\BeamMP.zip" set "BEAMMP=%BUILDROOT%\BeamMP.zip"
if defined RLS (
  echo RLS:      %RLS%
) else (
  set "RLS=%BUILDROOT%\rls_career_overhaul_2.6.7.zip"
  echo RLS:      [missing - rebuild skipped]
)

if defined CAREERMP (
  echo CareerMP: %CAREERMP%
) else (
  set "CAREERMP=%BUILDROOT%\CareerMP.zip"
  echo CareerMP: [missing - rebuild skipped]
)

if defined BEAMMP (
  echo BeamMP:   %BEAMMP%
) else (
  set "BEAMMP=%BUILDROOT%\BeamMP.zip"
  echo BeamMP:   [missing - client patch rebuild skipped]
)

echo.
python .\scripts\build_release_039.py ^
  --rls-original "%RLS%" ^
  --careermp-039 "%CAREERMP%" ^
  --beammp-original "%BEAMMP%" ^
  --server-root "%SERVER%" ^
  --beammp-client-target "%BEAMMP_CLIENT%" ^
  --rls-install-name "rls_career_overhaul_2.6.7_careermp_compatible.zip" ^
  --zip-engine python

if errorlevel 1 goto :fail

echo.
echo ==========================================
echo  BUILD COMPLETE
echo ==========================================
echo.
echo Patched files are in:
echo   %~dp0built-039
echo.
echo Installed server resources are in:
echo   %SERVER%\Resources\Client
echo.
pause
exit /b 0

:fail
echo.
echo ==========================================
echo  BUILD FAILED
echo ==========================================
echo.
pause
exit /b 1
