@echo off
rem Entrypoint for windows-nano-mysql. See README.md for the environment variables.
rem Anything other than "mysqld" is run as given, so "docker run <image> mysql ..." works.
setlocal DisableDelayedExpansion
if /I not "%~1"=="mysqld" goto passthrough

set "DATADIR=C:\mysql\data"
rem Everything after "mysqld" is passed on to the server
set "EXTRA="
shift
:collect
if "%~1"=="" goto collected
set EXTRA=%EXTRA% %1
shift
goto collect
:collected

if exist "%DATADIR%\mysql" goto start

if defined MYSQL_ROOT_PASSWORD goto password_ok
if /I "%MYSQL_ALLOW_EMPTY_PASSWORD%"=="yes" goto password_ok
echo error: the database is uninitialized and MYSQL_ROOT_PASSWORD is not set 1>&2
echo        set MYSQL_ROOT_PASSWORD, or MYSQL_ALLOW_EMPTY_PASSWORD=yes for an empty root password 1>&2
exit /b 1
:password_ok

echo Initializing the data directory
rem The SQL holds the passwords, so it exists only for the duration of the initialization
set "INIT=%TEMP%\mysql-init-%RANDOM%%RANDOM%.sql"
> "%INIT%" echo ALTER USER 'root'@'localhost' IDENTIFIED BY '%MYSQL_ROOT_PASSWORD%';
>> "%INIT%" echo CREATE USER 'root'@'%%' IDENTIFIED BY '%MYSQL_ROOT_PASSWORD%';
>> "%INIT%" echo GRANT ALL ON *.* TO 'root'@'%%' WITH GRANT OPTION;
if defined MYSQL_DATABASE >> "%INIT%" echo CREATE DATABASE IF NOT EXISTS `%MYSQL_DATABASE%`;
if defined MYSQL_USER if defined MYSQL_PASSWORD >> "%INIT%" echo CREATE USER '%MYSQL_USER%'@'%%' IDENTIFIED BY '%MYSQL_PASSWORD%';
if defined MYSQL_USER if defined MYSQL_DATABASE >> "%INIT%" echo GRANT ALL ON `%MYSQL_DATABASE%`.* TO '%MYSQL_USER%'@'%%';

mysqld --initialize-insecure --console --datadir="%DATADIR%" --init-file="%INIT%"
set "RC=%ERRORLEVEL%"
del /q "%INIT%" 2>nul
if "%RC%"=="0" goto start

echo error: initialization failed with exit code %RC%, cleaning up the data directory 1>&2
for /d %%d in ("%DATADIR%\*") do rmdir /s /q "%%d"
del /q "%DATADIR%\*" 2>nul
exit /b %RC%

:start
mysqld --console --datadir="%DATADIR%" --bind-address=0.0.0.0 %EXTRA%
exit /b %ERRORLEVEL%

:passthrough
%*
exit /b %ERRORLEVEL%
