@echo off
rem Non-interactive Far Manager run test. Copied into the container with docker cp and run with a TTY (-t).
rem Far loads the throwaway profile next to this script; its autorun macro writes macro.txt,
rem runs a command through Far's command line (which writes cmd.txt) and quits with F10.
setlocal
set "FAR_TEST_DIR=%~dp0"
set "FAR_TEST_DIR=%FAR_TEST_DIR:~0,-1%"
del /q "%FAR_TEST_DIR%\macro.txt" "%FAR_TEST_DIR%\cmd.txt" 2> NUL
where far.exe || (echo FAIL: far.exe is not on PATH & exit /b 1)
far.exe -s "%FAR_TEST_DIR%\profile" -set:Confirmations.Exit=false
set FAR_EXIT=%ERRORLEVEL%
echo.
echo ===== far-test results =====
echo FAR_EXIT=%FAR_EXIT%
if not exist "%FAR_TEST_DIR%\macro.txt" (echo FAIL: autorun macro did not run & exit /b 2)
type "%FAR_TEST_DIR%\macro.txt"
if not exist "%FAR_TEST_DIR%\cmd.txt" (echo FAIL: command typed into Far was not executed & exit /b 3)
type "%FAR_TEST_DIR%\cmd.txt"
findstr /c:"far_cmdline_ok" "%FAR_TEST_DIR%\cmd.txt" > NUL || (echo FAIL: unexpected cmd.txt contents & exit /b 4)
if not "%FAR_EXIT%"=="0" (echo FAIL: far.exe exited with %FAR_EXIT% & exit /b 5)
echo PASS
exit /b 0
