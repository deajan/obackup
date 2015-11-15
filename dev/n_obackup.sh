#!/usr/bin/env bash

###### Remote push/pull (or local) backup script for files & databases
###### (L) 2013-2015 by Orsiris "Ozy" de Jong (www.netpower.fr)
PROGRAM="obackup"
AUTHOR="(L) 2013-2015 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.0-pre
PROGRAM_BUILD=2015111502
IS_STABLE=no

source "/home/git/common/ofunctions.sh"

## Working directory for partial downloads
PARTIAL_DIR=".obackup_workdir_partial"

# List of runtime created global variables
# $SQL_DISK_SPACE, disk space available on target for sql backups
# $FILE_DISK_SPACE, disk space available on target for file backups
# $SQL_BACKUP_TASKS, list of all databases to backup, space separated
# $SQL_EXCLUDED_TASKS, list of all database to exclude from backup, space separated
# $FILE_BACKUP_TASKS list of directories to backup, found in config file
# $FILE_RECURSIVE_BACKUP_TASKS, list of directories to backup, computed from config file recursive list
# $FILE_RECURSIVE_EXCLUDED_TASKS, list of all directories excluded from recursive list
# $FILE_SIZE_LIST, list of all directories to include in GetDirectoriesSize

CAN_BACKUP_SQL=1
CAN_BACKUP_FILES=1

function TrapStop {
	Logger " /!\ WARNING: Manual exit of backup script. Backups may be in inconsistent state." "WARN"
	exit 1
}

function TrapQuit {
	if [ $ERROR_ALERT -ne 0 ]; then
		SendAlert
		CleanUp
		Logger "Backup script finished with errors." "ERROR"
	elif [ $WARN_ALERT -ne 0 ]; then
		SendAlert
		CleanUp
		Logger "Backup script finished with warnings." "WARN"
	else
		CleanUp
		Logger "Backup script finshed." "NOTICE"
	fi

	KillChilds $$ > /dev/null 2>&1
}

function CheckEnvironment {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start backup." "CRITICAL"
			exit 1
		fi

		if [ "$SQL_BACKUP" != "no" ]; then
			if ! type mysqldump > /dev/null 2>&1 ; then
				Logger "mysqldump not present. Cannot backup SQL." "CRITICAL"
				CAN_BACKUP_SQL=0
			fi
			if ! type mysql > /dev/null 2>&1 ; then
				Logger "mysql not present. Cannot backup SQL." "CRITICAL"
				CAN_BACKUP_SQL=0
			fi
		fi
	fi

	if [ "$FILE_BACKUP" != "no" ]; then
		if [ "$ENCRYPTION" == "yes" ]; then
			if ! type duplicity > /dev/null 2>&1 ; then
				Logger "duplicity not present. Cannot backup encrypted files." "CRITICAL"
				CAN_BACKUP_FILES=0
			fi
		else
			if ! type rsync > /dev/null 2>&1 ; then
				Logger "rsync not present. Cannot backup files." "CRITICAL"
				CAN_BACKUP_FILES=0
			fi
		fi
	fi
}

function CheckCurrentConfig {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SUDO_EXEC SSH_COMPRESSION REMOTE_HOST_PING DATABASES_ALL PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR)
	for i in ${yes_no_vars[@]}; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value defined in config file.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$BACKUP_TYPE" != "local" ] && [ "$BACKUP_TYPE" != "pull" ] && [ "$BACKUP_TYPE" != "push" ]; then
		Logger "Bogus BACKUP_TYPE value in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(BACKUP_SIZE_MINIMUM BANDWIDTH SQL_WARN_MIN_SPACE FILE_WARN_MIN_SPACE SOFT_MAX_EXEC_TIME_DB_TASK HARD_MAX_EXEC_TIME_DB_TASK COMPRESSION_LEVEL SOFT_MAX_EXEC_TIME_FILE_TASK HARD_MAX_EXEC_TIME_FILE_TASK SOFT_MAX_EXEC_TIME_TOTAL HARD_MAX_EXEC_TIME_TOTAL ROTATE_COPIES MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	for i in ${num_vars[@]}; do
		test="if [ $(IsNumeric \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value defined in config file.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	#TODO-v2.1: Add runtime variable tests (RSYNC_ARGS etc)
}

function _ListDatabasesLocal {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        sql_cmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2>&1"
        Logger "cmd: $sql_cmd" "DEBUG"
        eval "$sql_cmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
        if [ $? -eq 0 ]; then
                Logger "Listing databases succeeded." "NOTICE"
        else
                Logger "Listing databases failed." "ERROR"
                if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
                fi
                return 1
        fi

}

function _ListDatabasesRemote {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost
        sql_cmd="$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID\" 2>&1"
        Logger "cmd: $sql_cmd" "DEBUG"
        eval "$sql_cmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
        if [ $? -eq 0 ]; then
                Logger "Listing databases succeeded." "NOTICE"
        else
                Logger "Listing databases failed." "ERROR"
                if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
                fi
                return 1
        fi
}

function ListDatabases {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	local output_file	# Return of subfunction

	if [ $CAN_BACKUP_SQL -ne 1 ]; then
		Logger "Cannot list databases." "ERROR"
		return 1
	fi

	Logger "Listing databases." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		_ListDatabasesLocal
		if [ $? != 0 ]; then
			output_file=""
		else
			output_file="$RUN_DIR/$PROGRAM._ListDatabasesLocal.$SCRIPT_PID"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_ListDatabasesRemote
		if [ $? != 0 ]; then
			output_file=""
		else
			output_file="$RUN_DIR/$PROGRAM._ListDatabasesRemote.$SCRIPT_PID"
		fi
	fi

	if [ -f "$output_file" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		OLD_IFS=$IFS
		IFS=$' \n'
		for line in $(cat "$output_file")
		do
			db_name=$(echo $line | cut -f1)
			db_size=$(echo $line | cut -f2)

			if [ "$DATABASES_ALL" == "yes" ]; then
				db_backup=1
				IFS=$PATH_SEPARATOR_CHAR
				for j in $DATABASES_ALL_EXCLUDE_LIST
				do
					if [ "$db_name" == "$j" ]; then
						db_backup=0
					fi
				done
				IFS=$' \n'
			else
				db_backup=0
				IFS=$PATH_SEPARATOR_CHAR
				for j in $DATABASES_LIST
				do
					if [ "$db_name" == "$j" ]; then
						db_backup=1
					fi
				done
				IFS=$' \n'
			fi

			if [ $db_backup -eq 1 ]; then
				if [ "$SQL_BACKUP_TASKS" != "" ]; then
					SQL_BACKUP_TASKS="$SQL_BACKUP_TASKS $db_name"
				else
				SQL_BACKUP_TASKS="$db_name"
				fi
				TOTAL_DATABASES_SIZE=$((TOTAL_DATABASES_SIZE+$db_size))
			else
				SQL_EXCLUDED_TASKS="$SQL_EXCLUDED_TASKS $db_name"
			fi
		done
		IFS=$OLD_IFS

		Logger "Database backup list: $SQL_BACKUP_TASKS" "DEBUG"
		Logger "Database exclude list: $SQL_EXCLUDED_TASKS" "DEBUG"
	else
		Logger "Will not execute database backup." "ERROR"
		CAN_BACKUP_SQL=0
	fi
}

function _ListRecursiveBackupDirectoriesLocal {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for directory in $RECURSIVE_DIRECTORY_LIST
	do
		cmd="$COMMAND_SUDO $FIND_CMD -L $directory/ -mindepth 1 -maxdepth 1 -type d >> $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID"
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
		if  [ $? != 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			if [ -f $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID ]; then
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID ]; then
				Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
			fi
			retval=1
		else
			retval=0
		fi
	done
	IFS=$OLD_IFS
	return $retval
}

function _ListRecursiveBackupDirectoriesRemote {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for directory in $RECURSIVE_DIRECTORY_LIST
	do
		cmd=$SSH_CMD' "'$COMMAND_SUDO' '$FIND_CMD' -L '$directory'/ -mindepth 1 -maxdepth 1 -type d" >> '$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
		if  [ $? != 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			if [ -f $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID ]; then
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID ]; then
				Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
			fi
			retval=1
		else
			retval=0
		fi
	done
	IFS=$OLD_IFS
	return $retval
}

function ListRecursiveBackupDirectories {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	Logger "Listing directories to backup." "NOTICE"
	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		_ListRecursiveBackupDirectoriesLocal
		if [ $? != 0 ]; then
			output_file=""
		else
			output_file="$RUN_DIR/$PROGRAM._ListRecursiveBackupDirectoriesLocal.$SCRIPT_PID"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_ListRecursiveBackupDirectoriesRemote
		if [ $? != 0 ]; then
			output_file=""
		else
			output_file="$RUN_DIR/$PROGRAM._ListRecursiveBackupDirectoriesRemote.$SCRIPT_PID"
		fi
	fi

	if [ -f "$output_file" ]; then
		OLD_IFS=$IFS
		IFS=$' \n'
		for line in $(cat "$output_file")
		do
			file_exclude=0
			IFS=$PATH_SEPARATOR_CHAR
			for k in $RECURSIVE_EXCLUDE_LIST
			do
				if [ "$k" == "$line" ]; then
					file_exclude=1
				fi
			done
			IFS=$' \n'

			if [ $file_exclude -eq 0 ]; then
				if [ "$FILE_RECURSIVE_BACKUP_TASKS" == "" ]; then
					FILE_RECURSIVE_BACKUP_TASKS="$line"
					FILE_SIZE_LIST="$(EscapeSpaces $line)"
				else
					FILE_RECURSIVE_BACKUP_TASKS="$FILE_RECURSIVE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$line"
					FILE_SIZE_LIST="$FILE_SIZE_LIST $(EscapeSpaces $line)"
				fi
			else
				FILE_RECURSIVE_EXCLUDED_TASKS="$FILE_RECURSIVE_EXCLUDED_TASKS$PATH_SEPARATOR_CHAR$line"
			fi
		done
		IFS=$OLD_IFS
	fi

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for directory in $DIRECTORY_LIST
	do
		FILE_SIZE_LIST="$FILE_SIZE_LIST $(EscapeSpaces $directory)"
		if [ "$FILE_BACKUP_TASKS" == "" ]; then
			FILE_BACKUP_TASKS="$directory"
		else
			FILE_BACKUP_TASKS="$FILE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$directory"
		fi
	done
	IFS=$OLD_IFS
}

function _GetDirectoriesSizeLocal {
	local dir_list="${1}"
        __CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	cmd='echo "'$dir_list'" | xargs '$COMMAND_SUDO' du -cs | tail -n1 | cut -f1 > '$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID
	Logger "cmd: $cmd" "DEBUG"
        eval "$cmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
        if  [ $? != 0 ] || [ -s $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID ]; then
                Logger "Could not get files size for some or all directories." "ERROR"
                if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
                fi
        else
                Logger "File size fetched successfully." "NOTICE"
        fi

	if [ -s "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
                TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)"
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function _GetDirectoriesSizeRemote {
	local dir_list="${1}"
        __CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	# Error output is different from stdout because not all files in list may fail at once
	cmd=$SSH_CMD' "echo '$dir_list' | xargs '$COMMAND_SUDO' du -cs | tail -n1 | cut -f1" > '$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID
	Logger "cmd: $cmd" "DEBUG"
        eval "$cmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
        if  [ $? != 0 ] || [ -s $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID ]; then
                Logger "Could not get files size for some or all directories." "ERROR"
                if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
                fi
        else
                Logger "File size fetched successfully." "NOTICE"
	fi
	if [ -s "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
		TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)"
	else
		TOTAL_FILES_SIZE=-1
        fi
}

function GetDirectoriesSize {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        Logger "Getting files size" "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$FILE_BACKUP" != "no" ]; then
			_GetDirectoriesSizeLocal "$FILE_SIZE_LIST"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$FILE_BACKUP" != "no" ]; then
			_GetDirectoriesSizeRemote "$FILE_SIZE_LIST"
		fi
	fi
}

function _CreateStorageDirsLocal {
	local dir_to_create="${1}"
	        __CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ ! -d "$dir_to_create" ]; then
                $COMMAND_SUDO mkdir -p "$dir_to_create" > $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2>&1
                if [ $? != 0 ]; then
                        Logger "Cannot create directory [$dir_to_create]" "CRITICAL"
			if [ -f $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID ]; then
				Logger "Command output: $(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
			fi
                        return 1
                fi
        fi
}

function _CreateStorageDirsRemote {
	local dir_to_create="${1}"
	        __CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost
        cmd=$SSH_CMD' "if ! [ -d \"'$dir_to_create'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$dir_to_create'\"; fi" > '$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID' 2>&1'
        Logger "cmd: $cmd" "DEBUG"
        eval "$cmd" &
        WaitForTaskCompletion $! 720 1800 $FUNCNAME
        if [ $? != 0 ]; then
                Logger "Cannot create remote directory [$dir_to_create]." "CRITICAL"
                Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
                return 1
        fi
}

function CreateStorageDirectories {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "SQL_BACKUP" != "no" ]; then
			_CreateStorageDirsLocal "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=0
			fi
		fi
		if [ "FILE_BACKUP" != "no" ]; then
			_CreateStorageDirsLocal "$FILE_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=0
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "SQL_BACKUP" != "no" ]; then
			_CreateStorageDirsRemote "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=0
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateStorageDirsRemote "$FILE_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=0
			fi
		fi
	fi
}

function GetDiskSpaceLocal {
	# GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	# GLOBAL VARIABLE DRIVE to pass variable to parent function
	local path_to_check="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        if [ -w "$path_to_check" ]; then
		# Not elegant solution to make df silent on errors
		$COMMAND_SUDO df -P "$path_to_check" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1
        	if [ $? != 0 ]; then
        		DISK_SPACE=0
			Logger "Cannot get disk space in [$path_to_check] on local system." "ERROR"
			Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
        	else
                	DISK_SPACE=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID | tail -1 | awk '{print $4}')
                	DRIVE=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID | tail -1 | awk '{print $1}')
        	fi
        else
                Logger "Storage path [$path_to_check] does not exist or cannot write to it." "CRITICAL"
		return 1
	fi
}

function GetDiskSpaceRemote {
	# USE GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	local path_to_check="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	cmd=$SSH_CMD' "if [ -w \"'$path_to_check'\" ]; then '$COMMAND_SUDO' df -P \"'$path_to_check'\"; else exit 1; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
        if [ $? != 0 ]; then
        	DISK_SPACE=0
		Logger "Cannot get disk space in [$path_to_check] on remote system." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
		return 1
        else
               	DISK_SPACE=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID | tail -1 | awk '{print $4}')
               	DRIVE=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID | tail -1 | awk '{print $1}')
        fi
}

function CheckDiskSpace {
	# USE OF GLOBAL VARIABLES TOTAL_DATABASES_SIZE, TOTAL_FILES_SIZE, BACKUP_SIZE_MINIMUM, STORAGE_WARN_SIZE, STORAGE_SPACE

        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$SQL_STORAGE"
			if [ $? != 0 ]; then
				SQL_DISK_SPACE=0
				CAN_BACKUP_SQL=0
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$FILE_STORAGE"
			if [ $? != 0 ]; then
				FILE_DISK_SPACE=0
				CAN_BACKUP_FILES=0
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			GetDiskSpaceRemote "$SQL_STORAGE"
			if [ $? != 0 ]; then
				SQL_DISK_SPACE=0
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			GetDiskSpaceRemote "$FILE_STORAGE"
			if [ $? != 0 ]; then
				FILE_DISK_SPACE=0
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
	fi

	if [ "$TOTAL_DATABASES_SIZE" == "" ]; then
		TOTAL_DATABASES_SIZE=-1
	fi
	if [ "$TOTAL_FILES_SIZE" == "" ]; then
		TOTAL_FILES_SIZE=-1
	fi

	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		if [ $SQL_DISK_SPACE -eq 0 ]; then
			Logger "Storage space in [$SQL_STORAGE] reported to be 0Ko." "WARN"
		fi
		if [ $SQL_DISK_SPACE -lt $TOTAL_DATABASES_SIZE ]; then
        	        Logger "Disk space in [$SQL_STORAGE] may be insufficient to backup SQL ($SQL_DISK_SPACE Ko available in $SQL_DRIVE) (non compressed databases calculation)." "WARN"
		fi
		if [ $SQL_DISK_SPACE -lt $SQL_WARN_MIN_SPACE ]; then
			Logger "Disk space in [$SQL_STORAGE] is lower than warning value [$SQL_WARN_MIN_SPACE Ko]." "WARN"
		fi
		Logger "SQL storage Space: $SQL_DISK_SPACE Ko - Databases size: $TOTAL_DATABASES_SIZE Ko" "NOTICE"
	fi

	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES -eq 1 ]; then
		if [ $FILE_DISK_SPACE -eq 0 ]; then
			Logger "Storage space in [$FILE_STORAGE] reported to be 0 Ko." "WARN"
		fi
		if [ $FILE_DISK_SPACE -lt $TOTAL_FILES_SIZE ]; then
			Logger "Disk space in [$FILE_STORAGE] may be insufficient to backup files ($FILE_DISK_SPACE Ko available in $FILE_DRIVE)." "WARN"
		fi
		if [ $FILE_DISK_SPACE -lt $FILE_WARN_MIN_SPACE ]; then
			Logger "Disk space in [$FILE_STORAGE] is lower than warning value [$FILE_WARN_MIN_SPACE Ko]." "WARN"
		fi
		Logger "File storage space: $FILE_DISK_SPACE Ko - Files size: $TOTAL_FILES_SIZE Ko" "NOTICE"
	fi

	if [ $BACKUP_SIZE_MINIMUM -gt $(($TOTAL_DATABASES_SIZE+$TOTAL_FILES_SIZE)) ] && [ "$GET_BACKUP_SIZE" != "no" ]; then
		Logger "Backup size is smaller than expected." "WARN"
	fi
}

function _BackupDatabaseLocalToLocal {
	local database="${1}" # Database to backup
	local export_options="${2}" # export options

        __CheckArguments 2 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	local dry_sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > /dev/null 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID"
	local sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > $SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID"

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
	local retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
        fi
	return $retval
}

function _BackupDatabaseLocalToRemote {
	local database="${1}" # Database to backup
	local export_options="${2}" # export options

        __CheckArguments 2 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost

	#TODO-v2.0: cannot catch mysqldump warnings
	local dry_sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > /dev/null 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID"
	local sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS | $SSH_CMD '$COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION\" > /dev/null' 2> $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID"

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
	local retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
        fi
	return $retval
}

function _BackupDatabaseRemoteToLocal {
	local database="${1}" # Database to backup
	local export_options="${2}" # export options

        __CheckArguments 2 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost

	local dry_sql_cmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$export_options' --database '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID'"'
	local sql_cmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$export_options' --database '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION'" 2> "'$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID'"'

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
	local retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.error.$SCRIPT_PID)" "ERROR"
        fi
	return $retval
}

function BackupDatabase {
	local database="${1}"
        __CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	# Hack to prevent warning on table mysql.events, some mysql versions don't support --skip-events, prefer using --ignore-table
	if [ "$database" == "mysql" ]; then
		local mysql_options='--skip-lock-tables --single-transaction --ignore-table=mysql.event'
	else
		local mysql_options='--skip-lock-tables --single-transaction'
	fi

	if [ "$BACKUP_TYPE" == "local" ]; then
		_BackupDatabaseLocalToLocal "$database" "$mysql_options"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_BackupDatabaseRemoteToLocal "$database" "$mysql_options"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_BackupDatabaseLocalToRemote "$database" "$mysql_options"
	fi

	if [ $? -ne 0 ]; then
		Logger "Backup failed." "ERROR"
	else
		Logger "Backup succeeded." "NOTICE"
	fi
}

function BackupDatabases {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	local database

	OLD_IFS=$IFS
	IFS=$' \t\n'
	for database in $SQL_BACKUP_TASKS
	do
		Logger "Backing up database [$database]." "NOTICE"
		BackupDatabase $database &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $FUNCNAME
		CheckTotalExecutionTime
	done
	IFS=$OLD_IFS
}

function Rsync {
	local backup_directory="${1}"	# Which directory to backup
	local is_recursive="${2}"	# Backup only files at toplevel of directory

        __CheckArguments 2 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$KEEP_ABSOLUTE_PATHS" == "yes" ]; then
		local file_storage_path="$(dirname $FILE_STORAGE$backup_directory)"
	else
		local file_storage_path="$FILE_STORAGE"
	fi

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
	if [ "$is_recursive" == "no-recurse" ]; then
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion, and excludes subdirectories
		RSYNC_NO_RECURSE_ARGS=" -k  --exclude=*/*/"
	else
		RSYNC_NO_RECURSE_ARGS=""
	fi

	# Creating subdirectories because rsync cannot handle mkdir -p
	if [ ! -d "$file_storage_path/$backup_directory" ]; then
		$COMMAND_SUDO mkdir -p "$file_storage_path/$backup_directory"
		if [ $? != 0 ]; then
			Logger "Cannot create storage path [$file_storage_path/$backup_directory]." "ERROR"
		fi
	fi

	if [ "$BACKUP_TYPE" == "local" ]; then
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$backup_directory\" \"$file_storage_path\" > $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$backup_directory\" \"$file_storage_path\" > $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$backup_directory\" \"$REMOTE_USER@$REMOTE_HOST:$file_storage_path\" > $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID 2>&1"
	fi

	Logger "cmd: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Failed to backup [$backup_directory] to [$file_storage_path]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi
}

function Duplicity {
	local backup_directory="${1}"	# Which directory to backup
	local is_recursive="${2}"	# Backup only files at toplevel of directory

        __CheckArguments 2 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	Logger "Encrpytion not supported yet ! No backup done." "CRITICAL"
	return 1

	if [ "$KEEP_ABSOLUTE_PATHS" == "yes" ]; then
		local file_storage_path="$(dirname $FILE_STORAGE$backup_directory)"
	else
		local file_storage_path="$FILE_STORAGE"
	fi

	if [ "$BACKUP_TYPE" == "local" ]; then
		duplicity_cmd=""
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		duplicity_cmd=""
	elif [ "$BACKUP_TYPE" == "push" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		duplicity_cmd=""
	fi

	Logger "cmd: $duplicity_cmd" "DEBUG"
	eval "$duplicity_cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Failed to backup [$backup_directory] to [$file_storage_path]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi

}

function FilesBackup {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	# Backup non recursive directories
	for BACKUP_TASK in $FILE_BACKUP_TASKS
	do
		Logger "Beginning file backup of [$BACKUP_TASK]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ]; then
			Duplicity "$BACKUP_TASK" "recurse"
		else
			Rsync "$BACKUP_TASK" "recurse"
		fi
		CheckTotalExecutionTime
	done

	## Backup files at root of DIRECTORIES_RECURSE_LIST directories
	for BACKUP_TASK in $RECURSIVE_DIRECTORY_LIST
	do
		Logger "Beginning non recursive file backup of [$BACKUP_TASK]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ]; then
			Duplicity "$BACKUP_TASK" "no-recurse"
		else
			Rsync "$BACKUP_TASK" "no-recurse"
		fi
		CheckTotalExecutionTime
	done

	# Backup sub directories of recursive directories
	for BACKUP_TASK in $FILE_RECURSIVE_BACKUP_TASKS
	do
		Logger "Beginning recursive file backup of [$BACKUP_TASK]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ]; then
			Duplicity "$BACKUP_TASK" "recurse"
		else
			Rsync "$BACKUP_TASK" "recurse"
		fi
		CheckTotalExecutionTime
	done
	IFS=$OLD_IFS
}

function CheckTotalExecutionTime {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	#### Check if max execution time of whole script as been reached
	if [ $SECONDS -gt $SOFT_MAX_EXEC_TIME_TOTAL ]; then
		Logger "Max soft execution time of the whole backup exceeded while backing up [$BACKUP_TASK]." "ERROR"
		WARN_ALERT=1
		SendAlert
		if [ $SECONDS -gt $HARD_MAX_EXEC_TIME_TOTAL ] && [ $HARD_MAX_EXEC_TIME_TOTAL -ne 0 ]; then
			Logger "Max hard execution time of the whole backup exceeded while backing up [$BACKUP_TASK], stopping backup process." "CRITICAL"
			exit 1
		fi
	fi
}

function RsyncExcludePattern {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$RSYNC_EXCLUDE_PATTERN"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str=${rest%%;*}
		# Handle the last case
		if [ "$rest" = "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest=${rest#*$PATH_SEPARATOR_CHAR}
		fi

		if [ "$RSYNC_EXCLUDE" == "" ]; then
			RSYNC_EXCLUDE="--exclude=\"$str\""
		else
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$str\""
		fi
	done
	set +f
}

function RsyncExcludeFrom {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ ! $RSYNC_EXCLUDE_FROM == "" ]; then
		## Check if the exclude list has a full path, and if not, add the config file path if there is one
		if [ "$(basename $RSYNC_EXCLUDE_FROM)" == "$RSYNC_EXCLUDE_FROM" ]; then
			RSYNC_EXCLUDE_FROM=$(dirname $ConfigFile)/$RSYNC_EXCLUDE_FROM
		fi

		if [ -e $RSYNC_EXCLUDE_FROM ]; then
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude-from=\"$RSYNC_EXCLUDE_FROM\""
		fi
	fi
}

function _RotateBackupsLocal {
	local backup_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	OLD_IFS=$IFS
	IFS=$'\t\n'
	for backup in $(ls -I "*.$PROGRAM.*" "$backup_path")
	do
		copy=$ROTATE_COPIES
		while [ $copy -gt 1 ]
		do
			if [ $copy -eq $ROTATE_COPIES ]; then
				cmd="$COMMAND_SUDO rm -rf \"$backup_path/$backup.$PROGRAM.$copy\""
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 720 0 $FUNCNAME
				if [ $? != 0 ]; then
					Logger "Cannot delete oldest copy [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi
			fi
			path="$backup_path/$backup.$PROGRAM.$(($copy-1))"
			if [[ -f $path || -d $path ]]; then
				cmd="$COMMAND_SUDO mv \"$path\" \"$backup_path/$backup.$PROGRAM.$copy\""
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 720 0 $FUNCNAME
				if [ $? != 0 ]; then
					Logger "Cannot move [$path] to [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="$COMMAND_SUDO mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 720 0 $FUNCNAME
			if [ $? != 0 ]; then
				Logger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="$COMMAND_SUDO cp -R \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 720 0 $FUNCNAME
			if [ $? != 0 ]; then
				Logger "Cannot copy [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		else
			cmd="$COMMAND_SUDO mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 720 0 $FUNCNAME
			if [ $? != 0 ]; then
 				Logger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi
		fi
	done
	IFS=$OLD_IFS
}

function _RotateBackupsRemote {
	local backup_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG
$SSH_CMD PROGRAM=$PROGRAM REMOTE_OPERATION=$REMOTE_OPERATION _DEBUG=$_DEBUG COMMAND_SUDO=$COMMAND_SUDO ROTATE_COPIES=$ROTATE_COPIES backup_path="$backup_path" 'bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1 &

function _RemoteLogger {
        local value="${1}" # What to log
        echo -e "$value"
}

function RemoteLogger {
        local value="${1}" # Sentence to log (in double quotes)
        local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, NOTICE, WARN, ERROR, CRITIAL

	prefix="REMOTE TIME: $SECONDS - "

        if [ "$level" == "CRITICAL" ]; then
                _RemoteLogger "$prefix\e[41m$value\e[0m"
                return
        elif [ "$level" == "ERROR" ]; then
                _RemoteLogger "$prefix\e[91m$value\e[0m"
                return
        elif [ "$level" == "WARN" ]; then
                _RemoteLogger "$prefix\e[93m$value\e[0m"
                return
        elif [ "$level" == "NOTICE" ]; then
                _RemoteLogger "$prefix$value"
                return
        elif [ "$level" == "DEBUG" ]; then
                if [ "$_DEBUG" == "yes" ]; then
                        _RemoteLogger "$prefix$value"
                        return
                fi
        elif [ "$level" == "PARANOIA_DEBUG" ]; then             	#__WITH_PARANOIA_DEBUG
                if [ "$_PARANOIA_DEBUG" == "yes" ]; then        	#__WITH_PARANOIA_DEBUG
                        _RemoteLogger "$prefix$value"                 	#__WITH_PARANOIA_DEBUG
                        return                                  	#__WITH_PARANOIA_DEBUG
                fi                                              	#__WITH_PARANOIA_DEBUG
        else
                _RemoteLogger "\e[41mLogger function called without proper loglevel.\e[0m"
                _RemoteLogger "$prefix$value"
        fi
}

function _RotateBackupsRemoteSSH {
	OLD_IFS=$IFS
	IFS=$'\t\n'
	for backup in $(ls -I "*.$PROGRAM.*" "$backup_path")
	do
		copy=$ROTATE_COPIES
		while [ $copy -gt 1 ]
		do
			if [ $copy -eq $ROTATE_COPIES ]; then
				cmd="$COMMAND_SUDO rm -rf \"$backup_path/$backup.$PROGRAM.$copy\""
				RemoteLogger "cmd: $cmd" "DEBUG"
				eval "$cmd"
				if [ $? != 0 ]; then
					RemoteLogger "Cannot delete oldest copy [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi
			fi
			path="$backup_path/$backup.$PROGRAM.$(($copy-1))"
			if [[ -f $path || -d $path ]]; then
				cmd="$COMMAND_SUDO mv \"$path\" \"$backup_path/$backup.$PROGRAM.$copy\""
				RemoteLogger "cmd: $cmd" "DEBUG"
				eval "$cmd"
				if [ $? != 0 ]; then
					RemoteLogger "Cannot move [$path] to [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="$COMMAND_SUDO mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
				RemoteLogger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="$COMMAND_SUDO cp -R \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
				RemoteLogger "Cannot copy [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		else
			cmd="$COMMAND_SUDO mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
 				RemoteLogger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi
		fi
	done
	IFS=$OLD_IFS
}

	_RotateBackupsRemoteSSH

ENDSSH

	WaitForTaskCompletion $! 1800 0 $FUNCNAME
        if [ $? != 0 ]; then
                Logger "Could not rotate backups in [$backup_path]." "ERROR"
                Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
        else
                Logger "Remote rotation succeed." "NOTICE"
        fi        ## Need to add a trivial sleep time to give ssh time to log to local file
        #sleep 5


}

function RotateBackups {
	local backup_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	Logger "Rotating backups." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		_RotateBackupsLocal "$backup_path"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_RotateBackupsRemote "$backup_path"
	fi
}

function Init {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	trap TrapStop SIGINT SIGQUIT SIGKILL SIGTERM SIGHUP
	trap TrapQuit EXIT

	## Test if target dir is a ssh uri, and if yes, break it down it its values
        if [ "${REMOTE_SYSTEM_URI:0:6}" == "ssh://" ] && [ "$BACKUP_TYPE" != "local" ]; then
                REMOTE_OPERATION="yes"

                # remove leadng 'ssh://'
                uri=${REMOTE_SYSTEM_URI#ssh://*}
                if [[ "$uri" == *"@"* ]]; then
                        # remove everything after '@'
                        REMOTE_USER=${uri%@*}
                else
                        REMOTE_USER=$LOCAL_USER
                fi

                if [ "$SSH_RSA_PRIVATE_KEY" == "" ]; then
                        SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
                fi

                # remove everything before '@'
                _hosturiandpath=${uri#*@}
                # remove everything after first '/'
                _hosturi=${_hosturiandpath%%/*}
                if [[ "$_hosturi" == *":"* ]]; then
                        REMOTE_PORT=${_hosturi##*:}
                else
                        REMOTE_PORT=22
                fi
                REMOTE_HOST=${_hosturi%%:*}
	fi

	## Add update to default RSYNC_ARGS
	RSYNC_ARGS=$RSYNC_ARGS"u"

	if [ $_VERBOSE -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS"i"
	fi

	if [ "$PARTIAL" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
		RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$PARTIAL_DIR\""
	fi

	if [ "$DELETE_VANISHED_FILES" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --delete"
	fi

	if [ "$DELTA_COPIES" != "no" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --no-whole-file"
	else
		RSYNC_ARGS=$RSYNC_ARGS" --whole-file"
	fi

	if [ $stats -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --stats"
	fi

	## Fix for symlink to directories on target cannot get updated
	RSYNC_ARGS=$RSYNC_ARGS" --force"
}

function Main {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		ListDatabases
	fi
	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES -eq 1 ]; then
		ListRecursiveBackupDirectories
		if [ "$GET_BACKUP_SIZE" != "no" ]; then
			GetDirectoriesSize
		else
			TOTAL_FILE_SIZE=0
		fi
	fi

	if [ "$CREATE_DIRS" != "no" ]; then
		CreateStorageDirectories
	fi
	CheckDiskSpace

	# Actual backup process
	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		if [ $_DRYRUN -ne 1 ] && [ "$ROTATE_SQL_BACKUPS" == "yes" ]; then
			RotateBackups "$SQL_STORAGE"
		fi
		BackupDatabases
	fi

	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES -eq 1 ]; then
		if [ $_DRYRUN -ne 1 ] && [ "$ROTATE_FILE_BACKUPS" == "yes" ]; then
			RotateBackups "$FILE_STORAGE"
		fi
		## Add Rsync exclude patterns
		RsyncExcludePattern
		## Add Rsync exclude from file
		RsyncExcludeFrom
		FilesBackup
	fi
}

function Usage {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG


	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "usage: obackup.sh /path/to/backup.conf [OPTIONS]"
	echo ""
	echo "OPTIONS:"
	echo "--dry: will run obackup without actually doing anything, just testing"
	echo "--silent: will run obackup without any output to stdout, usefull for cron backups"
	echo "--verbose: adds command outputs"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      disables any soft and hard execution time checks"
	echo "--delete          Deletes files on destination that vanished on source"
	echo "--dontgetsize     Does not try to evaluate backup size"
	exit 128
}

# Command line argument flags
_DRYRUN=0
_SILENT=0
no_maxtime=0
dontgetsize=0
stats=0
PARTIAL=0

function GetCommandlineArguments {
	if [ $# -eq 0 ]; then
		Usage
	fi

	for i in "$@"
	do
		case $i in
			--dry)
			_DRYRUN=1
			;;
			--silent)
			_SILENT=1
			;;
			--verbose)
			_VERBOSE=1
			;;
			--stats)
			stats=1
			;;
			--partial)
			PARTIAL="yes"
			;;
			--no-maxtime)
			no_maxtime=1
			;;
			--delete)
			DELETE_VANISHED_FILES="yes"
			;;
			--dontgetsize)
			GET_BACKUP_SIZE="no"
			;;
			--help|-h|--version|-v)
			Usage
			;;
		esac
	done
}

GetCommandlineArguments "$@"
CheckEnvironment
LoadConfigFile "$1"
if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE=/var/log/$PROGRAM.$INSTANCE_ID.log
	else
		LOG_FILE=./$PROGRAM.$INSTANCE_ID.log
	fi
else
	LOG_FILE="$LOGFILE"
fi

if [ "$IS_STABLE" != "yes" ]; then
	Logger "This is an unstable dev build. Please use with caution." "WARN"
fi


GetLocalOS
InitLocalOSSettings
PreInit
Init
PostInit
CheckCurrentConfig
if [ "$REMOTE_OPERATION" == "yes" ]; then
	GetRemoteOS
	InitRemoteOSSettings
fi
DATE=$(date)
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING $DATE - $PROGRAM v$PROGRAM_VERSION $BACKUP_TYPE script begin." "NOTICE"
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "Backup instance [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

if [ $no_maxtime -eq 1 ]; then
	SOFT_MAX_EXEC_TIME_DB_TASK=0
	SOFT_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_DB_TASK=0
	HARD_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_TOTAL=0
fi

RunBeforeHook
Main
RunAfterHook
