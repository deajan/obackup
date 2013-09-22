## FUTURE IMPROVEMENTS

- Exit trap function must also stop child processes
- Rewrite rsync exclude patterns using \"pattern\" instead of escaped chars

## Known issues

- Backup size check counts excluded patterns
- Recursive task creation from directories does only include subdirectories, but no files in root directory
- Bandwidth parameter is ignored by SQL backups.
- Missing symlink support under MSYS

## Latest changelog

- Added MSYS (MinGW minimal system) bash compatibility under Windows
	- Added check for /var/log directory
	- Added check for shared memory directory
	- Added alternative way to kill child processes for other OSes and especially for MSYS (which is a very odd way)
	- Added Sendemail.exe support for windows Alerting
	- Replaced which commend by type -p, as it is more portable
	- Added support for ping.exe from windows
	- Forced usage of MSYS find instead of Windows' find.exe
	- Added an optionnal remote rsync executable path parameter
	- Made ListDatabases and ListDirectories Msys friendly
- Fixed loop problems in RotateBackups and ListDatabases (depending on IFS environment)
- Fixed an error in CheckSpaceRequirements not setting required space to zero if file / sql backup is disabled
- Fixed an issue with CheckConnectivity3rdPartyHosts
- Added option to stop execution on failed command execution
- Improved forced quit command by killing all child processes
- Before / After commands are now ignored on dryruns
- Improved verbose output
- Improved dryrun output
- Improved remote connecivity detection 
- Fixed a typo in configuration file
- 18 Aug. 2013: Now v1.84 RC2
- Added possibility to change default logfile
- Simplified dryrun (removed dryrun function and merged it with main function)
- Simplified Init function
- Added --stat switch to rsync execution
- Added bandwidth limit
- Added --no-maxtime switch
- Fixed LoadConfigFile function will not warn on wrong config file
- More code cleanup
- Added --verbose switch (will add databases list,  rsync commands, and file backup list)
- Improved task execution checks and more code cleanup
- Fixed CleanUp function if DEBUG=yes, also function is now launched from TrapQuit
- 16 Jul. 2013: version tagged as v1.84 RC1
- Code cleanup
- Uploaded first documentation
- Fixed an issue with RotateBackups
- Updated obackup to log failed ssh command results
- Updated ssh command filter to log failed commands
- Updated ssh command filter to accept personalized commands
- 23 Jun. 2013 v 1.84 RC1 approaching
- Added ssh commands filter, updated documentation
- Rewrote local space check function
- Added ability to run another executable than rsync (see documentation on sudo execution)
- Added some Rsync argument parameters (preserve ACL, Xattr, and stream compression)
- Internal hook execution logic revised
- Updated WaitForTaskCompletition function to handle skipping alerts
- Updated command line argument --silent processing
- Added remote before and after command execution hook
- Added local before and after command execution hook

14 Jun 2013
-----------

- Initial public release, fully functionnal
