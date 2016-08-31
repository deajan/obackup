#!/usr/bin/env bash

PROGRAM="obackup config file upgrade script"
SUBPROGRAM="obackup"
AUTHOR="(C) 2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obacup - ozy@netpower.fr"
OLD_PROGRAM_VERSION="v1.x"
NEW_PROGRAM_VERSION="v2.1x"
PROGRAM_BUILD=2016081901

## type -p does not work on platforms other than linux (bash). If if does not work, always as$
if ! type "$BASH" > /dev/null; then
        echo "Please run this script only with bash shell. Tested on bash >= 3.2"
        exit 127
fi

function Usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "This script migrates $SUBPROGRAM $OLD_PROGRAM_VERSION config files to $NEW_PROGRAM_VERSION."
	echo ""
	echo "Usage: $0 /path/to/config_file.conf"
	echo "Please make sure the config file is writable."
	exit 128
}

function LoadConfigFile {
	local config_file="${1}"

	if [ ! -f "$config_file" ]; then
		echo "Cannot load configuration file [$config_file]. Sync cannot start."
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		echo "Wrong configuration file supplied [$config_file]. Sync cannot start."
		exit 1
	else
		egrep '^#|^[^ ]*=[^;&]*'  "$config_file" > "./$SUBPROGRAM.$FUNCNAME.$$"
		source "./$SUBPROGRAM.$FUNCNAME.$$"
		rm -f "./$SUBPROGRAM.$FUNCNAME.$$"
	fi
}

function RewriteConfigFiles {
	local config_file="${1}"

	if ((! grep "BACKUP_ID=" $config_file > /dev/null) && ( ! grep "INSTANCE_ID=" $config_file > /dev/null)); then
		echo "File [$config_file] does not seem to be a obackup config file."
		exit 1
	fi

	echo "Backing up [$config_file] as [$config_file.save]"
	cp -p "$config_file" "$config_file.save"
	if [ $? != 0 ]; then
		echo "Cannot backup config file."
		exit 1
	fi

	echo "Rewriting config file $config_file"

	sed -i'.tmp' 's/^BACKUP_ID=/INSTANCE_ID=/g' "$config_file"
	sed -i'.tmp' 's/^BACKUP_SQL=/SQL_BACKUP=/g' "$config_file"
	sed -i'.tmp' 's/^BACKUP_FILES=/FILE_BACKUP=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_SQL_STORAGE=/SQL_STORAGE=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_FILE_STORAGE=/FILE_STORAGE=/g' "$config_file"

	if ! grep "^ENCRYPTION=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^FILE_STORAGE=*/a\'$'\n''ENCRYPTION=no\'$'\n''' "$config_file"
	fi

	if ! grep "^ENCRYPT_STORAGE=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^ENCRYPTION=*/a\'$'\n''ENCRYPT_STORAGE=/home/storage/backup/crypt\'$'\n''' "$config_file"
	fi

	if ! grep "^ENCRYPT_PUBKEY=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^ENCRYPT_STORAGE=*/a\'$'\n''ENCRYPTION='${HOME}/.gpg/pubkey'\'$'\n''' "$config_file"
	fi

	sed -i'.tmp' 's/^DISABLE_GET_BACKUP_FILE_SIZE=no/GET_BACKUP_SIZE=yes/g' "$config_file"
	sed -i'.tmp' 's/^DISABLE_GET_BACKUP_FILE_SIZE=yes/GET_BACKUP_SIZE=no/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_STORAGE_KEEP_ABSOLUTE_PATHS=/KEEP_ABSOLUTE_PATHS=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_STORAGE_WARN_MIN_SPACE=/SQL_WARN_MIN_SPACE=/g' "$config_file"
	if ! grep "^FILE_WARN_MIN_SPACE=" "$config_file" > /dev/null; then
		VALUE=$(cat $config_file | grep "SQL_WARN_MIN_SPACE=")
		VALUE=${VALUE#*=}
		sed -i'.tmp' '/^SQL_WARN_MIN_SPACE=*/a\'$'\n''FILE_WARN_MIN_SPACE='$VALUE'\'$'\n''' "$config_file"
	fi
	sed -i'.tmp' 's/^DIRECTORIES_SIMPLE_LIST=/DIRECTORY_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^DIRECTORIES_RECURSE_LIST=/RECURSIVE_DIRECTORY_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^DIRECTORIES_RECURSE_EXCLUDE_LIST=/RECURSIVE_EXCLUDE_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^ROTATE_BACKUPS=/ROTATE_SQL_BACKUPS=/g' "$config_file"
	if ! grep "^ROTATE_FILE_BACKUPS=" "$config_file" > /dev/null; then
		VALUE=$(cat $config_file | grep "ROTATE_SQL_BACKUPS=")
		VALUE=${VALUE#*=}
		sed -i'.tmp' '/^ROTATE_SQL_BACKUPS=*/a\'$'\n''ROTATE_FILE_BACKUPS='$VALUE'\'$'\n''' "$config_file"
	fi
	sed -i'.tmp' 's/^ROTATE_COPIES=/ROTATE_SQL_COPIES=/g' "$config_file"
	if ! grep "^ROTATE_FILE_COPIES=" "$config_file" > /dev/null; then
		VALUE=$(cat $config_file | grep "ROTATE_SQL_COPIES=")
		VALUE=${VALUE#*=}
		sed -i'.tmp' '/^ROTATE_SQL_COPIES=*/a\'$'\n''ROTATE_FILE_COPIES='$VALUE'\'$'\n''' "$config_file"
	fi
	REMOTE_BACKUP=$(cat $config_file | grep "REMOTE_BACKUP=")
	REMOTE_BACKUP=${REMOTE_BACKUP#*=}
	if [ "$REMOTE_BACKUP" == "yes" ]; then
		REMOTE_USER=$(cat $config_file | grep "REMOTE_USER=")
		REMOTE_USER=${REMOTE_USER#*=}
		REMOTE_HOST=$(cat $config_file | grep "REMOTE_HOST=")
		REMOTE_HOST=${REMOTE_HOST#*=}
		REMOTE_PORT=$(cat $config_file | grep "REMOTE_PORT=")
		REMOTE_PORT=${REMOTE_PORT#*=}

		REMOTE_SYSTEM_URI="ssh://$REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT/"

		sed -i'.tmp' 's#^REMOTE_BACKUP=yes#REMOTE_SYSTEM_URI='$REMOTE_SYSTEM_URI'#g' "$config_file"
		sed -i'.tmp' '/^REMOTE_USER=*/d' "$config_file"
		sed -i'.tmp' '/^REMOTE_HOST=*/d' "$config_file"
		sed -i'.tmp' '/^REMOTE_PORT=*/d' "$config_file"

		sed -i'.tmp' '/^INSTANCE_ID=*/a\'$'\n''BACKUP_TYPE=pull\'$'\n''' "$config_file"
	else
		if ! grep "^BACKUP_TYPE=" "$config_file" > /dev/null; then
			sed -i'.tmp' '/^INSTANCE_ID=*/a\'$'\n''BACKUP_TYPE=local\'$'\n''' "$config_file"
		fi
	fi

	# Add new config values from v1.1 if they don't exist
	if ! grep "^CREATE_DIRS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^ENCRYPTION=*/a\'$'\n''CREATE_DIRS=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^GET_BACKUP_SIZE=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^BACKUP_SIZE_MINIMUM=*/a\'$'\n''GET_BACKUP_SIZE=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^MYSQLDUMP_OPTIONS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^HARD_MAX_EXEC_TIME_DB_TASK=*/a\'$'\n''MYSQLDUMP_OPTIONS="--opt --single-transaction"\'$'\n''' "$config_file"
	fi

	if ! grep "^RSYNC_REMOTE_PATH=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^SSH_COMPRESSION=*/a\'$'\n''RSYNC_REMOTE_PATH=\'$'\n''' "$config_file"
	fi

	if ! grep "^SSH_IGNORE_KNOWN_HOSTS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^SSH_COMPRESSION=*/a\'$'\n''SSH_IGNORE_KNOWN_HOSTS=no\'$'\n''' "$config_file"
	fi

	if ! grep "^REMOTE_HOST_PING=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^RSYNC_REMOTE_PATH=*/a\'$'\n''REMOTE_HOST_PING=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^COPY_SYMLINKS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PRESERVE_XATTR=*/a\'$'\n''COPY_SYMLINKS=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^KEEP_DIRLINKS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^COPY_SYMLINKS=*/a\'$'\n''KEEP_DIRLINKS=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_HARDLINKS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^KEEP_DIRLINKS=*/a\'$'\n''PRESERVE_HARDLINKS=no\'$'\n''' "$config_file"
	fi

	if ! grep "^RSYNC_PATTERN_FIRST=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^RECURSIVE_EXCLUDE_LIST=*/a\'$'\n''RSYNC_PATTERN_FIRST=include\'$'\n''' "$config_file"
	fi

	if ! grep "^RSYNC_INCLUDE_PATTERN=" "$config_file" > /dev/null; then
	        sed -i'.tmp' '/^RSYNC_EXCLUDE_PATTERN=*/a\'$'\n''RSYNC_INCLUDE_PATTERN=""\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_PERMISSIONS=" "$config_file" > /dev/null; then
	        sed -i'.tmp' '/^PATH_SEPARATOR_CHAR=*/a\'$'\n''PRESERVE_PERMISSIONS=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_OWNER=" "$config_file" > /dev/null; then
	        sed -i'.tmp' '/^PRESERVE_PERMISSIONS=*/a\'$'\n''PRESERVE_OWNER=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_GROUP=" "$config_file" > /dev/null; then
	        sed -i'.tmp' '/^PRESERVE_OWNER=*/a\'$'\n''PRESERVE_GROUP=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_EXECUTABILITY=" "$config_file" > /dev/null; then
	        sed -i'.tmp' '/^PRESERVE_GROUP=*/a\'$'\n''PRESERVE_EXECUTABILITY=yes\'$'\n''' "$config_file"
	fi

        if ! grep "^PARTIAL=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^HARD_MAX_EXEC_TIME_FILE_TASK==*/a\'$'\n''PARTIAL=no\'$'\n''' "$config_file"
        fi

	if ! grep "^DELETE_VANISHED_FILES=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PARTIAL=*/a\'$'\n''DELETE_VANISHED_FILES=no\'$'\n''' "$config_file"
	fi

	if ! grep "^DELTA_COPIES=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^PARTIAL=*/a\'$'\n''DELTA_COPIES=yes\'$'\n''' "$config_file"
        fi

	if ! grep "^BANDWIDTH=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^DELTA_COPIES=*/a\'$'\n''BANDWIDTH=0\'$'\n''' "$config_file"
        fi

	if ! grep "^KEEP_LOGGING=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^HARD_MAX_EXEC_TIME_TOTAL=*/a\'$'\n''KEEP_LOGGING=1801\'$'\n''' "$config_file"
        fi

	if ! grep "^STOP_ON_CMD_ERROR=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^MAX_EXEC_TIME_PER_CMD_AFTER=*/a\'$'\n''STOP_ON_CMD_ERROR=no\'$'\n''' "$config_file"
        fi

	if ! grep "^RUN_AFTER_CMD_ON_ERROR=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^STOP_ON_CMD_ERROR=*/a\'$'\n''RUN_AFTER_CMD_ON_ERROR=no\'$'\n''' "$config_file"
        fi

	# "onfig file rev" to deal with earlier variants of the file
        sed -i'.tmp' '/onfig file rev/c\###### '$SUBPROGRAM' config file rev '$PROGRAM_BUILD "$config_file"

	rm -f "$config_file.tmp"
}

if [ "$1" != "" ] && [ -f "$1" ] && [ -w "$1" ]; then
	CONF_FILE="$1"
	# Make sure there is no ending slash
	CONF_FILE="${CONF_FILE%/}"
	LoadConfigFile "$CONF_FILE"
	RewriteConfigFiles "$CONF_FILE"
else
	Usage
fi
