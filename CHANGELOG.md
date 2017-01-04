KNOWN ISSUES
------------

- Backup size check does not honor rsync exclude patterns
- Encryption does not honor rsync exclude patterns
- Bandwidth parameter is ignored for SQL backups
- Missing symlink support when run from MSYS environment

CHANGELOG
---------

04 Jan 2017: obackup v2.1 beta1 released
----------------------------------------

- Fixed wrong file size fetched remotely since v2.1 rewrite
- Fixed missing databases in manual list fails to trigger an alert
- Improved support for GPG ver >= 2.1
- Added encryption / decryption parallel execution support
- Improved compatibility for RotateCopies
- Unit tests now run on CentOS 5,6
- Added optional rsync arguments configuration value
- Forcec bash usage on remote connections in order to be FreeBSD 11 compatible
- Spinner is less prone to move logging on screen
- Fixed another random error involving warns and errors triggered by earlier runs with same PID flag files
- Adde more preflight checks (pgrep presence)
- Added --no-prefix, --error-only and --summary switches
- Updated installer from osync
- Updated merge.sh script to handle includes
- Improved remote logging
- Simplified osync-batch runner (internally and for user)
	- Better filename handling
	- Easier to read log output
        - Always passes --silent to obackup
        - All options that do not belong to obackup-batch are automatically passed to obackup
- Improved installer OS detection
- Fixed upgrade script cannot update header on BSD / MacOS X
- Fixed SendEmail function on MacOS X
- Fixed MAX_SOFT_EXEC_TIME_PER_XX_TASK not enforced bug introduced with newer ofunctions from v2.1
- PRESERVE_ACL and PRESERVE_XATTR are ignored when local or remote OS is MacOS or msys or Cygwin
- Fixed PRESERVE_EXECUTABILITY was ommited volontary on MacOS X because of rsync syntax
- merge.sh is now BSD and Mac compatible
- Unit tests are now BSD and Mac compatible
- Local runs should not check for remote connectivity
- Fixed error alerts cannot be triggered from subprocesses
- Fixed error flags 
- Faster remote OS detection
- Added busybox (and Android Termux) support
	- More portable file size functions
	- More portable compression program commands
	- More paranoia checks
	- Added busybox sendmail support
	- Added tls and ssl support for sendmail
- Added ssh password file support
- Added unit tests
	- Added basic unit tests for all three operation modes
	- Added process management function tests
	- Added file rotation tests
	- Added upgrade script test
	- Added encryption tests
	- Added missing files / databases test
	- Added timed execution tests
- Implemented backup encryption using GPG (see documentation for advantages and caveats)
	- Backup encrypted but still use differential engine :)
- Database backup improvements
	- Added mysqldump options to config file
- Improved unit tests
- Added more preflight checks
- Logs sent by mail are easier to read
	- Better subject (currently running or finished run)
	- Fixed bogus double log sent in alert mails
	- Only current run log is now sent
	- Alert sending is now triggered after last action
- Made unix signals posix compliant
- Improved upgrade script
	- Upgrade script now updates header
	- Can add any missing value now
	- Added encrpytion support
- Fixed problem with spaces in directories to backup (again !)
- Added options to ignore permissions, ownership and groups
- Improved batch runner
	- Batch runner works for directories and direct paths
	- Fixed batch runner does not rerun obackup on warnings only
	- Code compliance
	- More clear semantic
- Made keep logging value configurable and not mandatory
- Fixed handling of processes in uninterruptible sleep state
- Code cleanup
- Refactored waiting functions
- Fixed double RunAfterHook launch

06 Aug 2016: obackup v2.0 released
----------------------------------

- Made logging begin before remote checks for sanity purposes
- RunAfterCommands can get executed when trapquit
- Improved process killing and process time control
- Added optional statistics for installer
- Added an option to ignore knownhosts for ssh connections (use with caution, this can lead to a security issue)
- Improved mail fallback
- More logging enhancements
- Improved upgrade script
- Revamped rsync patterns to allow include and exclude patterns
- Better SQL and file backup task separation (rotate copies and warnings are defined for sql and/or file)
- Added reverse backup, now backups can be local, pushed or pulled to or from a remote system
- Better fallback for SendAlert even if disk full
- Added an alert email sent on warnings while backup script is running
- Way better logging of errors in _GetDirectoriesSizeX, _BackupDatabaseX, _CreateStorageDirectoriesX
- Added bogus config file checks & environment checks
- Full code refactoring to use local and remote code once
- Fully merged codebase with osync
	- Added (much) more verbose debugging (and possibility to remove debug code to gain speed)
	- Replace child_pid by $? directly, add a better sub process killer in TrapQuit
	- Added some automatic checks in code, for _DEBUG mode (and _PARANOIA_DEBUG now)
	- Improved Logging
	- Updated obackup to be fully compliant with coding style
- Fixed creation of bogus subdirectories in some cases
- A long list of minor improvements and bug fixes

v0-1.x - Jan 2013 - Oct 2015
----------------------------

- New function to kill child processes
- Fixed no_maxtime not honored
- Improved some logging, also added highlighting to stdout errors
- Backported some fixes from Osync
	- Small improvements on install script
	- Copy ssh_filter.sh from osync project
	- Small improvements in obackup-batch.sh time management
- Quick and dirty hack to get the full last run log in SendAlert email
- Added detection of obackup.sh script in obackup-batch.sh to overcome mising path in crontab
- Moved command line arguments after config file load for allowing command line overrides
- Added a config file option equivalent to --dontgetsize
- Added basic install script from osync project
- Added obackup-batch.sh from osync project to rerun failed backups in row
- Delta copy algorithm is now used even for local copies (usefull for network drives), this can be overriden in config file
- Added --dontgetsize parameter to backup huge systems immediatly
- Fixed multiple keep logging messages since sleep time between commands has been lowered under a second
- Create local subdirectories if not exist before running rsync (rsync doesn't handle mkdir -p)
- Backported some fixes from Osync
	- Lowered sleep time between commands
	- Lowered debug sleep times
	- Fixed a bug with exclude pattern globbing preventing multiple exludes
	- Lowered default compression level for email alerts (for low end systems)
- Prevent exclude pattern globbing before the pattern reaches the rsync cmd
- Fixed some typos with ported code from osync rendering stats and partial downloads unusable
- Added delete on destination option for files that vanished from source
- Fixed ignoring compression level in conf file
- Added experimental partial downloads support for rsync so big files can be resumed on slow links
- Fixed dry mode sql backup output
- Prevented triggering TrapError if there are no child processes to terminate on TrapQuit
- Improved mysql debug logs
- Prevent creation of backup-id less log file when DEBUG is set
- WARNING: Default behavior is now to copy the referrent files and directories from symlinks (this can reach files outside the backup root)
- Recursive directory search now includes symlinks (find -L option. -type d cannot be replaced by -xtype d because of portability issues with BSD)
- Dry mode does not create target directories anymore
- Dry mode also tries mysqldumps now (check for error messages being logged)
- Added experimental partial download support
- Added Rsync exclude files suppport from osync
- Fixed another issue with existing symlinks to directories on target on non recursive backups
- Fixed remaining rsync -E option preventing obackup to work correctly on MacOS X
- Fixed an issue with existing symlinks to directories on target
- Prevent changed IFS to make ping commands fail
- Added RotateCopies execution time (spinner support)
- redirect stderr for mysqldump to catch problems
- Moved msys specific code to Init(Local|Remote)OSSettings except in TrapQuit that needs to work at any moment
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

02 Nov. 2013: obackup v1.84RC3 released
---------------------------------------

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

18 Aug. 2013: obackup v1.84RC2 released
---------------------------------------

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

16 Jul. 2013: obackup v1.84RC1 released
---------------------------------------

- Code cleanup
- Uploaded first documentation
- Fixed an issue with RotateBackups
- Updated obackup to log failed ssh command results
- Updated ssh command filter to log failed commands
- Updated ssh command filter to accept personalized commands
- 23 Jun. 2013: v1.84 RC1 approaching
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
