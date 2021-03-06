# obackup [![Build Status](https://travis-ci.org/deajan/obackup.svg?branch=master)](https://travis-ci.org/deajan/obackup) [![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause) [![GitHub Release](https://img.shields.io/github/release/deajan/obackup.svg?label=Latest)](https://github.com/deajan/obackup/releases/latest)

A robust file & database backup script that works for local and remote push or pull backups via ssh.
Designed to backup multiple subdirectories with a timeslot for each.
Supports encryption while still using rsync to lower transfered data (see advantages and caveats below).

## About

obackup is designed to make the backup process as reliable as possible.
It divides the whole backup process into tasks, allowing each task to execute for a certain amount of time.
If a task doesn't finish in time, it's stopped and the next task in list is processed.
Before a task gets stopped, a first warning message is generated telling the task takes too long.
Every action gets logged, and if a warning has been generated, a task gets stopped or an error happens, an alert email will be sent.

Remote backups are initiated from the backup server instead of the production server, so hacked servers won't get ssh access to the backup server.

obackup can enumerate and backup all MariaDB / MySQL databases present on a server.
It can also enumarate all subdirectories of a given path and process them as separate tasks (usefull for multiple vhosts).
It will do several checks before launching a backup like execution checks, dryruns, checking backup size and available local disk space.

obackup can execute local and remote commands before and after backup execution,
thus providing an easy way to handle snapshots (see https://github.com/deajan/zsnap for a zfs snapshot management script).
It may also rotate backups for you.

As of today, obackup has been tested successfully on RHEL / CentOS 5, 6 and 7, Debian 6 and 7, Linux Mint 14 and 17, FreeBSD 8.3 and 10.3.
Currently, obackup also runs on MacOSX and Windows MSYS environment.

## Warning

Obackup now follows symlinks and treats them as the referent files / dirs, following symlinks even outside the backup root, which IMHO is more secure in terms of backups.
You may disable this behavior in the config file.

## Installation

You can download the latest obackup script from authors website.
You may also clone the following git which will maybe have some more recent builds.

    $ git clone -b "v2.1-maint" git://github.com/deajan/obackup.git
    $ cd obackup
    $ ./install.sh

obackup needs to run with bash shell, using any other shell will most probably fail.  
Once you have grabbed a copy, just edit the config file with your favorite text editor to setup your environment and you're ready to run.
A detailled documentation can be found on the author's site.
You can run multiple instances of obackup scripts with different backup environments. Just create another configuration file,
edit it's environment and you're ready to run concurrently.

Performing remote backups requires you to create RSA private / public key pair. Please see documentation for further information.
Performing mysql backups requires to create a mysql user with SELECT rights on all databases. Please see documentation for further information.
Performing backup with SUDO_EXEC option requires to configure sudoers file to allow some commands without password.
Keep in mind that running backup as superuser might be a security risk. You should generally prefer a read only enabled user.
Please see documentation for further information.

## Usage

MariaDB / MySQL backups are consistent because dumps are done with the --single-transaction option.
File backups can be done directly if data won't change while a backup is going on (generally true on vhosts),
but backing up a snapshot of the actual data is preferable as it will stay consistent. LVM, zfs or btrfs snapshots will do fine.

You may try your setup by specifying the "--dry" parameter which will run a simulation of what will be done. Specifying "--verbose" will also list any command
that's actually launched and it's result.

    $ ./obackup.sh path/to/backup.conf --dry
    $ ./obackup.sh path/to/backup.conf
    $ ./obackup.sh path/to/backup.conf --silent
	

One you're happy with a test run, you may run obackup as a cron task with the "--silent" parameter so output will not be written to stdout.
All backup activity is logged to "/var/log/obackup_backupname.log" or current directory if /var/log is not writable.

You may mix "--silent" and "--verbose" parameters to output verbose input only in the log files.

## Troubleshooting

Whenever you may encounter rsync zombie processes and/or in unterruptible sleep state processes, you should force unmounting network drives obackup is supposed to deal with.

## Final words

Backup tasks aren't always reliable, connectivity loss, insufficient disk space, hacked servers with tons of unusefull stuff to backup... Anything can happen.
obackup will sent your a warning email for every issue it can handle.
Nevertheless, you should assure yourself that your backup tasks will get done the way you meant it. Also, a backup isn't valuable until you're sure
you can successfully restore. Try to restore your backups to check whether everything is okay. Backups will keep file permissions and owners,
but may loose ACLs if destination file system won't handle them. 

## Author

Feel free to mail me for limited support in my free time :)
Orsiris de Jong | ozy@netpower.fr
