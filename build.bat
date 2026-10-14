@echo off
setlocal
cd /d "%~dp0"

set "BUILDROOT=C:\BeamNG-Mod-Build"
set "SERVER=D:\beamng_server"

rem Prefer the clean source archive, then known compatibility filename,
rem then fall back to any RLS career-overhaul zip in the build folder.
set "RLS="
if exist "%BUILDROOT%\rls_career_overhaul_2.6.7.zip" set "RLS=%BUILDROOT%\rls_career_overhaul_2.6.7.zip"
if not defined RLS if exist "%BUILDROOT%\rls_career_overhaul_2.6.7_careermp_compatible.zip" set "RLS=%BUILDROOT%\rls_career_overhaul_2.6.7_careermp_compatible.zip"
if not defined RLS (
  for %%F in ("%BUILDROOT%\rls_career_overhaul*.zip") do (
    if not defined RLS set "RLS=%%~fF"
  )
)

set "CAREERMP="
if exist "%BUILDROOT%\CareerMP.zip" set "CAREERMP=%BUILDROOT%\CareerMP.zip"

set "BEAMMP="
if exist "%BUILDROOT%\BeamMP.zip" set "BEAMMP=%BUILDROOT%\BeamMP.zip"

echo.
echo ==========================================
echo  RLS + CareerMP + BeamMP 0.39.4 Builder
echo ==========================================
echo.
echo Build root: %BUILDROOT%
echo Server:     %SERVER%
echo.

if not defined RLS (
  echo ERROR: No RLS input zip found.
  echo Expected something matching:
  echo   %BUILDROOT%\rls_career_overhaul*.zip
  goto :fail
)

if not defined CAREERMP (
  echo ERROR: CareerMP.zip not found:
  echo   %BUILDROOT%\CareerMP.zip
  goto :fail
)

if not defined BEAMMP (
  echo ERROR: BeamMP.zip not found:
  echo   %BUILDROOT%\BeamMP.zip
  goto :fail
)

echo RLS:      %RLS%
echo CareerMP: %CAREERMP%
echo BeamMP:   %BEAMMP%
echo.

python .\scripts\build_release_039.py ^
  --rls-original "%RLS%" ^
  --careermp-039 "%CAREERMP%" ^
  --beammp-original "%BEAMMP%" ^
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
