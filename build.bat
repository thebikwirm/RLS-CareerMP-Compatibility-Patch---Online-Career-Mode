@echo off
setlocal
cd /d "%~dp0"

rem BeamNG 0.40 / RLS 2.8 beta + CareerMP experimental builder.
rem Never overwrite BeamMP.zip, installed mods, or server resources automatically.
set "BUILDROOT=%~dp0built-040-experimental"
set "RLS=%~dp0rls_career_overhaul_v2.8.0_beta.zip"
set "CAREERMP=%~dp0CareerMP.zip"
set "SERVER_LUA=%~dp0careerMP.lua"

rem Also accept original inputs in the builds folder for convenience.
if not exist "%RLS%" if exist "%BUILDROOT%\rls_career_overhaul_v2.8.0_beta.zip" set "RLS=%BUILDROOT%\rls_career_overhaul_v2.8.0_beta.zip"
if not exist "%CAREERMP%" if exist "%BUILDROOT%\CareerMP.zip" set "CAREERMP=%BUILDROOT%\CareerMP.zip"
if not exist "%SERVER_LUA%" if exist "%BUILDROOT%\careerMP.lua" set "SERVER_LUA=%BUILDROOT%\careerMP.lua"

if not exist "%RLS%" (
  echo Missing original RLS 2.8.0 beta ZIP:
  echo   %RLS%
  goto :fail
)
if not exist "%CAREERMP%" (
  echo Missing original CareerMP client ZIP:
  echo   %CAREERMP%
  goto :fail
)
if not exist "%SERVER_LUA%" (
  echo Missing original CareerMP server Lua:
  echo   %SERVER_LUA%
  goto :fail
)

echo.
echo RLS source:       %RLS%
echo CareerMP client:  %CAREERMP%
echo CareerMP server:  %SERVER_LUA%
echo Output directory: %BUILDROOT%
echo.
echo This is a source-validated but NOT in-game-tested experimental build.
echo Files will NOT be installed automatically.
echo.

python scripts\verify_rls_280_source.py
if errorlevel 1 goto :fail
python scripts\verify_rls_280_careermp.py
if errorlevel 1 goto :fail
python scripts\verify_rls_280_integration.py
if errorlevel 1 goto :fail
python scripts\check_careermp_040.py "%CAREERMP%"
if errorlevel 1 goto :fail
python scripts\verify_careermp_040_server.py "%SERVER_LUA%"
if errorlevel 1 goto :fail

python scripts\build_release_040.py ^
  --rls-original "%RLS%" ^
  --careermp-client "%CAREERMP%" ^
  --careermp-server "%SERVER_LUA%" ^
  --output "%BUILDROOT%" ^
  --experimental
if errorlevel 1 goto :fail

echo.
echo ==========================================
echo  EXPERIMENTAL 0.40 BUILD COMPLETE
echo ==========================================
echo.
echo Outputs:
echo   %BUILDROOT%\rls_2.8.0_careermp_040_EXPERIMENTAL.zip
echo   %BUILDROOT%\careermp_040_rls280_EXPERIMENTAL.zip
echo   %BUILDROOT%\careerMP_040_EXPERIMENTAL.lua
echo.
echo Back up your BeamNG and server saves before any testing.
echo No files have been installed.
echo.
pause
exit /b 0

:fail
echo.
echo ==========================================
echo  BUILD FAILED - NOTHING INSTALLED
echo ==========================================
echo.
pause
exit /b 1
