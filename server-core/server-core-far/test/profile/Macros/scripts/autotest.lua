-- Non-interactive Far Manager run test.
-- run-test.cmd starts Far with "-s <this profile>", so this autorun macro fires once the panels are up.
-- It proves Far really started (Lua macro engine + panels), runs a shell command through
-- Far's command line, and then quits Far.

Macro {
  description = "server-core/server-core-far automated run test";
  area = "Shell";
  flags = "RunAfterFARStart";
  action = function()
    local dir = win.GetEnv("FAR_TEST_DIR")
    local f = assert(io.open(dir .. "\\macro.txt", "w"))
    f:write("far_version=", tostring(far.AdvControl("ACTL_GETFARMANAGERVERSION")), "\n")
    f:write("far_pid=", tostring(Far.PID), "\n")
    f:write("console=", tostring(Far.Width), "x", tostring(Far.Height), "\n")
    f:write("active_panel=", tostring(APanel.Path), "\n")
    f:write("panel_items=", tostring(APanel.ItemCount), "\n")
    f:close()

    -- Type a command into Far's command line and press Enter, exactly as a user would.
    print('echo far_cmdline_ok FARHOME=%FARHOME%> "' .. dir .. '\\cmd.txt"')
    Keys("Enter")

    -- F10 = Quit. Confirmations.Exit is turned off on the far.exe command line.
    Keys("F10")
  end;
}
