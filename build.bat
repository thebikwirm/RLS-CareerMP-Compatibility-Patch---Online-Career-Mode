@echo off
setlocal
cd /d "%~dp0"

set "RLS=C:\BeamNG-Mod-Build\rls_career_overhaul_2.6.7.zip"
set "CAREERMP=C:\BeamNG-Mod-Build\CareerMP.zip"
set "BEAMMP=C:\BeamNG-Mod-Build\BeamMP.zip"
set "SERVER=D:\beamng_server"

echo.
echo ==========================================
echo  RLS + CareerMP + BeamMP 0.39.4 Builder
echo ==========================================
echo.
echo RLS:      %RLS%
echo CareerMP: %CAREERMP%
echo BeamMP:   %BEAMMP%
echo Server:   %SERVER%
echo.

python .\scripts\build_release_039.py ^
  --rls-original "%RLS%" ^
  --careermp-039 "%CAREERMP%" ^
  --beammp-original "%BEAMMP%" ^
  --server-root "%SERVER%" ^
  --rls-install-name "rls_career_overhaul_2.6.7_careermp_compatible.zip" ^
  --zip-engine python

if errorlevel 1 (
  echo.
  echo ==========================================
  echo  BUILD FAILED
  echo ==========================================
  pause
  exit /b 1
)

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
