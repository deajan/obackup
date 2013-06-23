#!/bin/bash

##### Obackup ssh command filter

## Paranoia option. Only change this if you read the documentation and know what you're doing
RSYNC_EXECUTABLE=rsync

function Go
{
	$SSH_ORIGINAL_COMMAND
}

case ${SSH_ORIGINAL_COMMAND%% *} in
	"$RSYNC_EXECUTABLE")
	Go ;;
	"mysqldump")
	Go ;;
	"find")
	Go ;;
	"du")
	Go ;;
	"sudo")
	if [[ "$SSH_ORIGINAL_COMMAND" == "sudo $RSYNC_EXECUTABLE"* ]]
	then
		Go
	elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo du"* ]]
	then
		Go
	elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo find"* ]]
	then
		Go
	else
		echo "Sudo command not allowed."
	fi
	;;
	*)
	echo "Not allowed."
esac
 

