SHORT FUTURE IMPROVEMENTS
-------------------------

- Rewrite rsync exclude patterns using \"pattern\" instead of escaped chars
- Clean most of recursive task creation code
- dry option shoudln't create local dirs
- Add symlink support (-L) and edit find -xtype d instead of -type d

FAR FUTURE IMPROVEMENTS
-----------------------

- (Secret world domination... Still need to get bald and get a cat)

KNOWN ISSUES
------------

- Backup size check does not honor rsync exclude patterns
- Bandwidth parameter is ignored for SQL backups
- Missing symlink support when run from MSYS environment
- Dry mode creates dirs
- Dry mode does not try mysqldump

CHANGELOG
---------

- Fixed an issue with existing symlinks to directories on target
- Prevent changed IFS to make ping commands fail
- Added RotateCopies execution time (spinner support)
- redirect stderr for mysqldump to catch problems
	!-and other commands (cp ?) + verify is not telling success if table damaged
!- Moved msys specific code to Init(Local|Remote)OSSettings (halfway done, still need the WaitForTaskCompletion code to moove)
- Added support for multithreaded gzip (if pigz is installed)
- Merged back changes from osync codebase
	- Enhanced debugging
	- Added language agnostic system command output
	- Enhanced log sending
	- Better handling of OS specific commands
	- Improved WaitForTaskCompletion when DEBUG enabled or SILENT enabled
	- Enhanced OS detection
- More correct error message on remote connection failure
- Gzipped logs are now deleted once sent
- Fixed some typos (thanks to Pavel Kiryukhin)
- Improved OS detection and added prelimnary MacOS X support
- Improved execution hook logs
- Improved RunLocalCommand execution hook
- 02 Nov. 2013: v1.84 RC3
- Updated documentation
- Minor rewrites in recursive backup code
- Added base directory files backup for recursive directories backup
- Minor improvements on permission checks
- Added local and remote OS detection
- Fixed ping arguments for FreeBSD compatibility
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
- 14 Jun 2013
- Initial public release, fully functionnal
