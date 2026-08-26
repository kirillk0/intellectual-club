@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
if not defined SECRET_KEY_BASE set "SECRET_KEY_BASE=create-admin-task-only-secret-key-base-00000000000000000000000000000000"
if not defined TOKEN_SIGNING_SECRET set "TOKEN_SIGNING_SECRET=create-admin-task-only-token-signing-secret-0000000000000000000000000000"

if not "%~1"=="" (
  call "%SCRIPT_DIR%intellectual_club.bat" eval "IntellectualClub.ReleaseTasks.CreateAdmin.main(System.argv())" %*
  exit /b %ERRORLEVEL%
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%create-admin.ps1"
exit /b %ERRORLEVEL%
