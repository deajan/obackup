#!/usr/bin/env bash

PROGRAM="obackup.upgrade"
SUBPROGRAM="obackup"
AUTHOR="(C) 2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obacup - ozy@netpower.fr"
OLD_PROGRAM_VERSION="v1.x"
NEW_PROGRAM_VERSION="v2.1x"
CONFIG_FILE_REVISION=2.1
PROGRAM_BUILD=2019072301

if ! type "$BASH" > /dev/null; then
        echo "Please run this script only with bash shell. Tested on bash >= 3.2"
        exit 127
fi

# Defines all keywords / value sets in obackup configuration files
# bash does not support two dimensional arrays, so we declare two arrays:
# ${KEYWORDS[index]}=${VALUES[index]}

KEYWORDS=(
INSTANCE_ID
LOGFILE
SQL_BACKUP
FILE_BACKUP
BACKUP_TYPE
SQL_STORAGE
FILE_STORAGE
ENCRYPTION
CRYPT_STORAGE
GPG_RECIPIENT
PARALLEL_ENCRYPTION_PROCESSES
CREATE_DIRS
KEEP_ABSOLUTE_PATHS
BACKUP_SIZE_MINIMUM
GET_BACKUP_SIZE
SQL_WARN_MIN_SPACE
FILE_WARN_MIN_SPACE
REMOTE_SYSTEM_URI
SSH_RSA_PRIVATE_KEY
SSH_PASSWORD_FILE
_REMOTE_TOKEN
SSH_COMPRESSION
SSH_IGNORE_KNOWN_HOSTS
RSYNC_REMOTE_PATH
REMOTE_HOST_PING
REMOTE_3RD_PARTY_HOSTS
SUDO_EXEC
SQL_USER
DATABASES_ALL
DATABASES_ALL_EXCLUDE_LIST
DATABASES_LIST
SOFT_MAX_EXEC_TIME_DB_TASK
HARD_MAX_EXEC_TIME_DB_TASK
MYSQLDUMP_OPTIONS
COMPRESSION_LEVEL
DIRECTORY_LIST
RECURSIVE_DIRECTORY_LIST
RECURSIVE_EXCLUDE_LIST
RSYNC_PATTERN_FIRST
RSYNC_INCLUDE_PATTERN
RSYNC_EXCLUDE_PATTERN
RSYNC_INCLUDE_FROM
RSYNC_EXCLUDE_FROM
PATH_SEPARATOR_CHAR
RSYNC_OPTIONAL_ARGS
PRESERVE_PERMISSIONS
PRESERVE_OWNER
PRESERVE_GROUP
PRESERVE_EXECUTABILITY
PRESERVE_ACL
PRESERVE_XATTR
COPY_SYMLINKS
KEEP_DIRLINKS
PRESERVE_HARDLINKS
RSYNC_COMPRESS
SOFT_MAX_EXEC_TIME_FILE_TASK
HARD_MAX_EXEC_TIME_FILE_TASK
PARTIAL
DELETE_VANISHED_FILES
DELTA_COPIES
BANDWIDTH
RSYNC_EXECUTABLE
DESTINATION_MAILS
MAIL_BODY_CHARSET
SENDER_MAIL
SMTP_SERVER
SMTP_PORT
SMTP_ENCRYPTION
SMTP_USER
SMTP_PASSWORD
SOFT_MAX_EXEC_TIME_TOTAL
HARD_MAX_EXEC_TIME_TOTAL
KEEP_LOGGING
ROTATE_SQL_BACKUPS
ROTATE_SQL_COPIES
ROTATE_FILE_BACKUPS
ROTATE_FILE_COPIES
LOCAL_RUN_BEFORE_CMD
LOCAL_RUN_AFTER_CMD
REMOTE_RUN_BEFORE_CMD
REMOTE_RUN_AFTER_CMD
MAX_EXEC_TIME_PER_CMD_BEFORE
MAX_EXEC_TIME_PER_CMD_AFTER
STOP_ON_CMD_ERROR
RUN_AFTER_CMD_ON_ERROR
)

VALUES=(
test-backup
''
true
true
local
/home/storage/sql
/home/storage/files
false
/home/storage/crypt
'Your Name used with GPG signature'
''
true
true
1024
true
1048576
1048576
ssh://backupuser@remote.system.tld:22/
${HOME}/.ssh/id_rsa
''
SomeAlphaNumericToken9
true
false
''
true
'www.kernel.org www.google.com'
false
root
true
test
''
3600
7200
'--opt --single-transaction'
3
''
''
;/lost+found
include
''
''
''
''
\;
''
true
true
true
true
false
false
true
true
false
false
3600
7200
false
false
true
0
rsync
infrastructure@example.com
''
sender@example.com
smtp.isp.tld
25
none
''
''
30000
36000
1801
false
7
false
7
''
''
''
''
0
0
false
false
)

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

function CheckAndBackup {
	local config_file="${1}"

	if ! grep "BACKUP_ID=" $config_file > /dev/null && ! grep "INSTANCE_ID=" $config_file > /dev/null; then
		echo "File [$config_file] does not seem to be a obackup config file."
		exit 1
	fi

	echo "Backing up [$config_file] as [$config_file.save]"
	cp -p "$config_file" "$config_file.save"
	if [ $? != 0 ]; then
		echo "Cannot backup config file."
		exit 1
	fi
}

function RewriteOldConfigFiles {
	local config_file="${1}"

	echo "Rewriting config file $config_file"

	sed -i'.tmp' 's/^BACKUP_ID=/INSTANCE_ID=/g' "$config_file"
	sed -i'.tmp' 's/^BACKUP_SQL=/SQL_BACKUP=/g' "$config_file"
	sed -i'.tmp' 's/^BACKUP_FILES=/FILE_BACKUP=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_SQL_STORAGE=/SQL_STORAGE=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_FILE_STORAGE=/FILE_STORAGE=/g' "$config_file"

	sed -i'.tmp' 's/^DISABLE_GET_BACKUP_FILE_SIZE=no/GET_BACKUP_SIZE=true/g' "$config_file"
	sed -i'.tmp' 's/^DISABLE_GET_BACKUP_FILE_SIZE=yes/GET_BACKUP_SIZE=false/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_STORAGE_KEEP_ABSOLUTE_PATHS=/KEEP_ABSOLUTE_PATHS=/g' "$config_file"
	sed -i'.tmp' 's/^LOCAL_STORAGE_WARN_MIN_SPACE=/SQL_WARN_MIN_SPACE=/g' "$config_file"
	if ! grep "^FILE_WARN_MIN_SPACE=" "$config_file" > /dev/null; then
		VALUE=$(grep "SQL_WARN_MIN_SPACE=" "$config_file")
		VALUE="${VALUE#*=}"
		sed -i'.tmp' '/^SQL_WARN_MIN_SPACE=*/a\'$'\n''FILE_WARN_MIN_SPACE='$VALUE'\'$'\n''' "$config_file"
	fi
	sed -i'.tmp' 's/^DIRECTORIES_SIMPLE_LIST=/DIRECTORY_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^DIRECTORIES_RECURSE_LIST=/RECURSIVE_DIRECTORY_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^DIRECTORIES_RECURSE_EXCLUDE_LIST=/RECURSIVE_EXCLUDE_LIST=/g' "$config_file"
	sed -i'.tmp' 's/^ROTATE_BACKUPS=/ROTATE_SQL_BACKUPS=/g' "$config_file"
	if ! grep "^ROTATE_FILE_BACKUPS=" "$config_file" > /dev/null; then
		VALUE=$(grep "ROTATE_SQL_BACKUPS=" "$config_file")
		VALUE="${VALUE#*=}"
		sed -i'.tmp' '/^ROTATE_SQL_BACKUPS=*/a\'$'\n''ROTATE_FILE_BACKUPS='$VALUE'\'$'\n''' "$config_file"
	fi
	sed -i'.tmp' 's/^ROTATE_COPIES=/ROTATE_SQL_COPIES=/g' "$config_file"
	if ! grep "^ROTATE_FILE_COPIES=" "$config_file" > /dev/null; then
		VALUE=$(grep "ROTATE_SQL_COPIES=" "$config_file")
		VALUE="${VALUE#*=}"
		sed -i'.tmp' '/^ROTATE_SQL_COPIES=*/a\'$'\n''ROTATE_FILE_COPIES='$VALUE'\'$'\n''' "$config_file"
	fi
	REMOTE_BACKUP=$(grep "REMOTE_BACKUP=" "$config_file")
	REMOTE_BACKUP="${REMOTE_BACKUP#*=}"
	if [ "$REMOTE_BACKUP" == "yes" ]; then
		REMOTE_USER=$(grep "REMOTE_USER=" "$config_file")
		REMOTE_USER="${REMOTE_USER#*=}"
		REMOTE_HOST=$(grep "REMOTE_HOST=" "$config_file")
		REMOTE_HOST="${REMOTE_HOST#*=}"
		REMOTE_PORT=$(grep "REMOTE_PORT=" "$config_file")
		REMOTE_PORT="${REMOTE_PORT#*=}"

		REMOTE_SYSTEM_URI="ssh://$REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT/"

		sed -i'.tmp' 's#^REMOTE_BACKUP=true#REMOTE_SYSTEM_URI='$REMOTE_SYSTEM_URI'#g' "$config_file"
		sed -i'.tmp' 's#^REMOTE_BACKUP=yes#REMOTE_SYSTEM_URI='$REMOTE_SYSTEM_URI'#g' "$config_file"
		sed -i'.tmp' '/^REMOTE_USER==*/d' "$config_file"
		sed -i'.tmp' '/^REMOTE_HOST==*/d' "$config_file"
		sed -i'.tmp' '/^REMOTE_PORT==*/d' "$config_file"

		sed -i'.tmp' '/^INSTANCE_ID=*/a\'$'\n''BACKUP_TYPE=pull\'$'\n''' "$config_file"
	else
		if ! grep "^BACKUP_TYPE=" "$config_file" > /dev/null; then
			sed -i'.tmp' '/^INSTANCE_ID=*/a\'$'\n''BACKUP_TYPE=local\'$'\n''' "$config_file"
		fi
	fi
	sed -i'.tmp' 's/^REMOTE_3RD_PARTY_HOST=/REMOTE_3RD_PARTY_HOSTS=/g' "$config_file"
}

function AddMissingConfigOptions {
	local config_file="${1}"
	local counter=0

	while [ $counter -lt ${#KEYWORDS[@]} ]; do
		if ! grep "^${KEYWORDS[$counter]}=" > /dev/null "$config_file"; then
			echo "${KEYWORDS[$counter]} not found"
			if [ $counter -gt 0 ]; then
				if [ "${VALUES[$counter]}" == true ] || [ "${VALUES[$counter]}" == false ]; then
					sed -i'.tmp' '/^'${KEYWORDS[$((counter-1))]}'=*/a\'$'\n'${KEYWORDS[$counter]}'='"${VALUES[$counter]}"'\'$'\n''' "$config_file"
				else
					sed -i'.tmp' '/^'${KEYWORDS[$((counter-1))]}'=*/a\'$'\n'${KEYWORDS[$counter]}'="'"${VALUES[$counter]}"'"\'$'\n''' "$config_file"
				fi
				if [ $? -ne 0 ]; then
					echo "Cannot add missing ${[KEYWORDS[$counter]}."
					exit 1
				fi
			else
				if [ "${VALUES[$counter]}" == true ] || [ "${VALUES[$counter]}" == false ]; then
					sed -i'.tmp' '/[GENERAL\]$//a\'$'\n'${KEYWORDS[$counter]}'='"${VALUES[$counter]}"'\'$'\n''' "$config_file"
				else
					sed -i'.tmp' '/[GENERAL\]$//a\'$'\n'${KEYWORDS[$counter]}'="'"${VALUES[$counter]}"'"\'$'\n''' "$config_file"
				fi
				if [ $? -ne 0 ]; then
					echo "Cannot add missing ${[KEYWORDS[$counter]}."
					exit 1
				fi
			fi
			echo "Added missing ${KEYWORDS[$counter]} config option with default option [${VALUES[$counter]}]"
		else
			# Not the most elegant but the quickest way :)
                        if grep "^${KEYWORDS[$counter]}=yes$" > /dev/null "$config_file"; then
                                sed -i'.tmp' 's/^'${KEYWORDS[$counter]}'=.*/'${KEYWORDS[$counter]}'=true/g' "$config_file"
                                if [ $? -ne 0 ]; then
                                        echo "Cannot rewrite ${[KEYWORDS[$counter]} boolean to true."
                                        exit 1
                                fi
                        elif grep "^${KEYWORDS[$counter]}=no$" > /dev/null "$config_file"; then
                                sed -i'.tmp' 's/^'${KEYWORDS[$counter]}'=.*/'${KEYWORDS[$counter]}'=false/g' "$config_file"
                                if [ $? -ne 0 ]; then
                                        echo "Cannot rewrite ${[KEYWORDS[$counter]} boolean to false."
                                        exit 1
                                fi
                        fi
		fi
		counter=$((counter+1))
	done
}

function RewriteSections {
        local config_file="${1}"

	# Earlier config files has GENERAL BACKUP OPTIONS set twice. Let's replace the first one only. sed does a horrible job doing this, at least if portability is required
	awk '/###### GENERAL BACKUP OPTIONS/ && !done { gsub(/###### GENERAL BACKUP OPTIONS/, "[GENERAL]"); done=1}; 1' "$config_file" >> "$config_file.tmp"
        #sed -i'.tmp' 's/###### GENERAL BACKUP OPTIONS/[GENERAL]/' "$config_file"
	# Fix using earlier tmp file from awk
        sed 's/###### BACKUP STORAGE/[BACKUP STORAGE]/g' "$config_file.tmp" > "$config_file"
        sed -i'.tmp' 's/###### REMOTE ONLY OPTIONS/[REMOTE_OPTIONS]/g' "$config_file"
        sed -i'.tmp' 's/###### DATABASE SPECIFIC OPTIONS/[DATABASE BACKUP SETTINGS]/g' "$config_file"
        sed -i'.tmp' 's/###### FILES SPECIFIC OPTIONS/[FILE BACKUP SETTINGS]/g' "$config_file"
        sed -i'.tmp' 's/###### ALERT OPTIONS/[ALERT_OPTIONS]/g' "$config_file"
        sed -i'.tmp' 's/###### GENERAL BACKUP OPTIONS/[BACKUP SETTINGS]/g' "$config_file"
        sed -i'.tmp' 's/###### EXECUTION HOOKS/[EXECUTION_HOOKS]/g' "$config_file"
}

function UpdateConfigHeader {
	local config_file="${1}"

	if ! grep "^CONFIG_FILE_REVISION=" > /dev/null "$config_file"; then
		if grep "\[GENERAL\]" > /dev/null "$config_file"; then
			sed -i'.tmp' '/^\[GENERAL\]$/a\'$'\n'CONFIG_FILE_REVISION=$CONFIG_FILE_REVISION$'\n''' "$config_file"
		else
			sed -i'.tmp' '/.*onfig file rev.*/a\'$'\n'CONFIG_FILE_REVISION=$CONFIG_FILE_REVISION$'\n''' "$config_file"
		fi
		# "onfig file rev" to deal with earlier variants of the file
		#sed -i'.tmp' 's/.*onfig file rev.*//' "$config_file"

	fi
}

if [ "$1" != "" ] && [ -f "$1" ] && [ -w "$1" ]; then
	CONF_FILE="$1"
	# Make sure there is no ending slash
	CONF_FILE="${CONF_FILE%/}"
	LoadConfigFile "$CONF_FILE"
	CheckAndBackup "$CONF_FILE"
	RewriteSections "$CONF_FILE"
	RewriteOldConfigFiles "$CONF_FILE"
	AddMissingConfigOptions "$CONF_FILE"
	UpdateConfigHeader "$CONF_FILE"
	rm -f "$CONF_FILE.tmp"
else
	Usage
fi
