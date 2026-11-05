# MySQL windows nano server container

MySQL Community Server 8.4 (LTS) on `mcr.microsoft.com/windows/nanoserver`, using the official `winx64` zip from MySQL. The image holds the server (`mysqld`) and the command-line client tools (`mysql`, `mysqladmin`, `mysqldump`, ...). It runs as `ContainerUser`, not as an administrator.

## Running

The first start initializes the data directory in the `C:\mysql\data` volume. The root password comes from the environment, like the official Linux image.

| Variable | Meaning |
| --- | --- |
| `MYSQL_ROOT_PASSWORD` | Password for `root`. Required on first start, unless `MYSQL_ALLOW_EMPTY_PASSWORD` is `yes`. |
| `MYSQL_ALLOW_EMPTY_PASSWORD` | Set to `yes` to allow an empty root password. |
| `MYSQL_DATABASE` | Database to create on first start. |
| `MYSQL_USER`, `MYSQL_PASSWORD` | Account to create on first start. It gets all privileges on `MYSQL_DATABASE`. |

These only matter when the data directory is empty. On later starts they are ignored. The server listens on `0.0.0.0`, port 3306 (classic protocol) and 33060 (X protocol).

```pwsh
docker volume create mysqldata
docker run -d --name mysql -v mysqldata:C:\mysql\data `
  -e MYSQL_ROOT_PASSWORD=$env:MYSQL_ROOT_PASSWORD `
  -e MYSQL_DATABASE=app -e MYSQL_USER=app -e MYSQL_PASSWORD=$env:APP_PASSWORD `
  zippy1981/windows-nano-mysql:2025

# Connect from a second container. The client reads the password from MYSQL_PWD.
$ip = docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" mysql
docker run --rm -e MYSQL_PWD=$env:MYSQL_ROOT_PASSWORD zippy1981/windows-nano-mysql:2025 mysql -h $ip -uroot -e "SELECT VERSION()"
```

Add `-p 3306:3306` to reach the server from other machines. Any command other than the default `mysqld` runs as given, so `docker run <image> mysql --version` and `docker run <image> cmd` work. Arguments after `mysqld` go to the server, for example `docker run ... <image> mysqld --max-connections=500`.

Don't use `& | < > ^ " % ' \` in the passwords. The entrypoint is a `cmd` script and writes them into SQL.

## How it works

- Nanoserver and Server Core don't ship the Visual C++ runtime. A throwaway Server Core stage installs the official redistributable and the Dockerfile copies `vcruntime140.dll`, `vcruntime140_1.dll` and `msvcp140.dll` out of it.
- `docker-entrypoint.cmd` runs `mysqld --initialize-insecure` with an `--init-file` that sets the passwords, then starts `mysqld --console` in the foreground. The init file is in the user's temp directory and is deleted as soon as initialization finishes, so the passwords are never stored in plaintext. They end up only as hashes in the data directory.
- The unpacked zip is about 1.7 GB, so the Dockerfile strips what a server doesn't need: `.pdb` debug symbols (`mysqld.pdb` alone is 600 MB), import libraries, the debug builds of DLLs and plugins, the MeCab full-text parser dictionaries (so the optional `mecab` parser plugin doesn't work), headers and docs.
- `C:\mysql\data` is granted to `ContainerUser` before the `VOLUME` is declared, so the server doesn't need administrator rights.

## Testing

```pwsh
./smoke-test.ps1 -Image windows-nano-mysql:2025
```

The smoke test checks that the server refuses to start without a root password, then starts one with a generated password and runs the `mysql` client from a second container over the container network. It creates a table, inserts a row, selects it, checks that a wrong password is rejected and that the `MYSQL_USER` account is limited to its database, then restarts the server container and checks that the row and the credentials persisted. It removes only the containers and volume it created.

### Windows versions

CI builds and tests this image for **ltsc2022 and ltsc2025 only**. On ltsc2019 the smoke test's restart check fails intermittently, with "the row did not survive a restart". It passed on some runs and failed on others for the same image, and the root cause isn't known yet. The workflow narrows the shared matrix with `windows-versions`, and `WINDOWS_VERSION_EXCEPTIONS` in `tests/repo_conventions.py` records the exception (ADR 0008). Building for 2019 locally still works with `set WINDOWS_VERSION=2019`, but that image isn't tested or published.

## Building

```pwsh
.\build.cmd                           # 2025
$env:WINDOWS_VERSION = "2022"; .\build.cmd   # or 2019
```

Builds use `--memory 4g`, because the default 1 GB Hyper-V limit hangs the build while extracting the zip.
