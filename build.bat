@echo off
setlocal
cd /d "%~dp0"

set "BUILDROOT=C:\Users\Carl\source\repos\thebikwirm\RLS-CareerMP-Compatibility-Patch---Online-Career-Mode\built-039"
set "SERVER=D:\beamng_server"

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
set "RLS_ARG="
if defined RLS (
  echo RLS:      %RLS%
  set "RLS_ARG=--rls-original ^"%RLS%^""
) else (
  echo RLS:      [missing - rebuild skipped]
)

set "CAREERMP_ARG="
if defined CAREERMP (
  echo CareerMP: %CAREERMP%
  set "CAREERMP_ARG=--careermp-039 ^"%CAREERMP%^""
) else (
  echo CareerMP: [missing - rebuild skipped]
)

set "BEAMMP_ARG="
if defined BEAMMP (
  echo BeamMP:   %BEAMMP%
  set "BEAMMP_ARG=--beammp-original ^"%BEAMMP%^""
) else (
  echo BeamMP:   [missing - rebuild skipped]
)

echo.
python .\scripts\build_release_039.py ^
  %RLS_ARG% ^
  %CAREERMP_ARG% ^
  %BEAMMP_ARG% ^
  --server-root "%SERVER%" ^
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
