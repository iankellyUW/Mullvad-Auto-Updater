<#
.SYNOPSIS
  A one-stop script to:
    1) Check Python installation
    2) Create C:\Mullvad-Auto-Updater (or user-specified folder)
    3) Create a virtual environment
    4) Install psutil, requests, pystray, pillow
    5) Create mullvad_updater.py, run_mullvad_updater.bat, run_mullvad_updater.vbs
    6) Register a scheduled task to run the .vbs at logon with admin privileges (hidden console)

.USAGE
  Run from an elevated PowerShell prompt:
     PS> .\install_mullvad_allinone.ps1

.PARAMETER InstallDir
  The folder where everything will be placed. Defaults to "C:\Mullvad-Auto-Updater".

.PARAMETER TaskName
  The name of the scheduled task. Defaults to "MullvadUpdaterTask".
#>

param(
    [string]$InstallDir = "C:\Mullvad-Auto-Updater",
    [string]$TaskName = "MullvadUpdaterTask"
)

# --- 0) Confirm we are in an elevated (Admin) PowerShell session ---
#    If not, we can attempt to relaunch with admin privileges.
function Assert-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Not running as administrator. Relaunching..."
        $commandLine = '"' + $PSCommandPath + '" ' + $MyInvocation.UnboundArguments
        Start-Process powershell.exe -Verb runas -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$commandLine`""
        exit
    }
}
Assert-Admin

Write-Host "`n=== Welcome to the Mullvad Updater Installer (All-in-One) ==="

# --- 1) Check if Python 3 is installed ---
Write-Host "`nChecking for Python 3..."
$python = Get-Command python -ErrorAction SilentlyContinue
if(-not $python) {
    Write-Warning "Python not found in PATH. Please install Python 3 and re-run this script."
    Write-Host "Download from: https://www.python.org/downloads/ or install via Windows Store."
    exit 1
}

# Optional: check version (this is approximate if multiple pythons are installed)
try {
    $pyVer = & python --version
    if($pyVer -notmatch "3\.") {
        Write-Warning "Found Python, but it's not Python 3.x. Please install Python 3."
        exit 1
    }
    Write-Host "Found Python: $pyVer"
} catch {
    Write-Warning "Could not run python --version. Please ensure Python 3 is accessible."
    exit 1
}

# --- 2) Create the InstallDir ---
Write-Host "`nCreating directory: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# --- 3) Create a virtual environment ---
Write-Host "`nCreating a virtual environment in $InstallDir\venv"
Push-Location $InstallDir
try {
    & python -m venv venv
} catch {
    Write-Error "Failed to create a virtual environment. Error: $_"
    Pop-Location
    exit 1
}

# --- 4) Install required packages (psutil, requests, pystray, pillow) ---
Write-Host "`nActivating venv and installing dependencies..."
$activateScript = Join-Path $InstallDir "venv\Scripts\activate.ps1"
if(!(Test-Path $activateScript)) {
    Write-Error "Could not find activate.ps1 at $activateScript"
    Pop-Location
    exit 1
}

# We can either dot-source or just call pip directly inside the venv.
# Easiest is to call pip from the venv\Scripts\pip.exe:
$venvPip = Join-Path $InstallDir "venv\Scripts\pip.exe"
if(!(Test-Path $venvPip)) {
    Write-Error "Could not find pip in the new venv. Something went wrong."
    Pop-Location
    exit 1
}

try {
    & $venvPip install --upgrade pip
    & $venvPip install psutil requests pystray pillow
} catch {
    Write-Error "Failed to install required Python packages. Error: $_"
    Pop-Location
    exit 1
}

# --- 5) Write the Python script, batch file, and VBS script ---

# 5a) Python script
$pythonScriptContent = @'
import os
import time
import threading
import requests
import subprocess
import sys
import ctypes
import psutil
import pystray
from pystray import MenuItem as item
from PIL import Image

CHECK_FREQUENCY_MINUTES = 60  # how often to check for updates (default: 1 hour)
MULLVAD_DOWNLOAD_URL = "https://mullvad.net/en/download/app/exe/latest"  # Windows direct link to the latest Mullvad Windows installer
#MULLVAD_DOWNLOAD_URL = "https://mullvad.net/en/download/app/pkg/latest"  # macOS direct link to the latest Mullvad Windows installer
MULLVAD_LOCAL_INSTALL_PATH = r"C:\Program Files\Mullvad VPN"      # typical Mullvad install path
MULLVAD_SETUP_LOCAL_FILE = r"C:\Temp\MullvadSetup.exe"            # where we temporarily save the new installer
MULLVAD_EXE_PATH = r"C:\Program Files\Mullvad VPN\Mullvad VPN.exe"

# Figure out the folder where *this script* is located.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# We'll store the installed version here:
VERSION_FILE = os.path.join(SCRIPT_DIR, "installed_version.txt")

def is_mullvad_running():
    """
    Returns True if a Mullvad process is already running.
    Checks by looking for 'mullvad.exe' in the list of process names.
    """
    for proc in psutil.process_iter(['name']):
        if proc.info['name'] and 'mullvad.exe' in proc.info['name'].lower():
            return True
    return False

def run_mullvad():
    """
    Attempts to launch Mullvad from the known install path.
    Uses subprocess.Popen so it doesn't block Python.
    """
    if os.path.exists(MULLVAD_EXE_PATH):
        print("Launching Mullvad...")
        subprocess.Popen([MULLVAD_EXE_PATH])
    else:
        print("Error: Mullvad not found at:", MULLVAD_EXE_PATH)
        
def get_installed_mullvad_version():
    """
    Checks a local text file for the last-installed Mullvad version.
    If the file doesn't exist or is empty, returns "0.0.0" by default.
    """
    if os.path.exists(VERSION_FILE):
        with open(VERSION_FILE, 'r', encoding='utf-8') as f:
            return f.read().strip()
    return "0.0.0"

def set_installed_mullvad_version(version_str):
    """
    Writes the given version string to the local installed_version.txt file.
    Overwrites any existing content.
    """
    with open(VERSION_FILE, 'w', encoding='utf-8') as f:
        f.write(version_str)

def get_latest_mullvad_version_online():
    """
    Fetch the latest Mullvad VPN release version from GitHub.
    Returns a string like "2023.4" (for example) or None if it fails.
    """
    url = "https://api.github.com/repos/mullvad/mullvadvpn-app/releases/latest"
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()  # Raise an exception if the response was 4xx or 5xx
        data = response.json()
        # The "tag_name" field typically contains the release version, e.g. "2023.4".
        return data.get("tag_name")  # or data["tag_name"] if you trust it always exists
    except (requests.RequestException, ValueError, KeyError) as e:
        print(f"Error fetching latest Mullvad version: {e}")
        return None

def is_newer_version(current_version, latest_version):
    """
    Compare version strings (simple numeric dot approach).
    You can refine for semver. This is a basic example.
    """
    def version_tuple(v):
        return tuple(map(int, (v.split("."))))
    try:
        return version_tuple(latest_version) > version_tuple(current_version)
    except ValueError:
        # fallback if something is weird
        return False

def download_and_install_mullvad():
    """
    Downloads the latest Mullvad installer and runs it in silent mode.
    """
    try:
        print("Downloading Mullvad from:", MULLVAD_DOWNLOAD_URL)
        response = requests.get(MULLVAD_DOWNLOAD_URL, stream=True)
        response.raise_for_status()

        # Ensure temp dir exists
        os.makedirs(os.path.dirname(MULLVAD_SETUP_LOCAL_FILE), exist_ok=True)

        with open(MULLVAD_SETUP_LOCAL_FILE, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
        print("Download complete.")

        # Attempt a silent install
        print("Starting silent install...")
        subprocess.run(
            [MULLVAD_SETUP_LOCAL_FILE, "/S"],
            check=True
        )
        print("Mullvad installation completed.")
        set_installed_mullvad_version(new_version)
        print(f"Recorded installed version as: {new_version}")
    except Exception as e:
        print("Error during Mullvad update:", e)

def check_for_updates_and_install():
    """
    Checks if there's a newer version of Mullvad. If so, downloads+installs it.
    """
    current_version = get_installed_mullvad_version()
    latest_version = get_latest_mullvad_version_online()

    print(f"Current installed version: {current_version}")
    print(f"Latest available version: {latest_version}")
    
    if is_newer_version(current_version, latest_version):
        print("New version found! Updating...")
        set_installed_mullvad_version(latest_version)
        print(f"Recorded installed version as: {latest_version}")
        download_and_install_mullvad()
    else:
        print("Mullvad is up to date.")
        
    if is_mullvad_running():
        print("Mullvad is already running.")
    else:
        print("Mullvad is not running. Starting now...")
        run_mullvad()

def scheduled_check_loop():
    """
    This function runs in a background thread, periodically calling check_for_updates_and_install.
    """
    while True:
        check_for_updates_and_install()
        # Sleep for the configured frequency
        time.sleep(CHECK_FREQUENCY_MINUTES * 60)

# --- Tray icon handling ---

def on_clicked_update(icon, item):
    """
    Manually trigger an update check/install from the tray menu.
    """
    # Run the check in a background thread so the tray doesn't freeze
    thread = threading.Thread(target=check_for_updates_and_install, daemon=True)
    thread.start()

def on_clicked_exit(icon, item):
    """
    Quit the tray application.
    """
    icon.stop()
    sys.exit(0)

def create_tray_icon():
    """
    Creates the tray icon with pystray, sets up menu items, and starts the event loop.
    """
    # Load an icon image (PNG recommended). Must be PIL Image object.
    icon_img = Image.open("tray_icon.png")  # path to your icon

    # Build the tray menu
    menu = (
        item('Check Now', lambda: on_clicked_update(icon, None)),
        item('Exit', lambda: on_clicked_exit(icon, None))
    )
    tray_icon = pystray.Icon("MullvadAutoUpdater", icon_img, "Mullvad Updater", menu)
    return tray_icon

def is_running_as_admin():
    """
    Returns True if the script is running with admin (elevated) privileges.
    """
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        # If calling IsUserAnAdmin fails, assume not an admin.
        return False

def run_as_admin(args=None):
    """
    Relaunch this script with 'runas' (UAC prompt).
    Args should be a list of additional arguments to pass, or None for none.
    """
    if args is None:
        args = []
    # Convert list of args to a command line string
    params = " ".join(args)

    # Use ShellExecuteW to request elevation (UAC).
    ctypes.windll.shell32.ShellExecuteW(
        None,              # parent window handle
        "runas",           # operation = 'runas' => run with admin rights
        sys.executable,    # lpFile = path to Python interpreter
        params,            # lpParameters = the script + arguments
        None,              # lpDirectory = current directory
        1                  # nShowCmd = 1 => show the window
    )

if __name__ == "__main__":
    # 1) Check for admin/elevated privileges
    if not is_running_as_admin():
        print("Not running as admin. Attempting to relaunch with admin privileges...")
        # Relaunch with same script and same args
        script = os.path.abspath(sys.argv[0])
        # [script] + any additional CLI args
        new_args = [script] + sys.argv[1:]
        run_as_admin(new_args)
        sys.exit(0)  # Exit to let the new admin process run fully

    # 2) If we’re here, we have admin rights. Proceed with installation logic.
    print("Running with admin privileges. Proceeding with Mullvad update...")
    
    # Start background thread for periodic checks
    t = threading.Thread(target=scheduled_check_loop, daemon=True)
    t.start()
        
    # Create and run the tray icon
    tray = create_tray_icon()
    tray.run()
'@

Set-Content -Path (Join-Path $InstallDir "mullvad_updater.py") -Value $pythonScriptContent -Encoding UTF8
Write-Host "Created mullvad_updater.py"

# 5b) Batch file (.bat)
$batchContent = @'
@echo off
cd /d "C:\Mullvad-Auto-Updater"
call venv\Scripts\activate.bat

REM Use pythonw to avoid a console window from Python itself.
pythonw mullvad_updater.py
'@

Set-Content -Path (Join-Path $InstallDir "run_mullvad_updater.bat") -Value $batchContent -Encoding ASCII
Write-Host "Created run_mullvad_updater.bat"

# 5c) VBS file (.vbs) to run the .bat hidden
$vbsContent = @'
Dim WshShell
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd /c ""C:\Mullvad-Auto-Updater\run_mullvad_updater.bat""", 0, True
'@

Set-Content -Path (Join-Path $InstallDir "run_mullvad_updater.vbs") -Value $vbsContent -Encoding ASCII
Write-Host "Created run_mullvad_updater.vbs"

Pop-Location

# --- 6) Create a Scheduled Task to run .vbs at logon, with highest privileges (hidden) ---
Write-Host "`nCreating a Scheduled Task '$TaskName' at logon with highest privileges..."
try {
    # Action: run wscript.exe with argument "C:\Mullvad-Auto-Updater\run_mullvad_updater.vbs"
    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$InstallDir\run_mullvad_updater.vbs`""

    # Trigger: At log on
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    # Principal: current user, run with highest privileges (requires admin context)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName `
                           -Action $action `
                           -Trigger $trigger `
                           -Principal $principal `
                           -Description "Runs Mullvad updater hidden at logon with admin privileges" `
                           -Force | Out-Null

    Write-Host "Scheduled Task '$TaskName' created successfully."
    Write-Host "It will run automatically at your next logon (as admin, hidden)."
} catch {
    Write-Warning "Failed to create scheduled task. Error: $_"
}

Write-Host "`n=== Installation Complete ==="
Write-Host "Files installed in: $InstallDir"
Write-Host "Virtual env created at: $InstallDir\venv"
Write-Host "Task Name: $TaskName"
Write-Host "`nIf you wish to run it immediately, you can open Task Scheduler and click 'Run' on the $TaskName task."
