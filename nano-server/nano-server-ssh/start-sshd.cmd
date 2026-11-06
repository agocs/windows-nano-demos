@echo off
rem Container entry point: create a real local Windows user from environment
rem variables, start the sshd service, create the user's profile, install the
rem authorized key, then stay in the foreground while sshd runs.
rem
rem   SSH_USER            local account name (default: sshuser)
rem   SSH_PASSWORD        password for the account (enables password logon)
rem   SSH_AUTHORIZED_KEY  one OpenSSH public key line (enables key logon)
rem   SSH_ADMIN           set to 1 to add the account to Administrators
rem
rem Do not use the characters " %% or ! in SSH_PASSWORD; cmd cannot pass them safely.
setlocal EnableExtensions DisableDelayedExpansion

set "SSHD_DATA=%ProgramData%\ssh"
set "SSHD_LOG=%ProgramData%\ssh\logs\sshd.log"
if not defined SSH_USER set "SSH_USER=sshuser"

if not defined SSH_PASSWORD if not defined SSH_AUTHORIZED_KEY (
    echo start-sshd: set SSH_PASSWORD and/or SSH_AUTHORIZED_KEY 1>&2
    exit /b 1
)

set "ACCOUNT_PASSWORD=%SSH_PASSWORD%"
rem Key-only accounts still need a password for the profile bootstrap below.
rem Password logon is switched off afterwards, so this one is never usable remotely.
if not defined ACCOUNT_PASSWORD set "ACCOUNT_PASSWORD=Kx9-%RANDOM%%RANDOM%-q%RANDOM%%RANDOM%-Z%RANDOM%"

rem Containers are short-lived; stop the default policy from expiring passwords.
net accounts /maxpwage:unlimited >nul

net user "%SSH_USER%" >nul 2>&1
if errorlevel 1 (
    rem /y answers the "longer than 14 characters" prompt for long passwords.
    net user "%SSH_USER%" "%ACCOUNT_PASSWORD%" /add /expires:never /y >nul || exit /b 1
    echo start-sshd: created local user %SSH_USER%
) else (
    net user "%SSH_USER%" "%ACCOUNT_PASSWORD%" /y >nul || exit /b 1
    echo start-sshd: reset password for existing user %SSH_USER%
)

if "%SSH_ADMIN%"=="1" (
    net localgroup Administrators "%SSH_USER%" /add >nul 2>&1
    echo start-sshd: %SSH_USER% is a member of Administrators
)

rem Host keys are generated per container, never baked into the image.
rem ssh-keygen gives its caller (ContainerAdministrator, S-1-5-93-2-1) an explicit
rem ACE, and sshd refuses host keys that account can read, so strip it.
if not exist "%SSHD_DATA%\ssh_host_ed25519_key" ssh-keygen.exe -A || exit /b 1
for %%K in ("%SSHD_DATA%\ssh_host_*_key") do (
    icacls "%%~K" /inheritance:r /remove:g "*S-1-5-93-2-1" /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" >nul
    icacls "%%~K" /setowner "*S-1-5-32-544" >nul
)

if not exist "%SSHD_DATA%\logs" mkdir "%SSHD_DATA%\logs"
call :start_sshd || goto stopped

rem Windows creates a profile on first logon, and sshd only reads
rem %USERPROFILE%\.ssh\authorized_keys once that profile exists. Pre-creating
rem C:\Users\<name> does not help: the profile then lands in C:\Users\<name>.<host>.
rem So log on once over loopback with the password to create it, and ask the
rem session where it is.
call :bootstrap_profile || goto stopped

if defined SSH_AUTHORIZED_KEY call :install_key || goto stopped

if not defined SSH_PASSWORD (
    echo start-sshd: no SSH_PASSWORD, disabling password logon
    rem The first occurrence of a keyword wins, so a prepended line overrides the default.
    > "%SSHD_DATA%\sshd_config.new" echo PasswordAuthentication no
    type "%SSHD_DATA%\sshd_config" >> "%SSHD_DATA%\sshd_config.new"
    move /y "%SSHD_DATA%\sshd_config.new" "%SSHD_DATA%\sshd_config" >nul
    call :stop_sshd
    call :start_sshd || goto stopped
)

echo start-sshd: sshd is running

rem Keep the container alive while the service runs.
:watch
ping -n 6 127.0.0.1 >nul
sc query sshd | findstr /c:"RUNNING" >nul && goto watch

:stopped
echo start-sshd: sshd is not running 1>&2
sc query sshd
for %%L in ("%SSHD_DATA%\logs\*.log") do type "%%~L"
exit /b 1

rem ---------------------------------------------------------------------------
:start_sshd
rem sshd runs as the LocalSystem service registered in the Dockerfile; run
rem directly as ContainerAdministrator it cannot create user tokens.
"%OPENSSH_DIR%\sshd.exe" -t || exit /b 1
if exist "%SSHD_LOG%" del /q "%SSHD_LOG%"
echo start-sshd: starting sshd service
sc start sshd >nul || exit /b 1
set /a WAITED=0
:wait_listening
findstr /c:"Server listening on" "%SSHD_LOG%" >nul 2>&1 && goto listening
set /a WAITED+=1
if %WAITED% GEQ 60 exit /b 1
ping -n 2 127.0.0.1 >nul
goto wait_listening
:listening
type "%SSHD_LOG%"
exit /b 0

:stop_sshd
sc stop sshd >nul 2>&1
:wait_stopped
ping -n 2 127.0.0.1 >nul
sc query sshd | findstr /c:"STOPPED" >nul || goto wait_stopped
exit /b 0

:bootstrap_profile
rem SSH_ASKPASS feeds the password to ssh.exe without a console. The helper reads
rem it from the environment so it is never written to disk.
> "%SSHD_DATA%\bootstrap-askpass.cmd" echo @setlocal EnableDelayedExpansion
>> "%SSHD_DATA%\bootstrap-askpass.cmd" echo @echo !BOOTSTRAP_PASSWORD!
set "BOOTSTRAP_PASSWORD=%ACCOUNT_PASSWORD%"
set "SSH_ASKPASS=%SSHD_DATA%\bootstrap-askpass.cmd"
set "SSH_ASKPASS_REQUIRE=force"
set "USER_HOME="
for /f "tokens=1,* delims==" %%A in ('ssh.exe -o StrictHostKeyChecking^=no -o UserKnownHostsFile^=NUL -o LogLevel^=ERROR -o PreferredAuthentications^=password -o PubkeyAuthentication^=no -o NumberOfPasswordPrompts^=1 "%SSH_USER%@127.0.0.1" set USERPROFILE') do (
    if /i "%%A"=="USERPROFILE" set "USER_HOME=%%B"
)
set "BOOTSTRAP_PASSWORD="
set "SSH_ASKPASS="
set "SSH_ASKPASS_REQUIRE="
del /q "%SSHD_DATA%\bootstrap-askpass.cmd"
if not defined USER_HOME (
    echo start-sshd: loopback logon for %SSH_USER% failed, no profile created 1>&2
    exit /b 1
)
echo start-sshd: profile for %SSH_USER% is %USER_HOME%
exit /b 0

:install_key
if "%SSH_ADMIN%"=="1" (
    set "KEY_DIR=%SSHD_DATA%"
    set "KEY_FILE=%SSHD_DATA%\administrators_authorized_keys"
) else (
    set "KEY_DIR=%USER_HOME%\.ssh"
    set "KEY_FILE=%USER_HOME%\.ssh\authorized_keys"
)
if not exist "%KEY_DIR%" mkdir "%KEY_DIR%" || exit /b 1
> "%KEY_FILE%" echo %SSH_AUTHORIZED_KEY%
rem sshd refuses key files that anyone other than the owner, SYSTEM and
rem Administrators can access. Strip inherited ACEs and grant exactly those.
if "%SSH_ADMIN%"=="1" (
    icacls "%KEY_FILE%" /inheritance:r /remove:g "*S-1-5-93-2-1" /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" >nul || exit /b 1
    icacls "%KEY_FILE%" /setowner "*S-1-5-32-544" >nul || exit /b 1
) else (
    icacls "%KEY_FILE%" /inheritance:r /remove:g "*S-1-5-93-2-1" /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" /grant "%SSH_USER%:F" >nul || exit /b 1
    icacls "%KEY_FILE%" /setowner "%SSH_USER%" >nul || exit /b 1
)
echo start-sshd: installed authorized key in %KEY_FILE%
exit /b 0
