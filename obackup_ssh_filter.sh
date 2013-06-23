#!/bin/bash

##### Obackup ssh command filter

## If enabled, execution of "sudo" command will be allowed.
SUDO_EXEC=yes
## Paranoia option. Don't change this unless you read the documentation and still feel concerned about security issues.
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
		else
			echo "Sudo command not allowed."
		fi
	else
		echo "Sudo command not enabled."
	fi
	;;
	*)
	echo "Not allowed."
esac
 

