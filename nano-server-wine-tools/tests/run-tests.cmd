@echo off
rem Tests for the Wine tools in this image. Writes TAP to stdout and exits with the number of failures.
rem Uses only cmd built-ins and nanoserver's own findstr for the checks, so a broken Wine tool cannot
rem hide its own failure. Test numbers in the descriptions match the test plan in plans/wine-binaries.md.
rem Usage: C:\tests\run-tests.cmd
setlocal
set FIX=C:\tests\fixtures
set WORK=C:\work
set "WT=C:\Program Files\wine-tools"
set OUT=%WORK%\test-out.txt
set T=0
set FAILS=0
if not exist "%WORK%" mkdir "%WORK%"
if "%WINEDEBUG%"=="" set WINEDEBUG=-all

rem The checks below call ":check <actual exit> <expected exit>" after setting D (description),
rem RX (findstr regex, empty for none) and RXI (/i for case-insensitive). Regexes go through variables
rem because CALL doubles carets in its arguments.

set "D=1 find in a file"& set "RX=^one"& set RXI=
find "one" %FIX%\a.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=2 find /c counts matches"& set "RX=: 1$"& set RXI=
find /c "one" %FIX%\a.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=3 find reads stdin"& set "RX=^one"& set RXI=
type %FIX%\a.txt | find "one" > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=4 fc reports differences"& set "RX=Comparing files"& set RXI=
fc %FIX%\a.txt %FIX%\b.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 1

set "D=5 fc on identical files"& set "RX=no differences"& set RXI=/i
fc %FIX%\a.txt %FIX%\a.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=6 where finds cmd"& set "RX=\\cmd\.exe$"& set RXI=/i
where cmd > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=7 where /q on a missing tool"& set RX=& set RXI=
where /q nosuchtool > "%OUT%" 2>&1
call :check %ERRORLEVEL% 1

rem Wine's whoami ends its line with LF only, and findstr's $ only matches before a CR, so no $ here.
set "D=8 whoami"& set "RX=\\ContainerUser"& set RXI=/i
whoami > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=9 tasklist lists itself"& set "RX=tasklist\.exe"& set RXI=/i
tasklist > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=10 tasklist /fi imagename"& set "RX=cmd\.exe"& set RXI=/i
tasklist /fi "imagename eq cmd.exe" > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

set "D=11 taskkill /? prints usage"& set "RX=taskkill"& set RXI=/i
taskkill /? > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

rem start is a cmd built-in, and cmd parses "start.exe" as the built-in followed by ".exe",
rem so Wine's start.exe has to be called by its full path.
set "D=12 start.exe /b /wait passes the exit code"& set RX=& set RXI=
"%WT%\start.exe" /b /wait cmd /c exit 3 > "%OUT%" 2>&1
call :check %ERRORLEVEL% 3

if exist "%WORK%\t.cab" del "%WORK%\t.cab"
set "D=13a cabarc creates a cabinet"& set RX=& set RXI=
cabarc n %WORK%\t.cab %FIX%\a.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0
set "D=13b cabarc lists the cabinet"& set "RX=a\.txt"& set RXI=/i
cabarc l %WORK%\t.cab > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

if exist "%WORK%\h.txt" del "%WORK%\h.txt"
copy /y %FIX%\a.txt %WORK%\src.txt > NUL
set "D=14a fsutil hardlink create"& set RX=& set RXI=
fsutil hardlink create %WORK%\h.txt %WORK%\src.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0
set "D=14b the hard link has the content"& set "RX=^one"& set RXI=
type %WORK%\h.txt > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0

rem 15: every tool loads. 0xC0000139 entry point not found, 0xC0000135 DLL not found, 0xC0000005 access violation.
for /f "usebackq eol=# tokens=*" %%t in ("C:\tests\tools.txt") do call :loadcheck %%t

rem 16: winecrt0's debug fallback honours WINEDEBUG on real Windows.
setlocal
set WINEDEBUG=
set "D=16a tasklist prints fixme without WINEDEBUG"& set "RX=fixme"& set RXI=
tasklist > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0
endlocal & set T=%T%& set FAILS=%FAILS%
setlocal
set WINEDEBUG=-all
set "D=16b tasklist is quiet with WINEDEBUG=-all"& set RX=& set RXI=& set "RXNOT=fixme"
tasklist > "%OUT%" 2>&1
call :check %ERRORLEVEL% 0
endlocal & set T=%T%& set FAILS=%FAILS%

echo 1..%T%
echo # %FAILS% failure(s)
if exist "%OUT%" del "%OUT%"
exit /b %FAILS%

:loadcheck
set "D=15 %~1 loads"& set RX=& set RXI=
"%WT%\%~1" /? > "%OUT%" 2>&1
set RC=%ERRORLEVEL%
if "%RC%"=="-1073741511" goto loadbad
if "%RC%"=="-1073741515" goto loadbad
if "%RC%"=="-1073741819" goto loadbad
set /a T+=1
echo ok %T% - %D% (exit %RC%)
goto :eof
:loadbad
set /a T+=1
set /a FAILS+=1
echo not ok %T% - %D% (exit %RC%)
call :dump
goto :eof

:check
set /a T+=1
set RC=%~1
if not "%RC%"=="%~2" goto checkbad
if not defined RXNOT goto checkrx
if not exist "%OUT%" goto checkbad
findstr /c:"%RXNOT%" "%OUT%" > NUL
if not errorlevel 1 goto checkbad
:checkrx
if not defined RX goto checkok
findstr %RXI% /r /c:"%RX%" "%OUT%" > NUL
if errorlevel 1 goto checkbad
:checkok
echo ok %T% - %D%
goto :eof
:checkbad
set /a FAILS+=1
echo not ok %T% - %D% (exit %RC%, expected %~2; regex "%RX%", must not match "%RXNOT%")
call :dump
goto :eof

:dump
if not exist "%OUT%" goto :eof
for /f "usebackq delims=" %%l in ("%OUT%") do echo #   %%l
goto :eof
