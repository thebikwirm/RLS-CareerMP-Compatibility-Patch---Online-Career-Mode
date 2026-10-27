@echo off
setlocal
cd /d "%~dp0"
echo ================================================
echo BEAMMP DUPLICATE MOD AUDIT - READ ONLY
echo ================================================
echo.
echo Server: D:\beamng_server\Resources\Client
echo Client: D:\beamng stuff\current\mods
echo.
echo This can hash large mod files. No mods will be changed.
echo.
python "%~dp0scripts\audit_beammp_duplicate_mods.py" --server-root "D:\beamng_server" --client-mods "D:\beamng stuff\current\mods" --output "%~dp0beammp_duplicate_mod_report.csv"
if errorlevel 1 (
 echo.
 echo ERROR: Audit failed. Verify Python and folder paths.
 pause
 exit /b 1
)
echo.
echo Open beammp_duplicate_mod_report.csv for results.
pause
