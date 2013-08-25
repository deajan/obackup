#!/bin/bash

##### Obackup / Osync ssh command filter build 2306201301
##### This script should be located in /usr/local/bin in the remote system that will be backed up / synced
##### It will filter the commands that can be run remotely via ssh.
##### Please chmod 755 and chown root:root this file

## If enabled, execution of "sudo" command will be allowed.
SUDO_EXEC=yes
## Paranoia option. Don't change this unless you read the documentation and still feel concerned about security issues.
RSYNC_EXECUTABLE=rsync
## Enable other commands, useful for remote execution hooks like remotely creating snapshots.
CMD1=
CMD2=
CMD3=

LOG_FILE=~/.ssh/ssh_filter.log

function Log
{
	DATE=$(date)
	echo "$DATE - $1" >> $LOG_FILE
}

function Go
{
	eval $SSH_ORIGINAL_COMMAND
}

case ${SSH_ORIGINAL_COMMAND%% *} in
	"$RSYNC_EXECUTABLE")
	Go ;;
	"mysqldump")
	Go ;;
	"mysql")
	Go ;;
	"echo")
	Go ;;
	"find")
	Go ;;
	"du")
	Go ;;
	"$CMD1")
	Go ;;
	"$CMD2")
	Go ;;
	"$CMD3")
	Go ;;
	"sudo")
	if [ "$SUDO_EXEC" == "yes" ]
	then
		if [[ "$SSH_ORIGINAL_COMMAND" == "sudo $RSYNC_EXECUTABLE"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo du"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo find"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD1"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD2"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD3"* ]]
		then
			Go
		else
			Log "Command [$SSH_ORIGINAL_COMMAND] not allowed."
		fi
	else
		Log "Command [$SSH_ORIGINAL_COMMAND] not allowed. sudo not enabled."
	fi
	;;
	*)
	Log "Command [$SSH_ORIGINAL_COMMAND] not allowed."
esac
