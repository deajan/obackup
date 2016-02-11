#!/usr/bin/env bash

PROGRAM="obackup config file upgrade script"
SUBPROGRAM="obackup"
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/obacup - ozy@netpower.fr"
OLD_PROGRAM_VERSION="v1.x"
NEW_PROGRAM_VERSION="v2.x"
PROGRAM_BUILD=2016021102

function Usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "This script migrates $SUBPROGRAM $OLD_PROGRAM_VERSION config files to $NEW_PROGRAM_VERSION."
	echo ""
	echo "Usage: $0 /path/to/config_file.conf"
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

	if ! grep "BACKUP_ID=" $config_file > /dev/null; then
		echo "File [$config_file] does not seem to be a obackup v1 config file."
		exit 1
	fi

	echo "Backing up [$config_file] as [$config_file.v1.x.save]"
	cp --preserve "$config_file" "$config_file.v1.x.save"
	if [ $? != 0 ]; then
		echo "Cannot backup config file."
		exit 1
	fi

	echo "Rewriting config file $config_file"

	sed -i 's/^BACKUP_ID=/INSTANCE_ID=/g' "$config_file"
	sed -i 's/^BACKUP_SQL=/SQL_BACKUP=/g' "$config_file"
	sed -i 's/^BACKUP_FILES=/FILE_BACKUP=/g' "$config_file"
	sed -i 's/^LOCAL_SQL_STORAGE=/SQL_STORAGE=/g' "$config_file"
	sed -i 's/^LOCAL_FILE_STORAGE=/FILE_STORAGE=/g' "$config_file"
	sed -i '/^FILE_STORAGE=*/a ENCRYPTION=no' "$config_file"
	sed -i 's/^DISABLE_GET_BACKUP_FILE_SIZE=no/GET_BACKUP_SIZE=yes/g' "$config_file"
	sed -i 's/^DISABLE_GET_BACKUP_FILE_SIZE=yes/GET_BACKUP_SIZE=no/g' "$config_file"
	sed -i 's/^LOCAL_STORAGE_KEEP_ABSOLUTE_PATHS=/KEEP_ABSOLUTE_PATHS=/g' "$config_file"
	sed -i 's/^LOCAL_STORAGE_WARN_MIN_SPACE=/SQL_WARN_MIN_SPACE=/g' "$config_file"
	VALUE=$(cat $config_file | grep "SQL_WARN_MIN_SPACE=")
	VALUE=${VALUE#*=}
	sed -i '/^SQL_WARN_MIN_SPACE=*/a FILE_WARN_MIN_SPACE='$VALUE "$config_file"
	# Add encryption
	sed -i 's/^DIRECTORIES_SIMPLE_LIST=/DIRECTORY_LIST=/g' "$config_file"
	sed -i 's/^DIRECTORIES_RECURSE_LIST=/RECURSIVE_DIRECTORY_LIST=/g' "$config_file"
	sed -i 's/^DIRECTORIES_RECURSE_EXCLUDE_LIST=/RECURSIVE_EXCLUDE_LIST=/g' "$config_file"
	sed -i 's/^ROTATE_BACKUPS=/ROTATE_SQL_BACKUPS=/g' "$config_file"
	VALUE=$(cat $config_file | grep "ROTATE_SQL_BACKUPS=")
	VALUE=${VALUE#*=}
	sed -i '/^ROTATE_SQL_BACKUPS=*/a ROTATE_FILE_BACKUPS='$VALUE "$config_file"
	sed -i 's/^ROTATE_COPIES=/ROTATE_SQL_COPIES=/g' "$config_file"
	VALUE=$(cat $config_file | grep "ROTATE_SQL_COPIES=")
	VALUE=${VALUE#*=}
	sed -i '/^ROTATE_SQL_COPIES=*/a ROTATE_FILE_COPIES='$VALUE "$config_file"

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

		sed -i 's#^REMOTE_BACKUP=yes#REMOTE_SYSTEM_URI='$REMOTE_SYSTEM_URI'#g' "$config_file"
		sed -i '/^REMOTE_USER=*/d' "$config_file"
		sed -i '/^REMOTE_HOST=*/d' "$config_file"
		sed -i '/^REMOTE_PORT=*/d' "$config_file"

		sed -i '/^INSTANCE_ID=*/a BACKUP_TYPE=pull' "$config_file"
	else
		sed -i '/^INSTANCE_ID=*/a BACKUP_TYPE=local' "$config_file"
	fi

	# Add new config values from v1.1 if they don't exist
	if ! grep "^ENCRYPTION=" "$config_file" > /dev/null; then
		sed -i '/^FILE_STORAGE=*/a ENCRYPTION=no' "$config_file"
	fi

	if ! grep "^CREATE_DIRS=" "$config_file" > /dev/null; then
		sed -i '/^ENCRYPTION=*/a CREATE_DIRS=yes' "$config_file"
	fi

	if ! grep "^GET_BACKUP_SIZE=" "$config_file" > /dev/null; then
		sed -i '/^BACKUP_SIZE_MINIMUM=*/a GET_BACKUP_SIZE=yes' "$config_file"
	fi

	if ! grep "^RSYNC_REMOTE_PATH=" "$config_file" > /dev/null; then
		sed -i '/^SSH_COMPRESSION=*/a RSYNC_REMOTE_PATH=' "$config_file"
	fi

	if ! grep "^REMOTE_HOST_PING=" "$config_file" > /dev/null; then
		sed -i '/^RSYNC_REMOTE_PATH=*/a REMOTE_HOST_PING=yes' "$config_file"
	fi

	if ! grep "^COPY_SYMLINKS=" "$config_file" > /dev/null; then
		sed -i '/^PRESERVE_XATTR=*/a COPY_SYMLINKS=yes' "$config_file"
	fi

	if ! grep "^KEEP_DIRLINKS=" "$config_file" > /dev/null; then
		sed -i '/^COPY_SYMLINKS=*/a KEEP_DIRLINKS=yes' "$config_file"
	fi

	if ! grep "^PRESERVE_HARDLINKS=" "$config_file" > /dev/null; then
		sed -i '/^KEEP_DIRLINKS=*/a PRESERVE_HARDLINKS=no' "$config_file"
	fi

	if ! grep "^RSYNC_PATTERN_FIRST=" "$config_file" > /dev/null; then
		sed -i '/^LOGFILE=*/a RSYNC_PATTERN_FIRST=include' "$config_file"
	fi

	if ! grep "^RSYNC_INCLUDE_PATTERN=" "$config_file" > /dev/null; then
	        sed -i '/^RSYNC_EXCLUDE_PATTERN=*/a RSYNC_INCLUDE_PATTERN=""' "$config_file"
	fi

	if ! grep "^RSYNC_INCLUDE_FROM=" "$config_file" > /dev/null; then
	        sed -i '/^RSYNC_EXCLUDE_FROM=*/a RSYNC_INCLUDE_FROM=""' "$config_file"
	fi

        if ! grep "^PARTIAL=" "$config_file" > /dev/null; then
                sed -i '/^HARD_MAX_EXEC_TIME_FILE_TASK==*/a PARTIAL=no' "$config_file"
        fi

	if ! grep "^DELETE_VANISHED_FILES=" "$config_file" > /dev/null; then
		sed -i '/^PARTIAL=*/a DELETE_VANISHED_FILES=no' "$config_file"
	fi

	if ! grep "^DELTA_COPIES=" "$config_file" > /dev/null; then
                sed -i '/^PARTIAL=*/a DELTA_COPIES=yes' "$config_file"
        fi

	if ! grep "^BANDWIDTH=" "$config_file" > /dev/null; then
                sed -i '/^DELTA_COPIES=*/a BANDWIDTH=0' "$config_file"
        fi

	if ! grep "^STOP_ON_CMD_ERROR=" "$config_file" > /dev/null; then
                sed -i '/^MAX_EXEC_TIME_PER_CMD_AFTER=*/a STOP_ON_CMD_ERROR=no' "$config_file"
        fi
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
