# Windows nanoserver  container demos for developers

I'm experimenting with windows containers and I'm putting the results here.

## Containers

Right now there is a PHP one. It has node and PHP and it works. I don't have notes to expose ports.

- [nano-server-rust](nano-server-rust/README.md): Rust (gnu toolchain), cargo, MinGit and micro on nano server. `cargo run` works.
- [nano-server-far](nano-server-far/README.md): Far Manager 3 (x64, stable build). It's based on servercore because Far needs DLLs that nanoserver doesn't have. Run it with `docker run -it`.
- [nano-server-ssh](nano-server-ssh/README.md): Win32-OpenSSH server on nanoserver where clients log in as real local Windows users (password and public key).
- [nano-server-go](nano-server-go/README.md): Go, MinGit and the micro editor for Go development.
- [nano-server-powershell](nano-server-powershell/README.md): PowerShell 7 with MinGit, micro, Pester, PSScriptAnalyzer, platyPS, PSReadLine and PSResourceGet.

## Developing

See [DEVELOPER.md](DEVELOPER.md) for how this repo works out which DLLs and APIs a tool needs on nano server, and when an image falls back to Server Core.
