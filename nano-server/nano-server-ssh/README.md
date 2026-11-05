# OpenSSH server windows nano server container

An SSH server on `mcr.microsoft.com/windows/nanoserver` using [Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH). Clients log in as a real local Windows account that the container creates at start-up with `net user`. Both password and public-key logon work, and `whoami` returns that account, not `ContainerAdministrator`. The login shell is `cmd`.

## Running

The account comes from environment variables. Nothing secret is baked into the image, and the host keys are generated fresh in each container.

| Variable | Meaning |
| --- | --- |
| `SSH_USER` | Local account to create. Defaults to `sshuser`. |
| `SSH_PASSWORD` | Password for the account. If unset, password logon is turned off. |
| `SSH_AUTHORIZED_KEY` | One OpenSSH public key line, for example the contents of `id_ed25519.pub`. |
| `SSH_ADMIN` | Set to `1` to add the account to the local Administrators group. |

At least one of `SSH_PASSWORD` or `SSH_AUTHORIZED_KEY` is required. Don't use `"`, `%` or `!` in the password, because `cmd` can't pass them through safely.

A normal user's key goes in `%USERPROFILE%\.ssh\authorized_keys`. An administrator's key goes in `C:\ProgramData\ssh\administrators_authorized_keys`, which is what the stock `Match Group administrators` rule expects. Both files get an ACL limited to SYSTEM, Administrators and (for the user file) the user.

```pwsh
docker run -d --name sshd `
  -e SSH_USER=alice `
  -e SSH_PASSWORD=$env:ALICE_PASSWORD `
  -e SSH_AUTHORIZED_KEY="$(Get-Content ~/.ssh/id_ed25519.pub)" `
  zippy1981/windows-nano-ssh:2022

$ip = docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" sshd
ssh alice@$ip whoami
```

Add `-p 2222:22` to reach the server from other machines.

## How it works

Getting real user logons to work on nanoserver took four workarounds:

- Nanoserver has no `netapi32.dll`, and `sshd.exe`, `sshd-session.exe` and `ssh.exe` all import it. Without it they exit with `0xC0000135` (`STATUS_DLL_NOT_FOUND`), which the Docker CLI reports as `error while loading shared libraries`. The Dockerfile copies `netapi32.dll` and `whoami.exe` from the servercore image of the same Windows build, so no host files are needed.
- When sshd runs directly as `ContainerAdministrator`, every public-key logon fails with `get_user_token - unable to generate user token for alice as i am not running as system`. So sshd is registered as a LocalSystem service with `sc create`, and `start-sshd.cmd` starts the service and then waits on it.
- `ssh-keygen -A` gives `ContainerAdministrator` an explicit ACE on the host keys, and sshd then refuses them with `Bad permissions. Try removing permissions for user: User Manager\ContainerAdministrator (S-1-5-93-2-1)`. The script removes that ACE.
- Windows only creates a profile on first logon. Until the profile exists, sshd never reads `authorized_keys`. Pre-creating `C:\Users\alice` doesn't help either, because the profile then lands in `C:\Users\alice.<hostname>`. So the script first logs the user on once over loopback with the password (supplied through `SSH_ASKPASS`), which creates the real profile, and only then writes the key into it. If no `SSH_PASSWORD` was given, the account gets a random password for this bootstrap step. The script then prepends `PasswordAuthentication no` to `sshd_config` and restarts sshd.

The sshd logs are in `C:\ProgramData\ssh\logs`.

## Windows Server 2025 uses servercore

On `nanoserver:ltsc2025` the steps above still get sshd running, but LSA rejects every logon for a local account. S4U fails, so key logon and group lookup fail, and password logon fails the same way:

```text
generate_s4u_user_token: LsaLogonUser() failed. User 'alice' Status: 0xC00000DF SubStatus 0.
error: get_user_token - unable to generate token on 2nd attempt for user alice
Windows authentication failed for user: alice domain: . error: 1355
```

`0xC00000DF` is `STATUS_NO_SUCH_DOMAIN` and 1355 is `ERROR_NO_SUCH_DOMAIN`. The computer name and the local SAM look fine, and copying the LSA-related DLLs that servercore has and nanoserver lacks didn't help. So for 2025, `build.cmd` and CI build the same Dockerfile with `BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2025-amd64`, where everything passes. That image is much bigger. The 2019 and 2022 images stay on nanoserver.

## Building

To build a 2022 container:

```cmd
build.cmd
```

To build the windows 2019 container, from powershell:

```pwsh
$env:WINDOWS_VERSION=2019
./build.cmd
```

From the Command Prompt:

```cmd
set WINDOWS_VERSION=2019
build.cmd
```

`build.cmd` also forwards `BASE_IMAGE` when it's set, for example `set BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2022-amd64`.

## Testing

`test.ps1` needs only pwsh and the docker CLI. It starts the server, then uses a second container of the same image as the SSH client, so it also works from a containerized CI runner. It checks key logon (`whoami`), a remote command, password logon, and that a wrong key and a wrong password are both rejected. With `-Admin -KeyOnly` it checks key logon through `administrators_authorized_keys`, membership of the Administrators group, and that password logon is turned off.

```pwsh
./test.ps1 -Image windows-nano-ssh:2022
./test.ps1 -Image windows-nano-ssh:2022 -Admin -KeyOnly
```

CI runs both modes for 2019, 2022 and 2025 in `.github/workflows/ssh-server.yml`.
