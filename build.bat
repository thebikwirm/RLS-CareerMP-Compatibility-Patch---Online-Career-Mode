@echo off
setlocal

cd /d "%~dp0"

set "RLS=D:\beamng_server\Resources\Client\rls_career_overhaul_2.6.7_careermp_compatible.zip"
set "CAREERMP=D:\beamng_server\Resources\Client\CareerMP.zip"
set "SERVER=D:\beamng_server"

python .\scripts\build_release_039.py ^
  --rls-original "%RLS%" ^
  --careermp-039 "%CAREERMP%" ^
  --server-root "%SERVER%" ^
  --rls-install-name "rls_career_overhaul_2.6.7_careermp_compatible.zip"

if errorlevel 1 (
    echo.
    echo BUILD FAILED
    pause
    exit /b 1
)

echo.
echo BUILD COMPLETE
pause