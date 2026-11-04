# Windows nanoserver  container demos for developers

I'm experimenting with windows containers and I'm putting the results here.

## Containers

Right now there is a PHP one. It has node and PHP and it works. I don't have notes to expose ports.

- [nano-server-rust](nano-server-rust/README.md): Rust (gnu toolchain), cargo, MinGit and micro on nano server. `cargo run` works.
- [nano-server-far](nano-server-far/README.md): Far Manager 3 (x64, stable build). It's based on servercore because Far needs DLLs that nanoserver doesn't have. Run it with `docker run -it`.
- [nano-server-ssh](nano-server-ssh/README.md): Win32-OpenSSH server on nanoserver where clients log in as real local Windows users (password and public key).
- [nano-server-go](nano-server-go/README.md): Go, MinGit and the micro editor for Go development.
- [nano-server-powershell](nano-server-powershell/README.md): PowerShell 7 with MinGit, micro, Pester, PSScriptAnalyzer, platyPS, PSReadLine and PSResourceGet.
- [nano-server-vim](nano-server-vim/README.md): console Vim and MinGit. Based on servercore, because Vim can't load on nanoserver.
- [nano-server-neovim](nano-server-neovim/README.md): Neovim and MinGit. Based on servercore, because Neovim can't load on nanoserver.
