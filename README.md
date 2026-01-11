# vscode-portable

This is a set of scripts for operating VS Code Portable safely, reproducibly, and with rollbacks, even in a Windows environment without administrator privileges.

Key features include:
- Downloading and setting up VS Code
- Updating VS Code
- Version control and switching
- Backing up and restoring user data
- Managing and reinstalling extensions

---

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

   Place launch.cmd wherever you like and run it  

   [launch.cmd](#launch.cmd)

5. Update to the latest VS Code

   ```powershell
   .\update.ps1
   # or
   # powershell -ExecutionPolicy Bypass -File .\update.ps1
   ```

---
