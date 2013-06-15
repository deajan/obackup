obackup
=======

A file & database backup script tailored for multiple virtualhost backups locally or remotely via ssh.
Yet it actually works for a lot of backup tasks.

## About

OBackup is designed from ground to make the backup process as reliable as possible.
It divides the whole backup process into tasks, allowing each task to execute for a certain amount of time.
If a task doesn't finish in time, it's stopped and the next task is processed.
Before a task gets stopped, a first warning message is generated telling the task takes too long.
Every action gets logged, and at the end of the backup process, if there was a warning,
a stopped task or an error an alert email will be sent.

Remote backups are initiated from the backup server instead of the production server, so hacked servers won't get ssh access to the backup server.

OBackup can enumerate and backup all MariaDB / MySQL databases present on a server
It can also enumarate all subdirectories of a given path and process them as separate tasks (usefull for multiple vhosts).
It will do several checks before launching a backup like execution checks, dryruns,
checking backup size and available local disk space.

Obackup will work well to backup to a snapshot aware filesystem like ZFS or btrfs.
In case you don't work with one of these, it may also rotate backups for you.

As of today, obackup has been tested successfully on RHEL / CentOS 5, CentOS 6, Debian 6.0.7 and Linux Mint 14
but should basically run on your favorite linux flavor. It relies on well known programs like rsync, ssh, mysqldump along
with other great GNU coreutils.

## Installation

You can download the latest obackup script from authors website.
You may also clone this git which will maybe have some more recent build.

    $ git clone git://github.com/deajan/obackup.git
    $ chmod +x ./obackup.sh
  
Once you have grabbed a copy of Obackup, just edit the config file with your favorite text editor to setup your environment and you're ready to run. A detailled documentation can be found in the DOCUMENTATION.md file.

You can run multiple instances of obackup scripts with different backup environments. Just create another configuration file, edit it's environment and you're ready to run concurrently.

## Usage

MariaDB / MySQL backups are consistent because dumps are done with the --single-transaction option.
File backups can be done directly if data won't change while a backup is going on (generally true on vhosts), but backing up a snapshot of the actual data is preferable as it will stay consistent. LVM, zfs or btrfs snapshots will do fine.

You may try your setup by specifying the "--dry" parameter which will run a simulation of what will be done.

    $ ./obackup.sh path/to/config/file --dry
    $ ./obackup.sh path/to/config/file

One you're happy with a test run, you may run obackup as a cron task with the "--silent" parameter so output will not be written to stdout.
All backup activity is logged to "/var/log/obackup_backupname.log".

## Final words

Backup tasks aren't always reliable, connectivity loss, insufficient disk space, hacked computers with tons of mangas to backup... Anything can happen. Obackup will sent your a warning email for every issue it can handle.
Nevertheless, you should assure yourself that your backup tasks will get done the way you meant it. Also, a backup isn't valuable until you're sure it's restoration will be a success. Try to restore your backups to check whether everything is okay. Backups will keep file permissions and owners, but may loose ACLs if destination file system won't handle them. 

## Author

Orsiris "Ozy" de Jong.
ozy@badministrateur.com


 
