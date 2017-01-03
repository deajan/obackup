#!/usr/bin/env bash

#TODO: do we rotate encrypted files too or only temp files in storage dir (pull / local question)

###### Remote push/pull (or local) backup script for files & databases
PROGRAM="obackup"
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.1-dev
PROGRAM_BUILD=2017010304
IS_STABLE=no

# Execution order					#__WITH_PARANOIA_DEBUG

# GetLocalOS						#__WITH_PARANOIA_DEBUG
# InitLocalOSDependingSettings				#__WITH_PARANOIA_DEBUG
# CheckRunningInstances					#__WITH_PARANOIA_DEBUG
# PreInit						#__WITH_PARANOIA_DEBUG
# Init							#__WITH_PARANOIA_DEBUG
# CheckEnvironment					#__WITH_PARANOIA_DEBUG
# Postinit						#__WITH_PARANOIA_DEBUG
# CheckCurrentConfig					#__WITH_PARANOIA_DEBUG
# GetRemoteOS						#__WITH_PARANOIA_DEBUG
# InitRemoteOSDependingSettings				#__WITH_PARANOIA_DEBUG
# RunBeforeHook						#__WITH_PARANOIA_DEBUG
# Main							#__WITH_PARANOIA_DEBUG
#	ListDatabases					#__WITH_PARANOIA_DEBUG
#	ListRecursiveBackupDirectories			#__WITH_PARANOIA_DEBUG
#	GetDirectoriesSize				#__WITH_PARANOIA_DEBUG
#	CreateSrorageDirectories			#__WITH_PARANOIA_DEBUG
#	CheckDiskSpace					#__WITH_PARANOIA_DEBUG
#	RotateBackups					#__WITH_PARANOIA_DEBUG
#	BackupDatabases					#__WITH_PARANOIA_DEBUG
#	RotateBackups					#__WITH_PARANOIA_DEBUG
#	RsyncPatterns					#__WITH_PARANOIA_DEBUG
#	FilesBackup					#__WITH_PARANOIA_DEBUG


include #### OFUNCTIONS FULL SUBSET ####

# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap
include #### _OFUNCTIONS_BOOTSTRAP SUBSET ####
[ "$_OFUNCTIONS_BOOTSTRAP" != true ] && echo "Please use bootstrap.sh to load this dev version of $(basename $0)" && exit 1


_LOGGER_PREFIX="time"

## Working directory for partial downloads
PARTIAL_DIR=".obackup_workdir_partial"

## File extension for encrypted files
CRYPT_FILE_EXTENSION=".$PROGRAM.gpg"

# List of runtime created global variables
# $SQL_DISK_SPACE, disk space available on target for sql backups
# $FILE_DISK_SPACE, disk space available on target for file backups
# $SQL_BACKUP_TASKS, list of all databases to backup, space separated
# $SQL_EXCLUDED_TASKS, list of all database to exclude from backup, space separated
# $FILE_BACKUP_TASKS list of directories to backup, found in config file
# $FILE_RECURSIVE_BACKUP_TASKS, list of directories to backup, computed from config file recursive list
# $FILE_RECURSIVE_EXCLUDED_TASKS, list of all directories excluded from recursive list
# $FILE_SIZE_LIST, list of all directories to include in GetDirectoriesSize, enclosed by escaped doublequotes

# Assume that anything can be backed up unless proven otherwise
CAN_BACKUP_SQL=true
CAN_BACKUP_FILES=true

function TrapStop {
	Logger "/!\ Manual exit of backup script. Backups may be in inconsistent state." "WARN"
	exit 2
}

function TrapQuit {
	local exitcode

        # Get ERROR / WARN alert flags from subprocesses that call Logger
        if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
                WARN_ALERT=true
        fi
        if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
                ERROR_ALERT=true
        fi

	if [ $ERROR_ALERT == true ]; then
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with errors." "ERROR"
		SendAlert
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with warnings." "WARN"
		SendAlert
		exitcode=2
	else
		RunAfterHook
		Logger "$PROGRAM finshed." "ALWAYS"
		exitcode=0
	fi

	if [ -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID" ]; then
		rm -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID"
	fi

	CleanUp
	KillChilds $$ > /dev/null 2>&1
	exit $exitcode
}

function CheckEnvironment {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start backup." "CRITICAL"
			exit 1
		fi

		if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
                        Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
                        exit 1
                fi
	else
		if [ "$SQL_BACKUP" != "no" ]; then
			if ! type mysqldump > /dev/null 2>&1 ; then
				Logger "mysqldump not present. Cannot backup SQL." "CRITICAL"
				CAN_BACKUP_SQL=false
			fi
			if ! type mysql > /dev/null 2>&1 ; then
				Logger "mysql not present. Cannot backup SQL." "CRITICAL"
				CAN_BACKUP_SQL=false
			fi
		fi
	fi

	if [ "$FILE_BACKUP" != "no" ]; then
		if ! type rsync > /dev/null 2>&1 ; then
			Logger "rsync not present. Cannot backup files." "CRITICAL"
			CAN_BACKUP_FILES=false
		fi
	fi

	if [ "$ENCRYPTION" == "yes" ]; then
		CheckCryptEnvironnment
	fi
}

function CheckCryptEnvironnment {
	if ! type gpg2 > /dev/null 2>&1 ; then
		if ! type gpg > /dev/null 2>&1; then
			Logger "Programs gpg2 nor gpg not present. Cannot encrypt backup files." "CRITICAL"
			CAN_BACKUP_FILES=false
		else
			Logger "Program gpg2 not present, falling back to gpg." "NOTICE"
			CRYPT_TOOL=gpg
		fi
	else
		CRYPT_TOOL=gpg2
	fi
}

function CheckCurrentConfig {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SUDO_EXEC DATABASES_ALL PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
	for i in "${yes_no_vars[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$BACKUP_TYPE" != "local" ] && [ "$BACKUP_TYPE" != "pull" ] && [ "$BACKUP_TYPE" != "push" ]; then
		Logger "Bogus BACKUP_TYPE value in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(BACKUP_SIZE_MINIMUM SQL_WARN_MIN_SPACE FILE_WARN_MIN_SPACE SOFT_MAX_EXEC_TIME_DB_TASK HARD_MAX_EXEC_TIME_DB_TASK COMPRESSION_LEVEL SOFT_MAX_EXEC_TIME_FILE_TASK HARD_MAX_EXEC_TIME_FILE_TASK BANDWIDTH SOFT_MAX_EXEC_TIME_TOTAL HARD_MAX_EXEC_TIME_TOTAL ROTATE_SQL_COPIES ROTATE_FILE_COPIES KEEP_LOGGING MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$FILE_BACKUP" == "yes" ]; then
		if [ "$DIRECTORY_LIST" == "" ] && [ "$RECURSIVE_DIRECTORY_LIST" == "" ]; then
			Logger "No directories specified in config file, no files to backup." "ERROR"
			CAN_BACKUP_FILES=false
		fi
	fi

	if [ "$REMOTE_OPERATION" == "yes" ] && [ ! -f "$SSH_RSA_PRIVATE_KEY" ]; then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY]. Cannot connect to remote system." "CRITICAL"
		exit 1
	fi

	#WIP: Encryption use key file instead of recipient ?
	#if [ ! -f "$ENCRYPT_GPG_PYUBKEY" ]; then
	#	Logger "Cannot find gpg pubkey [$ENCRYPT_GPG_PUBKEY]. Cannot encrypt backup files." "CRITICAL"
	#	exit 1
	#fi

	if [ "$SQL_BACKUP" == "yes" ] && [ "$SQL_STORAGE" == "" ]; then
		Logger "SQL_STORAGE not defined." "CRITICAL"
		exit 1
	fi

	if [ "$FILE_BACKUP" == "yes" ] && [ "$FILE_STORAGE" == "" ]; then
		Logger "FILE_STORAGE not defined." "CRITICAL"
		exit 1
	fi

	if [ "$ENCRYPTION" == "yes" ]; then
		if [ "$CRYPT_STORAGE" == "" ]; then
			Logger "CRYPT_STORAGE not defined." "CRITICAL"
			exit 1
		fi
		if [ "$GPG_RECIPIENT" == "" ]; then
			Logger "No GPG recipient defined." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$REMOTE_OPERATION" == "yes" ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
                Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
                exit 1
        fi
}

function CheckRunningInstances {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID" ]; then
		pid=$(cat "$RUN_DIR/$PROGRAM.$INSTANCE_ID")
		if ps aux | awk '{print $2}' | grep $pid > /dev/null; then
			Logger "Another instance [$INSTANCE_ID] of obackup is already running." "CRITICAL"
			exit 1
		fi
	fi

	echo $SCRIPT_PID > "$RUN_DIR/$PROGRAM.$INSTANCE_ID"
}

function _ListDatabasesLocal {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local retval
	local sqlCmd

        sqlCmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
        Logger "Launching command [$sqlCmd]." "DEBUG"
        eval "$sqlCmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
        if [ $retval -eq 0 ]; then
                Logger "Listing databases succeeded." "NOTICE"
        else
                Logger "Listing databases failed." "ERROR"
	        Logger "Command was [$sqlCmd]." "WARN"
                if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
                fi
                return 1
        fi

}

function _ListDatabasesRemote {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local sqlCmd
	local retval

        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost
        sqlCmd="$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
        Logger "Command output: $sqlCmd" "DEBUG"
        eval "$sqlCmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
        if [ $retval -eq 0 ]; then
                Logger "Listing databases succeeded." "NOTICE"
        else
                Logger "Listing databases failed." "ERROR"
	        Logger "Command output: $sqlCmd" "WARN"
                if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
                fi
                return $retval
        fi
}

function ListDatabases {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local outputFile	# Return of subfunction
	local dbName
	local dbSize
	local dbBackup
	local missingDatabases=false

	local dbArray

	if [ $CAN_BACKUP_SQL == false ]; then
		Logger "Cannot list databases." "ERROR"
		return 1
	fi

	Logger "Listing databases." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		_ListDatabasesLocal
		if [ $? -ne 0 ]; then
			outputFile=""
		else
			outputFile="$RUN_DIR/$PROGRAM._ListDatabasesLocal.$SCRIPT_PID.$TSTAMP"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_ListDatabasesRemote
		if [ $? -ne 0 ]; then
			outputFile=""
		else
			outputFile="$RUN_DIR/$PROGRAM._ListDatabasesRemote.$SCRIPT_PID.$TSTAMP"
		fi
	fi

	if [ -f "$outputFile" ] && [ $CAN_BACKUP_SQL == true ]; then
		while read -r line; do
			while read -r name size; do dbName=$name; dbSize=$size; done <<< "$line"

			if [ "$DATABASES_ALL" == "yes" ]; then
				dbBackup=true
				IFS=$PATH_SEPARATOR_CHAR read -r -a dbArray <<< "$DATABASES_ALL_EXCLUDE_LIST"
				for j in "${dbArray[@]}"; do
					if [ "$dbName" == "$j" ]; then
						dbBackup=false
					fi
				done
			else
				dbBackup=false
				IFS=$PATH_SEPARATOR_CHAR read -r -a dbArray <<< "$DATABASES_LIST"
				for j in "${dbArray[@]}"; do
					if [ "$dbName" == "$j" ]; then
						dbBackup=true
					fi
				done
				if [ $dbBackup == false ]; then
					missingDatabases=true
				fi

			fi

			if [ $dbBackup == true ]; then
				if [ "$SQL_BACKUP_TASKS" != "" ]; then
					SQL_BACKUP_TASKS="$SQL_BACKUP_TASKS $dbName"
				else
				SQL_BACKUP_TASKS="$dbName"
				fi
				TOTAL_DATABASES_SIZE=$((TOTAL_DATABASES_SIZE+dbSize))
			else
				SQL_EXCLUDED_TASKS="$SQL_EXCLUDED_TASKS $dbName"
			fi
		done < "$outputFile"

		if [ $missingDatabases == true ]; then
			IFS=$PATH_SEPARATOR_CHAR read -r -a dbArray <<< "$DATABASES_LIST"
			for i in "${dbArray[@]}"; do
				if ! grep "$i" "$outputFile" > /dev/null 2>&1; then
					Logger "Missing database [$i]." "CRITICAL"
				fi
			done
		fi

		Logger "Database backup list: $SQL_BACKUP_TASKS" "DEBUG"
		Logger "Database exclude list: $SQL_EXCLUDED_TASKS" "DEBUG"
	else
		Logger "Will not execute database backup." "ERROR"
		CAN_BACKUP_SQL=false
	fi
}

function _ListRecursiveBackupDirectoriesLocal {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local directories
	local directory
	local retval
	local successfulRun=false
	local failuresPresent=false

	IFS=$PATH_SEPARATOR_CHAR read -r -a directories <<< "$RECURSIVE_DIRECTORY_LIST"
	for directory in "${directories[@]}"; do
		# No sudo here, assuming you should have all necessary rights for local checks
		cmd="$FIND_CMD -L $directory/ -mindepth 1 -maxdepth 1 -type d >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		Logger "Launching command [$cmd]." "DEBUG"
		eval "$cmd"
		retval=$?
		if  [ $retval -ne 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			Logger "Command was [$cmd]." "Warn"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
			fi
			failuresPresent=true
		else
			successfulRun=true
		fi
	done
	if [ $successfulRun == true ] && [ $failuresPresent == true ]; then
		return 2
	elif [ $successfulRun == true ] && [ $failuresPresent == false ]; then
		return 0
	else
		return 1
	fi
}

function _ListRecursiveBackupDirectoriesRemote {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local retval

$SSH_CMD env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env RECURSIVE_DIRECTORY_LIST="'$RECURSIVE_DIRECTORY_LIST'" env PATH_SEPARATOR_CHAR="'$PATH_SEPARATOR_CHAR'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

function _ListRecursiveBackupDirectoriesRemoteSub {
	local directories
	local directory
	local retval
	local successfulRun=false
	local failuresPresent=false
	local cmd

	IFS=$PATH_SEPARATOR_CHAR read -r -a directories <<< "$RECURSIVE_DIRECTORY_LIST"
	for directory in "${directories[@]}"; do
		cmd="$REMOTE_FIND_CMD -L \"$directory\"/ -mindepth 1 -maxdepth 1 -type d"
		eval $cmd
		retval=$?
		if  [ $retval -ne 0 ]; then
			RemoteLogger "Could not enumerate directories in [$directory]." "ERROR"
			RemoteLogger "Command was [$cmd]." "WARN"
			failuresPresent=true
		else
			successfulRun=true
		fi
	done
	if [ $successfulRun == true ] && [ $failuresPresent == true ]; then
		return 2
	elif [ $successfulRun == true ] && [ $failuresPresent == false ]; then
		return 0
	else
		return 1
	fi
}
_ListRecursiveBackupDirectoriesRemoteSub
exit $?
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
	fi
	return $retval
}

function ListRecursiveBackupDirectories {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local output_file
	local file_exclude
	local excluded
	local fileArray

	if [ "$RECURSIVE_DIRECTORY_LIST" != "" ]; then

		# Return values from subfunctions can be 0 (no error), 1 (only errors) or 2 (some errors). Do process output except on 1 return code
		Logger "Listing directories to backup." "NOTICE"
		if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
			_ListRecursiveBackupDirectoriesLocal &
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -eq 1 ]; then
				output_file=""
			else
				output_file="$RUN_DIR/$PROGRAM._ListRecursiveBackupDirectoriesLocal.$SCRIPT_PID.$TSTAMP"
			fi
		elif [ "$BACKUP_TYPE" == "pull" ]; then
			_ListRecursiveBackupDirectoriesRemote &
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -eq 1 ]; then
				output_file=""
			else
				output_file="$RUN_DIR/$PROGRAM._ListRecursiveBackupDirectoriesRemote.$SCRIPT_PID.$TSTAMP"
			fi
		fi

		if [ -f "$output_file" ]; then
			while read -r line; do
				file_exclude=0
				IFS=$PATH_SEPARATOR_CHAR read -r -a fileArray <<< "$RECURSIVE_EXCLUDE_LIST"
				for excluded in "${fileArray[@]}"; do
					if [ "$excluded" == "$line" ]; then
						file_exclude=1
					fi
				done

				if [ $file_exclude -eq 0 ]; then
					if [ "$FILE_RECURSIVE_BACKUP_TASKS" == "" ]; then
						FILE_SIZE_LIST="\"$line\""
						FILE_RECURSIVE_BACKUP_TASKS="$line"
					else
						FILE_SIZE_LIST="$FILE_SIZE_LIST \"$line\""
						FILE_RECURSIVE_BACKUP_TASKS="$FILE_RECURSIVE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$line"
					fi
				else
					FILE_RECURSIVE_EXCLUDED_TASKS="$FILE_RECURSIVE_EXCLUDED_TASKS$PATH_SEPARATOR_CHAR$line"
				fi
			done < "$output_file"
		fi
	fi

	if [ "$DIRECTORY_LIST" != "" ]; then

		IFS=$PATH_SEPARATOR_CHAR read -r -a fileArray <<< "$DIRECTORY_LIST"
		for directory in "${fileArray[@]}"; do
			if [ "$FILE_SIZE_LIST" == "" ]; then
				FILE_SIZE_LIST="\"$directory\""
			else
				FILE_SIZE_LIST="$FILE_SIZE_LIST \"$directory\""
			fi

			if [ "$FILE_BACKUP_TASKS" == "" ]; then
				FILE_BACKUP_TASKS="$directory"
			else
				FILE_BACKUP_TASKS="$FILE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$directory"
			fi
		done
	fi
}

function _GetDirectoriesSizeLocal {
	local dirList="${1}"

        __CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local retval

	# No sudo here, assuming you should have all the necessary rights
	# This is not pretty, but works with all supported systems
	cmd="du -cs $dirList | tail -n1 | cut -f1 > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	Logger "Launching command [$cmd]." "DEBUG"
        eval "$cmd" &
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
	retval=$?
        if  [ $retval -ne  0 ] || [ -s $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
                Logger "Could not get files size for some or all local directories." "ERROR"
		Logger "Command was [$cmd]." "WARN"
                if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
                fi
        elsew
                Logger "File size fetched successfully." "NOTICE"
        fi

	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
                TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)"
		if [ $(IsInteger $TOTAL_FILES_SIZE) -eq 0 ]; then
			TOTAL_FILES_SIZE="$(HumanToNumeric $TOTAL_FILES_SIZE)"
		fi
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function _GetDirectoriesSizeRemote {
	local dirList="${1}"
        __CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local retval

	# Error output is different from stdout because not all files in list may fail at once
$SSH_CMD env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" dirList="'$dirList'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

	cmd="du -cs $dirList | tail -n1 | cut -f1"
        eval "$cmd"
	retval=$?
	if [ $retval != 0 ]; then
		RemoteLogger "Command was [$cmd]." "WARN"
	fi
	exit $retval
ENDSSH
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
        WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
        if  [ $retval -ne 0 ] || [ -s $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
                Logger "Could not get files size for some or all remote directories." "ERROR"
                if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
                        Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
                fi
        else
                Logger "File size fetched successfully." "NOTICE"
	fi
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)"
		if [ $(IsInteger $TOTAL_FILES_SIZE) -eq 0 ]; then
			TOTAL_FILES_SIZE="$(HumanToNumeric $TOTAL_FILES_SIZE)"
		fi
	else
		TOTAL_FILES_SIZE=-1
        fi
}

function GetDirectoriesSize {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

function _CreateDirectoryLocal {
	local dirToCreate="${1}"
	        __CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local retval

	if [ ! -d "$dirToCreate" ]; then
		# No sudo, you should have all necessary rights
                mkdir -p "$dirToCreate" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1 &
	        WaitForTaskCompletion $! 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false
		retval=$?
                if [ $retval -ne 0 ]; then
                        Logger "Cannot create directory [$dirToCreate]" "CRITICAL"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Command output: $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
			fi
                        return $retval
                fi
        fi
}

function _CreateDirectoryRemote {
	local dirToCreate="${1}"
	        __CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local retval

        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost

$SSH_CMD env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env dirToCreate="'$dirToCreate'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

	if [ ! -d "$dirToCreate" ]; then
		# No sudo, you should have all necessary rights
                mkdir -p "$dirToCreate"
		retval=$?
                if [ $retval -ne 0 ]; then
                        RemoteLogger "Cannot create directory [$dirToCreate]" "CRITICAL"
                        exit $retval
                fi
        fi
	exit 0
ENDSSH
        WaitForTaskCompletion $! 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
        if [ $retval -ne 0 ]; then
                Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
                return $retval
        fi
}

function CreateStorageDirectories {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == "yes" ]; then
			_CreateDirectoryLocal "$CRYPT_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == "yes" ]; then
			_CreateDirectoryLocal "$CRYPT_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
	fi
}

function GetDiskSpaceLocal {
	# GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	# GLOBAL VARIABLE DRIVE to pass variable to parent function
	local pathToCheck="${1}"

	__CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local retval

        if [ -d "$pathToCheck" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		$DF_CMD "$pathToCheck" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
        	if [ $retval -ne 0 ]; then
        		DISK_SPACE=0
			Logger "Cannot get disk space in [$pathToCheck] on local system." "ERROR"
			Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
        	else
                	DISK_SPACE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" | awk '{print $4}')
                	DRIVE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" | awk '{print $1}')
			if [ $(IsInteger $DISK_SPACE) -eq 0 ]; then
				DISK_SPACE="$(HumanToNumeric $DISK_SPACE)"
			fi
        	fi
        else
                Logger "Storage path [$pathToCheck] does not exist." "CRITICAL"
		return 1
	fi
}

function GetDiskSpaceRemote {
	# USE GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	local pathToCheck="${1}"

	__CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local retval

$SSH_CMD env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env DF_CMD="'$DF_CMD'" \
env pathToCheck="'$pathToCheck'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

function _GetDiskSpaceRemoteSub {
        if [ -d "$pathToCheck" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		cmd="$DF_CMD \"$pathToCheck\""
		if [ $? != 0 ]; then
			RemoteLogger "Error getting [$pathToCheck] size." "CRITICAL"
			RemoteLogger "Command was [$cmd]." "WARN"
			return 1
		else
			return 0
		fi
        else
                RemoteLogger "Storage path [$pathToCheck] does not exist." "CRITICAL"
		return 1
	fi
}

_GetDiskSpaceRemoteSub
exit $?
ENDSSH
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
        if [ $retval -ne 0 ]; then
        	DISK_SPACE=0
		Logger "Cannot get disk space in [$pathToCheck] on remote system." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		return $retval
        else
               	DISK_SPACE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" | awk '{print $4}')
               	DRIVE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" | awk '{print $1}')
		if [ $(IsInteger $DISK_SPACE) -eq 0 ]; then
			DISK_SPACE="$(HumanToNumeric $DISK_SPACE)"
		fi
        fi
}

function CheckDiskSpace {
	# USE OF GLOBAL VARIABLES TOTAL_DATABASES_SIZE, TOTAL_FILES_SIZE, BACKUP_SIZE_MINIMUM, STORAGE_WARN_SIZE, STORAGE_SPACE

        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				SQL_DISK_SPACE=0
				CAN_BACKUP_SQL=false
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				FILE_DISK_SPACE=0
				CAN_BACKUP_FILES=false
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
		if [ "$ENCRYPTION" != "no" ]; then
			GetDiskSpaceLocal "$CRYPT_STORAGE"
			if [ $? -ne 0 ]; then
				CRYPT_DISK_SPACE=0
				CAN_BACKUP_FILES=false
				CAN_BACKUP_SQL=false
			else
				CRYPT_DISK_SPACE=$DISK_SPACE
				CRYPT_DRIVE=$DRIVE
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			GetDiskSpaceRemote "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				SQL_DISK_SPACE=0
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			GetDiskSpaceRemote "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				FILE_DISK_SPACE=0
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
		if [ "$ENCRYPTION" != "no" ]; then
			GetDiskSpaceLocal "$CRYPT_STORAGE"
			if [ $? -ne 0 ]; then
				CRYPT_DISK_SPACE=0
				CAN_BACKUP_FILES=false
				CAN_BACKUP_SQL=false
			else
				CRYPT_DISK_SPACE=$DISK_SPACE
				CRYPT_DRIVE=$DRIVE
			fi
		fi

	fi

	if [ "$TOTAL_DATABASES_SIZE" == "" ]; then
		TOTAL_DATABASES_SIZE=-1
	fi
	if [ "$TOTAL_FILES_SIZE" == "" ]; then
		TOTAL_FILES_SIZE=-1
	fi

	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL == true ]; then
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

	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES == true ]; then
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

	if [ "$ENCRYPTION" == "yes" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			if [ "$SQL_DRIVE" == "$CRYPT_DRIVE" ]; then
				if [ $((SQL_DISK_SPACE/2)) -lt $((TOTAL_DATABASES_SIZE)) ]; then
					Logger "Disk space in [$SQL_STORAGE] and [$CRYPT_STORAGE] may be insufficient to backup SQL ($SQL_DISK_SPACE Ko available in $SQL_DRIVE) (non compressed databases calculation + crypt storage space)." "WARN"
				fi
			else
				if [ $((CRYPT_DISK_SPACE)) -lt $((TOTAL_DATABASES_SIZE)) ]; then
					Logger "Disk space in [$CRYPT_STORAGE] may be insufficient to encrypt SQL ($CRYPT_DISK_SPACE Ko available in $CRYPT_DRIVE) (non compressed databases calculation)." "WARN"
				fi
			fi
		fi

		if [ "$FILE_BACKUP" != "no" ]; then
			if [ "$FILE_DRIVE" == "$CRYPT_DRIVE" ]; then
				if [ $((FILE_DISK_SPACE/2)) -lt $((TOTAL_FILES_SIZE)) ]; then
					Logger "Disk space in [$FILE_STORAGE] and [$CRYPT_STORAGE] may be insufficient to encrypt Sfiles ($FILE_DISK_SPACE Ko available in $FILE_DRIVE)." "WARN"
				fi
			else
				if [ $((CRYPT_DISK_SPACE)) -lt $((TOTAL_FILES_SIZE)) ]; then
					Logger "Disk space in [$CRYPT_STORAGE] may be insufficient to encrypt files ($CRYPT_DISK_SPACE Ko available in $CRYPT_DRIVE)." "WARN"
				fi
			fi
		fi

		Logger "Crypt storage space: $CRYPT_DISK_SPACE Ko" "NOTICE"
	fi

	if [ $BACKUP_SIZE_MINIMUM -gt $((TOTAL_DATABASES_SIZE+TOTAL_FILES_SIZE)) ] && [ "$GET_BACKUP_SIZE" != "no" ]; then
		Logger "Backup size is smaller than expected." "WARN"
	fi
}

function _BackupDatabaseLocalToLocal {
	local database="${1}" # Database to backup
	local exportOptions="${2}" # export options
	local encrypt="${3:-false}" # Does the file need to be encrypted ?

	local encryptOptions
	local drySqlCmd
	local sqlCmd
	local retval

        __CheckArguments 3 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ $encrypt == true ]; then
		encryptOptions="| $CRYPT_TOOL --encrypt --recipient=\"$GPG_RECIPIENT\""
		encryptExtension="$CRYPT_FILE_EXTENSION"
	fi

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > $SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			Logger "Command was [$drySqlCmd]." "WARN"
			eval "$drySqlCmd" &
		fi
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
        fi
	return $retval
}

function _BackupDatabaseLocalToRemote {
	local database="${1}" # Database to backup
	local exportOptions="${2}" # export options
	local encrypt="${3:-false}" # Does the file need to be encrypted

        __CheckArguments 3 $# "$@"    #__WITH_PARANOIA_DEBUG

	local encryptOptions
	local encryptExtension
	local drySqlCmd
	local sqlCmd
	local retval

	CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost


	if [ $encrypt == true ]; then
		encryptOptions="| $CRYPT_TOOL --encrypt --recipient=\"$GPG_RECIPIENT\""
		encryptExtension="$CRYPT_FILE_EXTENSION"
	fi

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions | $SSH_CMD '$COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension\" > /dev/null' 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			Logger "Command was [$drySqlCmd]." "WARN"
			eval "$drySqlCmd" &
		fi
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
        fi
	return $retval
}

function _BackupDatabaseRemoteToLocal {
	local database="${1}" # Database to backup
	local exportOptions="${2}" # export options
	local encrypt="${3:-false}" # Does the file need to be encrypted ?

        __CheckArguments 3 $# "$@"    #__WITH_PARANOIA_DEBUG

	local encryptOptions
	local encryptExtension
	local drySqlCmd
	local sqlCmd
	local retval

	CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost


	if [ $encrypt == true ]; then
		encryptOptions="| $CRYPT_TOOL --encrypt --recipient=\\\"$GPG_RECIPIENT\\\""
		encryptExtension="$CRYPT_FILE_EXTENSION"
	fi

	local drySqlCmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'
	local sqlCmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension'" 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			Logger "Command was [$drySqlCmd]." "WARN"
			eval "$drySqlCmd" &
		fi
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
        fi
	return $retval
}

function BackupDatabase {
	local database="${1}"
        __CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local mysqlOptions
	local encrypt=false

	# Hack to prevent warning on table mysql.events, some mysql versions don't support --skip-events, prefer using --ignore-table
	if [ "$database" == "mysql" ]; then
		mysqlOptions="$MYSQLDUMP_OPTIONS --ignore-table=mysql.event"
	else
		mysqlOptions="$MYSQLDUMP_OPTIONS"
	fi

	if [ "$ENCRYPTION" == "yes" ]; then
		encrypt=true
		Logger "Backing up encrypted database [$database]." "NOTICE"
	else
		Logger "Backing up database [$database]." "NOTICE"
	fi

	if [ "$BACKUP_TYPE" == "local" ]; then
		_BackupDatabaseLocalToLocal "$database" "$mysqlOptions" $encrypt
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_BackupDatabaseRemoteToLocal "$database" "$mysqlOptions" $encrypt
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_BackupDatabaseLocalToRemote "$database" "$mysqlOptions" $encrypt
	fi

	if [ $? -ne 0 ]; then
		Logger "Backup failed." "ERROR"
	else
		Logger "Backup succeeded." "NOTICE"
	fi
}

function BackupDatabases {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local database

	for database in $SQL_BACKUP_TASKS
	do
		BackupDatabase $database
		CheckTotalExecutionTime
	done
}

function EncryptFiles {
	local filePath="${1}"	# Path of files to encrypt
	local destPath="${2}"    # Path to store encrypted files
	local recipient="${3}"  # GPG recipient
	local recursive="${4:-true}" # Is recursive ?
	local keepFullPath="${5:-false}" # Should destpath become destpath + sourcepath ?

	__CheckArguments 5 $# "$@"    #__WITH_PARANOIA_DEBUG

	local successCounter=0
	local errorCounter=0
	local cryptFileExtension="$CRYPT_FILE_EXTENSION"
	local recursiveArgs=""

	if [ ! -d "$destPath" ]; then
		mkdir -p "$destPath"
		if [ $? -ne 0 ]; then
			Logger "Cannot create crypt storage path [$destPath]." "ERROR"
			return 1
		fi
	fi

	if [ ! -w "$destPath" ]; then
		Logger "Cannot write to crypt storage path [$destPath]." "ERROR"
		return 1
	fi

	if [ $recursive == false ]; then
		recursiveArgs="-mindepth 1 -maxdepth 1"
	fi

	Logger "Encrypting files in [$filePath]." "NOTICE"
	while IFS= read -r -d $'\0' sourceFile; do
		# Get path of sourcefile
		path="$(dirname "$sourceFile")"
		if [ $keepFullPath == false ]; then
			# Remove source path part
			path="${path#$filePath}"
		fi
		# Remove ending slash if there is one
		path="${path%/}"
		# Add new path
		path="$destPath/$path"

		# Get filename
		file="$(basename "$sourceFile")"
		if [ ! -d "$path" ]; then
			mkdir -p "$path"
		fi

		Logger "Encrypting file [$sourceFile] to [$path/$file$cryptFileExtension]." "VERBOSE"
		if [ $(IsNumeric $PARALLEL_ENCRYPTION_PROCESSES) -eq 1  ] && [ "$PARALLEL_ENCRYPTION_PROCESSES" != "1" ]; then
			echo "$CRYPT_TOOL --batch --yes --out \"$path/$file$cryptFileExtension\" --recipient=\"$recipient\" --encrypt \"$sourceFile\" >> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP"
		else
			$CRYPT_TOOL --batch --yes --out "$path/$file$cryptFileExtension" --recipient="$recipient" --encrypt "$sourceFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1
			if [ $? -ne 0 ]; then
				Logger "Cannot encrypt [$sourceFile]." "ERROR"
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "DEBUG"
				errorCounter=$((errorCounter+1))
			else
				successCounter=$((successCounter+1))
			fi
		fi
	done < <($FIND_CMD "$filePath" $recursiveArgs -type f ! -name "*$cryptFileExtension" -print0)

	if [ $(IsNumeric $PARALLEL_ENCRYPTION_PROCESSES) -eq 1 ] && [ "$PARALLEL_ENCRYPTION_PROCESSES" != "1" ]; then
		# Handle batch mode where SOFT /HARD MAX EXEC TIME TOTAL is not defined
		if [ $(IsNumeric $SOFT_MAX_EXEC_TIME_TOTAL) -eq 1 ]; then
			softMaxExecTime=$SOFT_MAX_EXEC_TIME_TOTAL
		else
			softMaxExecTime=0
		fi

		if [ $(IsNumeric $HARD_MAX_EXEC_TIME_TOTAL) -eq 1 ]; then
			hardMaxExecTime=$HARD_MAX_EXEC_TIME_TOTAL
		else
			hardMaxExecTime=0
		fi

		ParallelExec $PARALLEL_ENCRYPTION_PROCESSES "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP" true $softMaxExecTime $hardMaxExecTime $SLEEP_TIME $KEEP_LOGGING true true false
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Encryption error.." "ERROR"
			# Output file is defined in ParallelExec
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ParallelExec.EncryptFiles.$SCRIPT_PID.$TSTAMP)" "DEBUG"
		fi
		successCounter=$(($(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP") - retval))
		errorCounter=$retval
	fi

	if [ $successCounter -gt 0 ]; then
		Logger "Encrypted [$successCounter] files successfully." "NOTICE"
	elif [ $successCounter -eq 0 ] && [ $errorCounter -eq 0 ]; then
		Logger "There were no files to encrypt." "WARN"
	fi
		if [ $errorCounter -gt 0 ]; then
		Logger "Failed to encrypt [$errorCounter] files." "CRITICAL"
	fi
	return $errorCounter
}

function DecryptFiles {
	local filePath="${1}"	 # Path to files to decrypt
	local passphraseFile="${2}"  # Passphrase file to decrypt files
	local passphrase="${3}"	# Passphrase to decrypt files

	__CheckArguments 3 $# "$@"    #__WITH_PARANOIA_DEBUG

	local options
	local secret
	local successCounter=0
	local errorCounter=0
	local cryptToolVersion
	local cryptToolMajorVersion
	local cryptToolSubVersion
	local cryptFileExtension="$CRYPT_FILE_EXTENSION"

	local retval

	if [ ! -w "$filePath" ]; then
		Logger "Path [$filePath] is not writable or does not exist. Cannot decrypt files." "CRITICAL"
		exit 1
	fi

	# Detect if GnuPG >= 2.1 that does not allow automatic pin entry anymore
	cryptToolVersion=$($CRYPT_TOOL --version | head -1 | awk '{print $3}')
	cryptToolMajorVersion=${cryptToolVersion%%.*}
	cryptToolSubVersion=${cryptToolVersion#*.}
	cryptToolSubVersion=${cryptToolSubVersion%.*}

	if [ $cryptToolMajorVersion -eq 2 ] && [ $cryptToolSubVersion -ge 1 ]; then
		additionalParameters="--pinentry-mode loopback"
	fi

	if [ -f "$passphraseFile" ]; then
		secret="--passphrase-file $passphraseFile"
	elif [ "$passphrase" != "" ]; then
		secret="--passphrase $passphrase"
	else
		Logger "The given passphrase file or passphrase are inexistent." "CRITICAL"
		exit 1
	fi

	if [ "$CRYPT_TOOL" == "gpg2" ]; then
		options="--batch --yes"
	elif [ "$CRYPT_TOOL" == "gpg" ]; then
		options="--no-use-agent --batch"
	fi

	while IFS= read -r -d $'\0' encryptedFile; do
		Logger "Decrypting [$encryptedFile]." "VERBOSE"

		if [ $(IsNumeric $PARALLEL_ENCRYPTION_PROCESSES) -eq 1  ] && [ "$PARALLEL_ENCRYPTION_PROCESSES" != "1" ]; then
			echo "$CRYPT_TOOL $options --out \"${encryptedFile%%$cryptFileExtension}\" $additionalParameters $secret --decrypt \"$encryptedFile\" >> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP"
		else
			$CRYPT_TOOL $options --out "${encryptedFile%%$cryptFileExtension}" $additionalParameters $secret --decrypt "$encryptedFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Cannot decrypt [$encryptedFile]." "ERROR"
				Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
				errorCounter=$((errorCounter+1))
			else
				successCounter=$((successCounter+1))
				rm -f "$encryptedFile"
				if [ $? -ne 0 ]; then
					Logger "Cannot delete original file [$encryptedFile] after decryption." "ERROR"
				fi
			fi
		fi
	done < <($FIND_CMD "$filePath" -type f -name "*$cryptFileExtension" -print0)

	if [ $(IsNumeric $PARALLEL_ENCRYPTION_PROCESSES) -eq 1 ] && [ "$PARALLEL_ENCRYPTION_PROCESSES" != "1" ]; then
		# Handle batch mode where SOFT /HARD MAX EXEC TIME TOTAL is not defined
		if [ $(IsNumeric $SOFT_MAX_EXEC_TIME_TOTAL) -eq 1 ]; then
			softMaxExecTime=$SOFT_MAX_EXEC_TIME_TOTAL
		else
			softMaxExecTime=0
		fi

		if [ $(IsNumeric $HARD_MAX_EXEC_TIME_TOTAL) -eq 1 ]; then
			hardMaxExecTime=$HARD_MAX_EXEC_TIME_TOTAL
		else
			hardMaxExecTime=0
		fi

		ParallelExec $PARALLEL_ENCRYPTION_PROCESSES "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP" true $softMaxExecTime $hardMaxExecTime $SLEEP_TIME $KEEP_LOGGING true true false
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Decrypting error.." "ERROR"
			# Output file is defined in ParallelExec
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ParallelExec.EncryptFiles.$SCRIPT_PID.$TSTAMP)" "DEBUG"
		fi
		successCounter=$(($(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP") - retval))
		errorCounter=$retval
	fi

	if [ $successCounter -gt 0 ]; then
		Logger "Decrypted [$successCounter] files successfully." "NOTICE"
	elif [ $successCounter -eq 0 ] && [ $errorCounter -eq 0 ]; then
		Logger "There were no files to decrypt." "WARN"
	fi

	if [ $errorCounter -gt 0 ]; then
		Logger "Failed to decrypt [$errorCounter] files." "CRITICAL"
	fi
	return $errorCounter
}

function Rsync {
	local sourceDir="${1}"		# Source directory
	local destinationDir="${2}"	# Destination directory
	local recursive="${2:-true}"	# Backup only files at toplevel of directory

        __CheckArguments 3 $# "$@"    #__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
	if [ $recursive == false ]; then
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion, and excludes subdirectories
		RSYNC_NO_RECURSE_ARGS=" -k  --exclude=*/*/"
	else
		RSYNC_NO_RECURSE_ARGS=""
	fi

	Logger "Beginning file backup of [$sourceDir] to [$destinationDir]." "VERBOSE"


	# Creating subdirectories because rsync cannot handle multiple subdirectory creation
	if [ "$BACKUP_TYPE" == "local" ]; then
		_CreateDirectoryLocal "$destinationDir"
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$sourceDir\" \"$destinationDir\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_CreateDirectoryLocal "$destinationDir"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		sourceDir=$(EscapeSpaces "$sourceDir")
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$sourceDir\" \"$destinationDir\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		destinationDir=$(EscapeSpaces "$destinationDir")
		_CreateDirectoryRemote "$destinationDir"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$sourceDir\" \"$REMOTE_USER@$REMOTE_HOST:$destinationDir\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	fi

	Logger "Launching command [$rsyncCmd]." "DEBUG"
	eval "$rsyncCmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed to backup [$sourceDir] to [$destinationDir]." "ERROR"
		Logger "Command was [$rsyncCmd]." "WARN"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi

	return $retval
}

function FilesBackup {
        __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local backupTask
	local backupTasks
	local destinationDir
	local withoutCryptPath


	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$FILE_BACKUP_TASKS"
	for backupTask in "${backupTasks[@]}"; do
	# Backup directories from simple list

		if [ "$KEEP_ABSOLUTE_PATHS" != "no" ]; then
			destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}")
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning backup task [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" "$destinationDir" true
			if [ $? -eq 0 ]; then
				EncryptFiles "$encryptDir" "$CRYPT_STORAGE/$backupTask" "$GPG_RECIPIENT" true false
			fi
		else
			Rsync "$backupTask" "$destinationDir" true
		fi
		CheckTotalExecutionTime
	done

	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$RECURSIVE_DIRECTORY_LIST"
	for backupTask in "${backupTasks[@]}"; do
	# Backup recursive directories withouht recursion

		if [ "$KEEP_ABSOLUTE_PATHS" != "no" ]; then
			destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}")
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning backup task [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" false true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" false
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" "$destinationDir" false
			if [ $? -eq 0 ]; then
				EncryptFiles "$encryptDir" "$CRYPT_STORAGE/$backupTask" "$GPG_RECIPIENT" false false
			fi
		else
			Rsync "$backupTask" "$destinationDir" false
		fi
		CheckTotalExecutionTime
	done

	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$FILE_RECURSIVE_BACKUP_TASKS"
	for backupTask in "${backupTasks[@]}"; do
	# Backup sub directories of recursive directories

		if [ "$KEEP_ABSOLUTE_PATHS" != "no" ]; then
			destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}")
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning backup task [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" "$destinationDir" true
			if [ $? -eq 0 ]; then
				EncryptFiles "$encryptDir" "$CRYPT_STORAGE/$backupTask" "$GPG_RECIPIENT" true false
			fi
		else
			Rsync "$backupTask" "$destinationDir" true
		fi
		CheckTotalExecutionTime
	done
}

function CheckTotalExecutionTime {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	#### Check if max execution time of whole script as been reached
	if [ $SECONDS -gt $SOFT_MAX_EXEC_TIME_TOTAL ]; then
		Logger "Max soft execution time of the whole backup exceeded." "WARN"
		SendAlert true
	fi

	if [ $SECONDS -gt $HARD_MAX_EXEC_TIME_TOTAL ] && [ $HARD_MAX_EXEC_TIME_TOTAL -ne 0 ]; then
		Logger "Max hard execution time of the whole backup exceeded, stopping backup process." "CRITICAL"
		exit 1
	fi
}

function _RotateBackupsLocal {
	local backupPath="${1}"
	local rotateCopies="${2}"
	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

	local backup
	local copy
	local cmd
	local path

	$FIND_CMD "$backupPath" -mindepth 1 -maxdepth 1 ! -regex ".*\.$PROGRAM\.[0-9]+"  -print0 | while IFS= read -r -d $'\0' backup; do
		copy=$rotateCopies
		while [ $copy -gt 1 ]; do
			if [ $copy -eq $rotateCopies ]; then
				path="$backup.$PROGRAM.$copy"
				if [ -f "$path" ] || [ -d "$path" ]; then
					cmd="rm -rf \"$path\""
					Logger "Launching command [$cmd]." "DEBUG"
					eval "$cmd" &
					WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
					if [ $? -ne 0 ]; then
						Logger "Cannot delete oldest copy [$path]." "ERROR"
						Logger "Command was [$cmd]." "WARN"
					fi
				fi
			fi

			path="$backup.$PROGRAM.$((copy-1))"
			if [ -f "$path" ] || [ -d "$path" ]; then
				cmd="mv \"$path\" \"$backup.$PROGRAM.$copy\""
				Logger "Launching command [$cmd]." "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
				if [ $? -ne 0 ]; then
					Logger "Cannot move [$path] to [$backup.$PROGRAM.$copy]." "ERROR"
					Logger "Command was [$cmd]." "WARN"
				fi

			fi
			copy=$((copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -ne 0 ]; then
				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				Logger "Command was [$cmd]." "WARN"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -ne 0 ]; then
				Logger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				Logger "Command was [$cmd]." "WARN"
			fi

		else
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -ne 0 ]; then
 				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				Logger "Command was [$cmd]." "WARN"
			fi
		fi
	done
}

function _RotateBackupsRemote {
	local backupPath="${1}"
	local rotateCopies="${2}"
	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

$SSH_CMD env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" env rotateCopies="'$rotateCopies'" env backupPath="'$backupPath'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

function _RotateBackupsRemoteSSH {
	$REMOTE_FIND_CMD "$backupPath" -mindepth 1 -maxdepth 1 ! -regex ".*\.$PROGRAM\.[0-9]+"  -print0 | while IFS= read -r -d $'\0' backup; do
		copy=$rotateCopies
		while [ $copy -gt 1 ]; do
			if [ $copy -eq $rotateCopies ]; then
				path="$backup.$PROGRAM.$copy"
				if [ -f "$path" ] || [ -d "$path" ]; then
					cmd="rm -rf \"$path\""
					RemoteLogger "Launching command [$cmd]." "DEBUG"
					eval "$cmd"
					if [ $? -ne 0 ]; then
						RemoteLogger "Cannot delete oldest copy [$path]." "ERROR"
						RemoteLogger "Command was [$cmd]." "WARN"
					fi
				fi
			fi
			path="$backup.$PROGRAM.$((copy-1))"
			if [ -f "$path" ] || [ -d "$path" ]; then
				cmd="mv \"$path\" \"$backup.$PROGRAM.$copy\""
				RemoteLogger "Launching command [$cmd]." "DEBUG"
				eval "$cmd"
				if [ $? -ne 0 ]; then
					RemoteLogger "Cannot move [$path] to [$backup.$PROGRAM.$copy]." "ERROR"
					RemoteLogger "Command was [$cmd]." "WARN"
				fi

			fi
			copy=$((opy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "Launching command [$cmd]." "DEBUG"
			eval "$cmd"
			if [ $? -ne 0 ]; then
				RemoteLogger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				RemoteLogger "Command was [$cmd]." "WARN"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "Launching command [$cmd]." "DEBUG"
			eval "$cmd"
			if [ $? -ne 0 ]; then
				RemoteLogger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				RemoteLogger "Command was [$cmd]." "WARN"
			fi

		else
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "Launching command [$cmd]." "DEBUG"
			eval "$cmd"
			if [ $? -ne 0 ]; then
 				RemoteLogger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				RemoteLogger "Command was [$cmd]." "WARN"
			fi
		fi
	done
}

	_RotateBackupsRemoteSSH

ENDSSH

	WaitForTaskCompletion $! 1800 0 $SLEEP_TIME $KEEP_LOGGING true true false
        if [ $? -ne 0 ]; then
                Logger "Could not rotate backups in [$backupPath]." "ERROR"
                Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
        else
                Logger "Remote rotation succeed." "NOTICE"
        fi        ## Need to add a trivial sleep time to give ssh time to log to local file
        #sleep 5


}

#TODO: test find cmd for backup rotation with regex on busybox / mac
function RotateBackups {
	local backupPath="${1}"
	local rotateCopies="${2}"

	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

	Logger "Rotating backups in [$backupPath] for [$rotateCopies] copies." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		_RotateBackupsLocal "$backupPath" "$rotateCopies"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_RotateBackupsRemote "$backupPath" "$rotateCopies"
	fi
}

function Init {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	local uri
	local hosturiandpath
	local hosturi

	trap TrapStop INT QUIT TERM HUP
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
                        if [ ! -f "$SSH_PASSWORD_FILE" ]; then
                                # Assume that there might exist a standard rsa key
                                SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
                        fi
                fi

                # remove everything before '@'
                hosturiandpath=${uri#*@}
                # remove everything after first '/'
                hosturi=${hosturiandpath%%/*}
                if [[ "$hosturi" == *":"* ]]; then
                        REMOTE_PORT=${hosturi##*:}
                else
                        REMOTE_PORT=22
                fi
                REMOTE_HOST=${hosturi%%:*}
	fi

	## Add update to default RSYNC_ARGS
	RSYNC_ARGS=$RSYNC_ARGS" -u"

	if [ $_LOGGER_VERBOSE == true ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -i"
	fi

	if [ "$DELETE_VANISHED_FILES" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --delete"
	fi

	if [ $stats == true ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --stats"
	fi

	## Fix for symlink to directories on target cannot get updated
	RSYNC_ARGS=$RSYNC_ARGS" --force"
}

function Main {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL == true ]; then
		ListDatabases
	fi
	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES == true ]; then
		ListRecursiveBackupDirectories
		if [ "$GET_BACKUP_SIZE" != "no" ]; then
			GetDirectoriesSize
		else
			TOTAL_FILES_SIZE=-1
		fi
	fi

	# Expand ~ if exists
	FILE_STORAGE="${FILE_STORAGE/#\~/$HOME}"
	SQL_STORAGE="${SQL_STORAGE/#\~/$HOME}"
	SSH_RSA_PRIVATE_KEY="${SSH_RSA_PRIVATE_KEY/#\~/$HOME}"
	SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE/#\~/$HOME}"
	ENCRYPT_PUBKEY="${ENCRYPT_PUBKEY/#\~/$HOME}"

	if [ "$CREATE_DIRS" != "no" ]; then
		CreateStorageDirectories
	fi
	CheckDiskSpace

	# Actual backup process
	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL == true ]; then
		if [ $_DRYRUN == false ] && [ "$ROTATE_SQL_BACKUPS" == "yes" ]; then
			RotateBackups "$SQL_STORAGE" "$ROTATE_SQL_COPIES"
		fi
		BackupDatabases
	fi

	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES == true ]; then
		if [ $_DRYRUN == false ] && [ "$ROTATE_FILE_BACKUPS" == "yes" ]; then
			RotateBackups "$FILE_STORAGE" "$ROTATE_FILE_COPIES"
		fi
	        ## Add Rsync include / exclude patterns
        	RsyncPatterns
		FilesBackup
	fi
}

function Usage {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG


	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "General usage: $0 /path/to/backup.conf [OPTIONS]"
	echo ""
	echo "OPTIONS:"
	echo "--dry             will run $PROGRAM without actually doing anything, just testing"
        echo "--no-prefix       Will suppress time / date suffix from output"
	echo "--silent          will run $PROGRAM without any output to stdout, usefull for cron backups"
	echo "--errors-only     Output only errors (can be combined with silent or verbose)"
	echo "--verbose         adds command outputs"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      disables any soft and hard execution time checks"
	echo "--delete          Deletes files on destination that vanished on source"
	echo "--dontgetsize     Does not try to evaluate backup size"
	echo "--parallel=ncpu	Use n cpus to encrypt / decrypt files. Works in normal and batch processing mode."
	echo ""
	echo "Batch processing usage:"
	echo -e "\e[93mDecrypt\e[0m a backup encrypted with $PROGRAM"
	echo  "$0 --decrypt=/path/to/encrypted_backup --passphrase-file=/path/to/passphrase"
	echo  "$0 --decrypt=/path/to/encrypted_backup --passphrase=MySecretPassPhrase (security risk)"
	echo ""
	echo "Batch encrypt directories in separate gpg files"
	echo "$0 --encrypt=/path/to/files --destination=/path/to/encrypted/files --recipient=\"Your Name\""
	exit 128
}

# Command line argument flags
_DRYRUN=false
no_maxtime=false
stats=false
PARTIAL=no
_DECRYPT_MODE=false
DECRYPT_PATH=""
_ENCRYPT_MODE=false

function GetCommandlineArguments {
	if [ $# -eq 0 ]; then
		Usage
	fi

	for i in "$@"; do
		case $i in
			--dry)
			_DRYRUN=true
			;;
			--silent)
			_LOGGER_SILENT=true
			;;
			--verbose)
			_LOGGER_VERBOSE=true
			;;
			--stats)
			stats=false
			;;
			--partial)
			PARTIAL="yes"
			;;
			--no-maxtime)
			no_maxtime=true
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
			--decrypt=*)
			_DECRYPT_MODE=true
			DECRYPT_PATH="${i##*=}"
			;;
			--passphrase=*)
			PASSPHRASE="${i##*=}"
			;;
			--passphrase-file=*)
			PASSPHRASE_FILE="${i##*=}"
			;;
			--encrypt=*)
			_ENCRYPT_MODE=true
			CRYPT_SOURCE="${i##*=}"
			;;
			--destination=*)
			CRYPT_STORAGE="${i##*=}"
			;;
			--recipient=*)
			GPG_RECIPIENT="${i##*=}"
			;;
			--errors-only)
			_LOGGER_ERR_ONLY=true
			;;
                	--no-prefix)
                	_LOGGER_PREFIX=""
                	;;
			--parallel=*)
			PARALLEL_ENCRYPTION_PROCESSES="${i##*=}"
			if [ $(IsNumeric $PARALLEL_ENCRYPTION_PROCESSES) -ne 1 ]; then
				Logger "Bogus --parallel value. Using only one CPU." "WARN"
			fi
		esac
	done
}

GetCommandlineArguments "$@"
if [ "$_DECRYPT_MODE" == true ]; then
	CheckCryptEnvironnment
	GetLocalOS
	InitLocalOSDependingSettings
	Logger "$DRY_WARNING$PROGRAM v$PROGRAM_VERSION decrypt mode begin." "ALWAYS"
	DecryptFiles "$DECRYPT_PATH" "$PASSPHRASE_FILE" "$PASSPHRASE"
	exit $?
fi

if [ "$_ENCRYPT_MODE" == true ]; then
	CheckCryptEnvironnment
	GetLocalOS
	InitLocalOSDependingSettings
	Logger "$DRY_WARNING$PROGRAM v$PROGRAM_VERSION encrypt mode begin." "ALWAYS"
	EncryptFiles "$CRYPT_SOURCE" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true false
	exit $?
fi

LoadConfigFile "$1"
if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "${HOME}" != "" ] && [ -w "{$HOME}" ]); then
		LOG_FILE="${HOME}/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE=./$PROGRAM.$INSTANCE_ID.log
	fi
else
	LOG_FILE="$LOGFILE"
fi

if [ ! -w "$(dirname $LOG_FILE)" ]; then
	echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
	Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

if [ "$IS_STABLE" != "yes" ]; then
	Logger "This is an unstable dev build [$PROGRAM_BUILD]. Please use with caution." "WARN"
fi

DATE=$(date)
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING$DATE - $PROGRAM v$PROGRAM_VERSION $BACKUP_TYPE script begin." "ALWAYS"
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "Backup instance [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

GetLocalOS
InitLocalOSDependingSettings
CheckRunningInstances
PreInit
Init
CheckEnvironment
PostInit
CheckCurrentConfig
GetRemoteOS
InitRemoteOSDependingSettings

if [ $no_maxtime == true ]; then
	SOFT_MAX_EXEC_TIME_DB_TASK=0
	SOFT_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_DB_TASK=0
	HARD_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_TOTAL=0
fi
RunBeforeHook
Main
