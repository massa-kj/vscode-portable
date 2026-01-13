# vscode-portable

This is a set of scripts for operating VS Code Portable safely, reproducibly, and with rollbacks, even in a Windows environment without administrator privileges.

Key features include:
- Downloading and setting up VS Code
- Updating VS Code
- Version control and switching
- Backing up and restoring user data
- Managing and reinstalling extensions

## Table of Contents

- [Usage](#usage)
  - [Simple Scenario](#simple-scenario)
  - [launch.cmd](#launchcmd)
  - [update.ps1](#updateps1)
  - [Rollback](#rollback)
- [Overall Structure](#overall-structure)

## Usage

### Simple Scenario

1. Download and set up VS Code Portable

   [update.ps1](#update.ps1)

   ```powershell
   .\update.ps1
   # or
   # powershell -ExecutionPolicy Bypass -File .\update.ps1
   ```

2. Launch VS Code

   Place the shortcut to launch.cmd anywhere you like and run it.  

   [launch.cmd](#launch.cmd)

5. Update to the latest VS Code

   ```powershell
   .\update.ps1
   # or
   # powershell -ExecutionPolicy Bypass -File .\update.ps1
   ```

### launch.cmd

```bat
launch.cmd
```

* Always launch through this launcher
* The VS Code version specified in `current.txt` will be launched


### update.ps1

```powershell
.\update.ps1
# or
# powershell -ExecutionPolicy Bypass -File .\update.ps1
```

#### Behavior at first

* Downloads the latest VS Code from the official site
* Extracts it to `versions/<version>/`
* Initializes `data/current/`
* Creates `current.txt`

#### Update Behavior

* Downloads the latest version
* Adds new version to `versions/` (existing versions are not deleted)
* Backs up `data/current` to `data/backups/<timestamp>/`
* If successful, switches `current.txt` to the new version

#### Running with Options

The `update.ps1` script supports the following options:

```powershell
# Display help
.\update.ps1 --help

# Show directory structure
.\update.ps1 --show-paths

# Specify platform (example: ARM64 Portable)
.\update.ps1 --platform win32-arm64-archive

# Specify quality (stable / insiders)
.\update.ps1 --quality stable

# Specify version
.\update.ps1 --version 1.107.1

# Clean rebuild of extensions
.\update.ps1 --rebuild-extensions

# Combination usage
.\update.ps1 --version 1.107.1 --platform win32-x64-archive --quality stable
```

#### Parameter List

| Option                   | Description                               | Default Value        |
| ------------------------ | ----------------------------------------- | -------------------- |
| `--help`                 | Display help message                      | -                    |
| `--show-paths`           | Display directory structure               | -                    |
| `--platform`             | VS Code platform to download             | `win32-x64-archive`  |
| `--quality`              | Release type                              | `stable`             |
| `--version`              | VS Code version to retrieve               | (Latest if not specified) |
| `--rebuild-extensions`   | Clean rebuild of extensions               | -                    |

### Rollback

* Simply write back `current.txt` to a previous version number
* If needed, data can also be restored from `data/backups/`

## Overall Structure

The final directory structure after execution will be as follows:

```
vscode-portable/
│
├─ versions/                 # VS Code binaries (saved per version)
│   ├─ 1.107.1/
│   ├─ 1.108.0/
│   └─ ...
│
├─ data/
│   ├─ current/              # Currently used user data
│   │   ├─ user-data/        # settings.json, state.vscdb, snippets etc.
│   │   └─ extensions/       # Extension files
│   │
│   └─ backups/              # Snapshots of data
│       ├─ 2026-01-10_203000/
│       └─ ...
│
├─ current.txt               # Version number of VS Code currently in use
│
├─ launch.cmd                # VS Code launcher (always use this)
├─ update.ps1                # Download, update, and switch script
├─ README.md
└─ .gitignore
```

※ `versions/`, `data/`, `current.txt` are **.gitignore targets** and not managed by Git.
