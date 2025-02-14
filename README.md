# Mullvad-Auto-Updater
Automatically Update Mullvad VPN on Windows

WARNINGS:
- Tested only on Windows 10
- Downloads and installs things automatically with Administrator Privileges
- Use at your own risk

What this program will do:
- Create and install a python virtual environment
- Create a windows task scheduler task to run this python script on computer startup
- Every loop (60 minutes by default), check if you have the latest version of Mullvad VPN installed and running
- Download and install the latest version of Mullvad VPN if not currently installed
- Run Mullvad VPN if it is not currently running

To install / activate:
1. Install Python3 / Clone Repo to C:\ Drive (Or ensure paths are updated in script to desired locations)
2. Open autoupdate_mullvad_allinone.ps1 in text editor and ensure that all C:\ paths are correct
3. Change update check window to the desired time. (CHECK_FREQUENCY_MINUTES = 60) is the default
4. Run autoupdate_mullvad_allinone.ps1 in PowerShell as Administrator
5. Go To Task Scheduler's Task Scheduler Library and find the MullvadUpdaterTask and Run (Optional, will run when computer starts)

Known Issues:
- Task tray icon / program must be killed with task manager, right-click and exit does not work. (It has the same icon and is called "Python" under processes)
