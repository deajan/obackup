#!/bin/bash

###### Remote (or local) backup script for files & databases
###### (L) 2013 by Orsiris "Ozy" de Jong (www.netpower.fr)
OBACKUP_VERSION=1.84preRC3-MSYS-compatible
OBACKUP_BUILD=2209201303

DEBUG=no
SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -d /var/log ]
then
	LOG_FILE=/var/log/obackup.log
else
	LOG_FILE=./obackup.log
fi

## Default directory where to store run files
if [ -d /dev/shm ]
then
	RUN_DIR=/dev/shm
elif [ -d /tmp ]
then
	RUN_DIR=/tmp
elif [ -d /var/tmp ]
then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Log a state message every $KEEP_LOGGING seconds. Should generally not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

## Global variables and forked command results
DATABASES_TO_BACKUP=""					# Processed list of DBs that will be backed up
DATABASES_EXCLUDED_LIST=""				# Processed list of DBs that won't be backed up
TOTAL_DATABASES_SIZE=0					# Total DB size of $DATABASES_TO_BACKUP
DIRECTORIES_RECURSE_TO_BACKUP=""			# Processed list of recursive directories that will be backed up
DIRECTORIES_EXCLUDED_LIST=""				# Processed list of recursive directorires that won't be backed up
DIRECTORIES_TO_BACKUP=""				# Processed list of all directories to backup
TOTAL_FILES_SIZE=0					# Total file size of $DIRECTORIES_TO_BACKUP

# $RUN_DIR/obackup_dblist_$SCRIPT_PID                   Databases list and sizes
# $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID	Recursive directories list
# $RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID	Local free space for sql backup
# $RUN_DIR/obackup_local_file_storage_$SCRIPT_PID	Local free space for file backup
# $RUN_DIR/obackup_fsize_$SCRIPT_PID			Size of $DIRECTORIES_TO_BACKUP
# $RUN_DIR/obackup_rsync_output_$SCRIPT_PID		Output of Rsync command
# $RUN_DIR/obackup_config_$SCRIPT_PID			Parsed configuration file
# $RUN_DIR/obackup_run_local_$SCRIPT_PID		Output of command to be run localy
# $RUN_DIR/obackup_run_remote_$SCRIPT_PID		Output of command to be run remotely

function Log
{
	echo "TIME: $SECONDS - $1" >> "$LOG_FILE"
	if [ $silent -eq 0 ]
	then
		echo -e "TIME: $SECONDS - $1"
	fi
}

function LogError
{
	Log "$1"
	error_alert=1
}

function TrapError
{
	local JOB="$0"
	local LINE="$1"
	local CODE="${2:-1}"
	if [ $silent -eq 0 ]
	then
		echo " /!\ Error in ${JOB}: Near line ${LINE}, exit code ${CODE}"
	fi
}

function TrapStop
{
	LogError " /!\ WARNING: Manual exit of backup script. Backups may be in inconsistent state."
	exit 1
}

function TrapQuit
{
	# Kill all child processes
	if type -p pkill > /dev/null 2>&1
	then
		pkill -TERM -P $$
	elif [ "$OSTYPE" == "msys" ]
	then
		## This is not really a clean way to get child process pids, especially the tail -n +2 which resolves a strange char apparition in msys bash
		for pid in $(ps -a | awk '{$1=$1}$1' | awk '{print $1" "$2}' | grep " $$$" | awk '{print $1}' | tail -n +2)
		do
			kill -9 $pid > /dev/null 2>&1
		done
	else
		for pid in $(ps -a --Group $$)
		do
			kill -9 $pid
		done
	fi

        if [ $error_alert -ne 0 ]
        then
                SendAlert
		CleanUp
                LogError "Backup script finished with errors."
                exit 1
        else
		CleanUp
                Log "Backup script finshed."
                exit 0
        fi
}

function Spinner
{
	if [ $silent -eq 1 ]
	then
		return 1
	fi

	case $toggle
	in
	1)
	echo -n $1" \ "
	echo -ne "\r"
	toggle="2"
	;;

	2)
	echo -n $1" | "
	echo -ne "\r"
	toggle="3"
	;;

	3)
	echo -n $1" / "
	echo -ne "\r"
	toggle="4"
	;;

	*)
	echo -n $1" - "
	echo -ne "\r"
	toggle="1"
	;;
	esac
}

function Dummy
{
	exit 1;
}

function StripQuotes
{
	echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

function EscapeSpaces
{
	echo $(echo $1 | sed 's/ /\\ /g')
}

function CleanUp
{
	if [ "$DEBUG" != "yes" ]
	then
		rm -f "$RUN_DIR/obackup_dblist_$SCRIPT_PID"
		rm -f "$RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID"
        	rm -f "$RUN_DIR/obackup_local_file_storage_$SCRIPT_PID"
        	rm -f "$RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID"
        	rm -f "$RUN_DIR/obackup_fsize_$SCRIPT_PID"
        	rm -f "$RUN_DIR/obackup_rsync_output_$SCRIPT_PID"
		rm -f "$RUN_DIR/obackup_config_$SCRIPT_PID"
		rm -f "$RUN_DIR/obackup_run_local_$SCRIPT_PID"
		rm -f "$RUN_DIR/obackup_run_remote_$SCRIPT_PID"
	fi
}

function SendAlert
{
	cat "$LOG_FILE" | gzip -9 > /tmp/obackup_lastlog.gz
        if type -p mutt > /dev/null 2>&1
        then
            echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s "Backup alert for $BACKUP_ID" $DESTINATION_MAILS -a /tmp/obackup_lastlog.gz
            if [ $? != 0 ]
            then
                Log "WARNING: Cannot send alert email via $(type -p mutt) !!!"
			else
				Log "Sent alert mail using mutt."
            fi
        elif type -p mail > /dev/null 2>&1
		then
			echo $MAIL_ALERT_MSG | $(type -p mail) -a /tmp/obackup_lastlog.gz -s "Backup alert for $BACKUP_ID" $DESTINATION_MAILS
            if [ $? != 0 ]
            then
                Log "WARNING: Cannot send alert email via $(type -p mail) with attachments !!!"
				echo $MAIL_ALERT_MSG | $(type -p mail) -s "Backup alert for $BACKUP_ID" $DESTINATION_MAILS
				if [ $? != 0 ]
				then
					Log "WARNING: Cannot send alert email via $(type -p mail) without attachments !!!"
				else
				Log "Sent alert mail using mail command without attachment."
				fi
			else
				Log "Sent alert mail using mail command."
            fi
        elif type -p sendemail > /dev/null 2>&1
		then
			$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "Backup alert for $BACKUP_ID" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER -o username $SMTP_USER -p password $SMTP_PASSWORD > /dev/null 2>&1
			if [ $? != 0 ]
			then
				Log "WARNING: Cannot send alert email via $(type -p sendemail) !!!"
			else
				Log "Sent alert mail using mail command without attachment."
			fi 
		else
		Log "WARNING: Cannot send alert email (no mutt / mail present) !!!"
		return 1
	fi
}

function LoadConfigFile
{
	if [ ! -f "$1" ]
	then
		LogError "Cannot load backup configuration file [$1]. Backup cannot start."
		return 1
	elif [[ "$1" != *".conf" ]]
	then
		LogError "Wrong configuration file supplied [$1]. Backup cannot start."
		return 1
	else 
		egrep '^#|^[^ ]*=[^;&]*'  "$1" > "$RUN_DIR/obackup_config_$SCRIPT_PID"
		source "$RUN_DIR/obackup_config_$SCRIPT_PID"
	fi
} 

function CheckEnvironment
{
	sed --version > /dev/null 2>&1
        if [ $? != 0 ]
        then
                LogError "GNU coreutils not found (tested for sed --version). Backup cannot start."
        	return 1
	fi
	

	if [ "$REMOTE_BACKUP" == "yes" ]
	then
		if ! type -p ssh > /dev/null 2>&1
		then
			LogError "ssh not present. Cannot start backup."
			return 1
		fi

		if [ "$BACKUP_SQL" != "no" ]
		then
			if ! type -p mysqldump > /dev/null 2>&1
			then
				LogError "mysqldump not present. Cannot start backup."
				return 1
			fi
		fi
	fi

	if [ "$BACKUP_FILES" != "no" ]
	then
		if ! type -p rsync > /dev/null 2>&1 
		then
			LogError "rsync not present. Backup cannot start."
			return 1
		fi
	fi
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds exec time exceeded unless $2 equals 0. Will stop task and log alert if $3 seconds exec time exceeded.
function WaitForTaskCompletion
{
        soft_alert=0
        SECONDS_BEGIN=$SECONDS
                if [ "$OSTYPE" == "msys" ]
        then
        	PROCESS_TEST="ps -a | awk '{\$1=\$1}\$1' | awk '{print \$1}' | grep $1"
        else
        	PROCESS_TEST="ps -p$1"
        fi
        while eval $PROCESS_TEST > /dev/null
        do
                Spinner
                sleep 1
                EXEC_TIME=$(($SECONDS - $SECONDS_BEGIN))
                if [ $(($EXEC_TIME % $KEEP_LOGGING)) -eq 0 ]
                then
                        Log "Current task still running."
                fi
                if [ $EXEC_TIME -gt $2 ]
                then
                        if [ $soft_alert -eq 0 ] && [ $2 != 0 ]
                        then
                                LogError "Max soft execution time exceeded for task."
                                soft_alert=1
                        fi
                        if [ $EXEC_TIME -gt $3 ] && [ $3 != 0 ]
                        then
                                LogError "Max hard execution time exceeded for task. Stopping task execution."
				kill -s SIGTERM $1
                                if [ $? == 0 ]
                                then
                                        LogError "Task stopped succesfully"
                                else
                                        LogError "Sending SIGTERM to process failed. Trying the hard way."
					kill -9 $1
					if [ $? != 0 ]
					then
						LogError "Could not stop task."
					fi
                                fi
                                return 1
                        fi
                fi
        done
	wait $child_pid
	return $?
}


## Runs local command $1 and waits for completition in $2 seconds
function RunLocalCommand
{
	if [ $dryrun -ne 0 ]
	then
		Log "Dryrun: Local command [$1] not run."
		return 1
	fi
	$1 > $RUN_DIR/obackup_run_local_$SCRIPT_PID 2>&1 &
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $2
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Running command [$1] on local host succeded."
	else
		LogError "Running command [$1] on local host failed."
	fi
	
	if [ $verbose -eq 1 ]
	then
		Log "Command output:\n$(cat $RUN_DIR/obackup_run_local_$SCRIPT_PID)"
	fi
	
	if [ "$STOP_ON_CMD_ERROR" == "yes" ]
        then
                exit 1
        fi

}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand
{
	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
        if [ $dryrun -ne 0 ]
        then
                Log "Dryrun: Remote command [$1] not run."
                return 1
        fi
	eval "$SSH_CMD \"$1\" > $RUN_DIR/obackup_run_remote_$SCRIPT_PID 2>&1 &"
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $2
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Running command [$1] succeded."
	else
		LogError "Running command [$1] failed."
	fi
	
	if [ -f $RUN_DIR/obackup_run_remote_$SCRIPT_PID ] && [ $verbose -eq 1 ]
	then
		Log "Command output:\n$(cat $RUN_DIR/obackup_run_remote_$SCRIPT_PID)"
	fi

        if [ "$STOP_ON_CMD_ERROR" == "yes" ]
        then
                exit 1
        fi
}

function RunBeforeHook
{
	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]
	then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]
	then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi	
}

function RunAfterHook
{
        if [ "$LOCAL_RUN_AFTER_CMD" != "" ]
        then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
        fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]
	then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi
}

function CreateLocalStorageDirectories
{
	if [ ! -d $LOCAL_SQL_STORAGE ] && [ "$BACKUP_SQL" != "no" ]
	then
		mkdir -p $LOCAL_SQL_STORAGE
	fi

	if [ ! -d $LOCAL_FILE_STORAGE ] && [ "$BACKUP_FILES" != "no" ]
	then
		mkdir -p $LOCAL_FILE_STORAGE
	fi
}

function CheckSpaceRequirements
{
	if [ "$BACKUP_SQL" != "no" ]
	then
		if [ -d $LOCAL_SQL_STORAGE ]
		then
			# Not elegant solution to make df silent on errors
			df -P $LOCAL_SQL_STORAGE > $RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID 2>&1
			if [ $? != 0 ]
			then
				LOCAL_SQL_SPACE=0
			else
				LOCAL_SQL_SPACE=$(cat $RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID | tail -1 | awk '{print $4}')
				LOCAL_SQL_DRIVE=$(cat $RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID | tail -1 | awk '{print $1}')
			fi

			if [ $LOCAL_SQL_SPACE -eq 0 ]
			then
				LogError "Local sql storage space reported to be 0Ko."
			elif [ $LOCAL_SQL_SPACE -lt $TOTAL_DATABASES_SIZE ]
			then
				LogError "Local disk space may be insufficient to backup files (available space is lower than non compressed databases)."
			fi
		else
			LOCAL_SQL_SPACE=0
			LogError "SQL storage path [$LOCAL_SQL_STORAGE] doesn't exist."
		fi
	else
		LOCAL_SQL_SPACE=0
	fi

        if [ "$BACKUP_FILES" != "no" ]
        then
                if [ -d $LOCAL_FILE_STORAGE ]
                then
                        df -P $LOCAL_FILE_STORAGE > $RUN_DIR/obackup_local_file_storage_$SCRIPT_PID 2>&1
                        if [ $? != 0 ]
                        then
                                LOCAL_FILE_SPACE=0
                        else
                                LOCAL_FILE_SPACE=$(cat $RUN_DIR/obackup_local_file_storage_$SCRIPT_PID | tail -1 | awk '{print $4}')
                                LOCAL_FILE_DRIVE=$(cat $RUN_DIR/obackup_local_file_storage_$SCRIPT_PID | tail -1 | awk '{print $1}')
                        fi

                        if [ $LOCAL_FILE_SPACE -eq 0 ]
                        then
                                LogError "Local file storage space reported to be 0Ko."
                        elif [ $LOCAL_FILE_SPACE -lt $TOTAL_FILES_SIZE ]
			then
				LogError "Local disk space may be insufficient to backup files (available space is lower than full backup)."
			fi
                else
			LOCAL_FILE_SPACE=0
                        LogError "File storage path [$LOCAL_FILE_STORAGE] doesn't exist."
                fi
        else
        	LOCAL_FILE_SPACE=0
        fi

	if [ "$LOCAL_SQL_DRIVE" == "$LOCAL_FILE_DRIVE" ]
	then
		LOCAL_SPACE=$LOCAL_FILE_SPACE
	else
		LOCAL_SPACE=$(($LOCAL_SQL_SPACE+$LOCAL_FILE_SPACE))
	fi

        if [ $BACKUP_SIZE_MINIMUM -gt $(($TOTAL_DATABASES_SIZE+$TOTAL_FILES_SIZE)) ]
        then
                LogError "Backup size is smaller then expected."
	elif [ $LOCAL_STORAGE_WARN_MIN_SPACE -gt $LOCAL_SPACE ]
	then
		LogError "Local disk space is lower than warning value [$LOCAL_STORAGE_WARN_MIN_SPACE Ko]."
	fi
	Log "Local Space: $LOCAL_SPACE Ko - Databases size: $TOTAL_DATABASES_SIZE Ko - Files size: $TOTAL_FILES_SIZE Ko"
}
      
function CheckTotalExecutionTime
{
	#### Check if max execution time of whole script as been reached
	if [ $SECONDS -gt $SOFT_MAX_EXEC_TIME_TOTAL ]
        then
		if [ $soft_alert_total -eq 0 ]
                then
                	LogError "Max soft execution time of the whole backup exceeded while backing up $BACKUP_TASK."
                        soft_alert_total=1
                fi
                if [ $SECONDS -gt $HARD_MAX_EXEC_TIME_TOTAL ]
                then
                        LogError "Max hard execution time of the whole backup exceeded while backing up $BACKUP_TASK, stopping backup process."
                        exit 1
                fi
        fi
}

function CheckConnectivityRemoteHost
{
	if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_BACKUP" != "no" ]
	then
		if [ "$OSTYPE" == "msys" ]
		then
			ping $REMOTE_HOST -n 2 > /dev/null 2>&1
		else
			ping $REMOTE_HOST -c 2 > /dev/null 2>&1
		fi
		if [ $? != 0 ]
		then
			LogError "Cannot ping $REMOTE_HOST"
			return 1
		fi
	fi
}

function CheckConnectivity3rdPartyHosts
{
	if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]
	then
		remote_3rd_party_success=0
		OLD_IFS=$IFS
                IFS=$' \t\n'
		for i in $REMOTE_3RD_PARTY_HOSTS
		do
			if [ "$OSTYPE" == "msys" ]
			then
				ping $i -n 2 > /dev/null 2>&1
			else
				ping $i -c 2 > /dev/null 2>&1
			fi
			if [ $? != 0 ]
			then
				LogError "Cannot ping 3rd party host $i"
			else
				remote_3rd_party_success=1
			fi
		done
		IFS=$OLD_IFS
		if [ $remote_3rd_party_success -ne 1 ]
		then
			LogError "No remote 3rd party host responded to ping. No internet ?"
			return 1
		fi
	fi
}
	
function ListDatabases
{
	SECONDS_BEGIN=$SECONDS
	Log "Listing databases."
	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ "$REMOTE_BACKUP" != "no" ]
	then
		eval "$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > $RUN_DIR/obackup_dblist_$SCRIPT_PID &"
	else
		mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/obackup_dblist_$SCRIPT_PID &
	fi
	child_pid=$!
	WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Listing databases succeeded."
	else
		LogError "Listing databases failed."
		if [ -f $RUN_DIR/obackup_dblist_$SCRIPT_PID ]
		then
			LogError "Command output:\n$(cat $RUN_DIR/obackup_dblist_$SCRIPT_PID)"
		fi
		return $retval
	fi

	OLD_IFS=$IFS
	IFS=$' \n'
	for line in $(cat $RUN_DIR/obackup_dblist_$SCRIPT_PID)	
	do
		db_name=$(echo $line | cut -f1)
		db_size=$(echo $line | cut -f2)

                if [ "$DATABASES_ALL" == "yes" ]
                then
                        db_backup=1
			for j in $DATABASES_ALL_EXCLUDE_LIST
                        do
                                if [ "$db_name" == "$j" ]
                                then
                                        db_backup=0
                                fi
                        done
                else
			db_backup=0
                        for j in $DATABASES_LIST
                        do
                                if [ "$db_name" == "$j" ]
                                then
                                        db_backup=1
                                fi
                        done
                fi

		if [ $db_backup -eq 1 ]
		then
			if [ "$DATABASES_TO_BACKUP" != "" ]
			then
				DATABASES_TO_BACKUP="$DATABASES_TO_BACKUP $db_name"
			else
				DATABASES_TO_BACKUP=$db_name
			fi
			TOTAL_DATABASES_SIZE=$((TOTAL_DATABASES_SIZE+$db_size))
		else
			DATABASES_EXCLUDED_LIST="$DATABASES_EXCLUDED_LIST $db_name"
		fi
	done
	IFS=$OLD_IFS
	return 0
}

function BackupDatabase
{
	CheckConnectivity3rdPartyHosts
	if [ "$REMOTE_BACKUP" == "yes" ] && [ "$COMPRESSION_REMOTE" == "no" ]
	then
		CheckConnectivityRemoteHost
		if [ $? != 0 ]
		then
			LogError "Connectivity test failed. Stopping current task."
			exit 1
		fi
		eval "$SSH_CMD mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 | $COMPRESSION_PROGRAM -$COMPRESSION_LEVEL $COMPRESSION_OPTIONS > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION"
	elif [ "$REMOTE_BACKUP" == "yes" ] && [ "$COMPRESSION_REMOTE" == "yes" ]
	then
		CheckConnectivityRemoteHost
		if [ $? != 0 ]
		then
			LogError "Connectivity test failed. Stopping current task."
			exit 1
		fi
		eval "$SSH_CMD \"mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 | $COMPRESSION_PROGRAM -$COMPRESSION_LEVEL $COMPRESSION_OPTIONS\" > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION"
	else
		mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 | $COMPRESSION_PROGRAM -$COMPRESSION_LEVEL $COMPRESSION_OPTIONS > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION
	fi
	exit $?
}

function BackupDatabases
{
	OLD_IFS=$IFS
        IFS=$' \t\n'
	for BACKUP_TASK in $DATABASES_TO_BACKUP
	do
		Log "Backing up database $BACKUP_TASK"
		SECONDS_BEGIN=$SECONDS
		BackupDatabase $BACKUP_TASK &
		child_pid=$!
		WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK
      	 	retval=$?
		if [ $retval -ne 0 ]
		then
			LogError "Backup failed."
		else
			Log "Backup succeeded."
		fi
	
		CheckTotalExecutionTime
	done
	IFS=$OLD_IFS
}

# Fetches single quoted directory listing including recursive ones separated by commas (eg '/dir1';'/dir2';'/dir3') 
function ListDirectories
{
	SECONDS_BEGIN=$SECONDS
	Log "Listing directories to backup."
	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for dir in $DIRECTORIES_RECURSE_LIST
	do
		CheckConnectivity3rdPartyHosts
		if [ "$REMOTE_BACKUP" == "yes" ]
		then
	                CheckConnectivityRemoteHost
			if [ $? != 0 ]
			then
				LogError "Connectivity test failed. Stopping current task."
				Dummy &
                	else
				eval "$SSH_CMD \"$COMMAND_SUDO $FIND_CMD $dir/ -mindepth 1 -maxdepth 1 -type d\" > $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID &"
			fi
		else
			eval "$COMMAND_SUDO $FIND_CMD $dir/ -mindepth 1 -maxdepth 1 -type d > $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID &"
		fi
		child_pid=$!
		WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK
		retval=$?
		if  [ $retval != 0 ]
		then
			LogError "Could not enumerate recursive directories in $dir."
			if [ -f $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID ]
			then
				LogError "Command output:\n$(cat $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID)"
			fi
			return 1
		else
			Log "Listing of recursive directories succeeded for $dir."
		fi

		OLD_IFS=$IFS
		IFS=$' \n'
		for line in $(cat $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID)
#		while read line
		do
			file_exclude=0
			for k in $DIRECTORIES_RECURSE_EXCLUDE_LIST
			do
				if [ "$k" == "$line" ]
				then
					file_exclude=1
				fi
			done

			if [ $file_exclude -eq 0 ]
			then
				if [ "$DIRECTORIES_TO_BACKUP" == "" ]
				then
					DIRECTORIES_TO_BACKUP="'$line'"
				else
					DIRECTORIES_TO_BACKUP="$DIRECTORIES_TO_BACKUP$PATH_SEPARATOR_CHAR'$line'"
				fi
			else
				DIRECTORIES_EXCLUDED_LIST="$DIRECTORIES_EXCLUDED_LIST$PATH_SEPARATOR_CHAR'$line'"
			fi
#		done < <(cat $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID)
		done
		IFS=$OLD_IFS
	done
	DIRECTORIES_TO_BACKUP_RECURSE=$DIRECTORIES_TO_BACKUP
	
	for dir in $DIRECTORIES_SIMPLE_LIST
	do
		if [ "$DIRECTORIES_TO_BACKUP" == "" ]
		then
			DIRECTORIES_TO_BACKUP="'$dir'"
		else
			DIRECTORIES_TO_BACKUP="$DIRECTORIES_TO_BACKUP$PATH_SEPARATOR_CHAR'$dir'"
		fi
	done

	IFS=$OLD_IFS
}

function GetDirectoriesSize
{	
 	# remove the path separator char from the dir list with sed 's/;/ /g'
	dir_list=$(echo $DIRECTORIES_TO_BACKUP | sed 's/'"$PATH_SEPARATOR_CHAR"'/ /g' )
	Log "Getting files size"
	CheckConnectivity3rdPartyHosts
	if [ "$REMOTE_BACKUP" == "yes" ]
	then
		CheckConnectivityRemoteHost
		if [ $? != 0 ]
		then
			LogError "Connectivity test failed. Stopping current task."
			Dummy &
		else
			eval "$SSH_CMD \"echo $dir_list | xargs $COMMAND_SUDO du -cs | tail -n1 | cut -f1\" > $RUN_DIR/obackup_fsize_$SCRIPT_PID &"
		fi
	else
		echo $dir_list | xargs $COMMAND_SUDO du -cs | tail -n1 | cut -f1 > $RUN_DIR/obackup_fsize_$SCRIPT_PID &
	fi
	child_pid=$!
	WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK
	retval=$?
	if  [ $retval != 0 ]
	then
		LogError "Could not get files size."
		if [ -f $RUN_DIR/obackup_fsize_$SCRIPT_PID ]
		then
			LogError "Command output:\n$(cat $RUN_DIR/obackup_fsize_$SCRIPT_PID)"
		fi
		return 1
	else
		Log "File size fetched successfully."
		TOTAL_FILES_SIZE=$(cat $RUN_DIR/obackup_fsize_$SCRIPT_PID)
	fi
}

function RsyncExcludePattern
{
	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for excludedir in $RSYNC_EXCLUDE_PATTERN
	do
		if [ "$RSYNC_EXCLUDE" == "" ]
		then
			RSYNC_EXCLUDE="--exclude=$(EscapeSpaces $excludedir)"
		else
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=$(EscapeSpaces $excludedir)"
		fi
	done
	IFS=$OLD_IFS
}

function Rsync
{
	i="$(StripQuotes $1)"
	if [ "$LOCAL_STORAGE_KEEP_ABSOLUTE_PATHS" == "yes" ]
	then
		local_file_storage_path="$(dirname $LOCAL_FILE_STORAGE$i)"
	else
	#### Leave the last directory path if recursive task when absolute paths not set so paths won't be mixed up
		if [ "$2" == "recurse" ]
		then
			local_file_storage_path="$LOCAL_FILE_STORAGE/$(basename $(dirname $i))"
		else
			local_file_storage_path="$LOCAL_FILE_STORAGE"
		fi
	fi
	if [ ! -d $local_file_storage_path ]
	then
		mkdir -p "$local_file_storage_path"
	fi

	CheckConnectivity3rdPartyHosts
	if [ "$REMOTE_BACKUP" == "yes" ]
	then
                CheckConnectivityRemoteHost
		if [ $? != 0 ]
		then
			LogError "Connectivity test failed. Stopping current task."
			exit 1
		fi
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS --stats --delete $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$1\" \"$local_file_storage_path\" > $RUN_DIR/obackup_rsync_output_$SCRIPT_PID 2>&1"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS --stats --delete $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$1\" \"$local_file_storage_path\" > $RUN_DIR/obackup_rsync_output_$SCRIPT_PID 2>&1"
	fi
	#### Eval is used so the full command is processed without bash adding single quotes round variables
	if [ $verbose -eq 1 ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	exit $?
}

#### First backup simple list then recursive list
function FilesBackup
{
	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for BACKUP_TASK in $DIRECTORIES_SIMPLE_LIST
	do
		BACKUP_TASK=$(StripQuotes $BACKUP_TASK)
		Log "Beginning file backup $BACKUP_TASK"
		SECONDS_BEGIN=$SECONDS
		Rsync $BACKUP_TASK &
		child_pid=$!
		WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK
        	retval=$?
		if [ $verbose -eq 1 ] && [ -f $RUN_DIR/obackup_rsync_output_$SCRIPT_PID ]
		then
			Log "List:\n$(cat $RUN_DIR/obackup_rsync_output_$SCRIPT_PID)"
		fi

		if [ $retval -ne 0 ]
		then
			LogError "Backup failed on remote files."
                        if [ $verbose -eq 0 ] && [ -f $RUN_DIR/obackup_rsync_output_$SCRIPT_PID ]
                        then
                                LogError "$(cat $RUN_DIR/obackup_rsync_output_$SCRIPT_PID)"
                        fi
		else
			Log "Backup succeeded."
		fi
		CheckTotalExecutionTime
	done

        for BACKUP_TASK in $DIRECTORIES_TO_BACKUP_RECURSE
        do
                BACKUP_TASK=$(StripQuotes $BACKUP_TASK)
                Log "Beginning file backup $BACKUP_TASK"
                SECONDS_BEGIN=$SECONDS
                Rsync $BACKUP_TASK "recurse" &
                child_pid=$!
                WaitForTaskCompletion $child_pid $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK
                retval=$?
                if [ $verbose -eq 1 ] && [ -f $RUN_DIR/obackup_rsync_output_$SCRIPT_PID ]
                then
                        Log "List:\n$(cat $RUN_DIR/obackup_rsync_output_$SCRIPT_PID)"
                fi

                if [ $retval -ne 0 ]
                then
                        LogError "Backup failed on remote files."
			if [ $verbose -eq 0 ] && [ -f $RUN_DIR/obackup_rsync_output_$SCRIPT_PID ]
			then
                        	LogError "$(cat $RUN_DIR/obackup_rsync_output_$SCRIPT_PID)"
			fi
                else
                        Log "Backup succeeded."
                fi
                CheckTotalExecutionTime
        done
	IFS=$OLD_IFS
}

# Will rotate everything in $1
function RotateBackups
{
	OLD_IFS=$IFS
        IFS=$' \t\n'
	for backup in $(ls -I "*.obackup.*" $1)
	do
		copy=$ROTATE_COPIES
		while [ $copy -gt 1 ]
		do
			if [ $copy -eq $ROTATE_COPIES ]
			then
				rm -rf "$1/$backup.obackup.$copy"
			fi
			path="$1/$backup.obackup.$(($copy-1))"
			if [[ -f $path || -d $path ]]
			then
				mv $path "$1/$backup.obackup.$copy"
			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]
		then
			mv "$1/$backup" "$1/$backup.obackup.1"
		elif [ "$REMOTE_BACKUP" == "yes" ]
		then
			cp -R "$1/$backup" "$1/$backup.obackup.1"
		else
			mv "$1/$backup" "$1/$backup.obackup.1"
		fi
	done
	IFS=$OLD_IFS
}

function Init
{
	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

        trap TrapStop SIGINT SIGQUIT SIGKILL SIGTERM SIGHUP
	trap TrapQuit EXIT
	if [ "$DEBUG" == "yes" ]
	then
		trap 'TrapError ${LINENO} $?' ERR
	fi

	if [ "$LOGFILE" == "" ]
	then
		if [ -d /var/log ]
		then
			LOG_FILE=/var/log/obackup_$OBACKUP_VERSION-$BACKUP_ID.log
		else
			LOG_FILE=./obackup_$OBACKUP_VERSION_$BACKUP_ID.log
		fi
	else
		LOG_FILE="$LOGFILE"
	fi

	MAIL_ALERT_MSG="Warning: Execution of obackup instance $BACKUP_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors."

	## If running Msys, find command of windows is used instead of msys one
	if [ "$OSTYPE" == "msys" ]
	then
		FIND_CMD=$(dirname $BASH)/find
	else
		FIND_CMD=find
	fi

	## Set SSH command
        if [ "$SSH_COMPRESSION" == "yes" ]
        then
                SSH_COMP=-C
        else
                SSH_COMP=
        fi
	SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
	RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -p $REMOTE_PORT"

        ## Support for older config files without RSYNC_EXECUTABLE option
        if [ "$RSYNC_EXECUTABLE" == "" ]
        then
                RSYNC_EXECUTABLE=rsync
        fi

	## Sudo execution option
        if [ "$SUDO_EXEC" == "yes" ]
        then
		if [ "$RSYNC_REMOTE_PATH" != "" ]
		then
			RSYNC_PATH="sudo $(type -p $RSYNC_REMOTE_PATH)/$RSYNC_EXECUTABLE)"
		else
			RSYNC_PATH="sudo $(type -p $RSYNC_EXECUTABLE)"
                fi
		COMMAND_SUDO="sudo"
        else
		if [ "$RSYNC_REMOTE_PATH" != "" ]
                        then
                                RSYNC_PATH="$(type -p $RSYNC_REMOTE_PATH)/$RSYNC_EXECUTABLE)"
                        else
                                RSYNC_PATH="$(type -p $RSYNC_EXECUTABLE)"
                        fi
                COMMAND_SUDO=""
        fi

	## Set Rsync arguments
        RSYNC_ARGS=-rlptgoDE
        if [ "$PRESERVE_ACL" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"A"
        fi
        if [ "$PRESERVE_XATTR" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"X"
        fi
        if [ "$RSYNC_COMPRESS" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"z"
        fi
	if [ $verbose -eq 1 ]
	then
		RSYNC_ARGS=$RSYNC_ARGS"i"
	fi
        if [ $dryrun -eq 1 ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"n"
                DRY_WARNING="/!\ DRY RUN"
        fi
        if [ "$BANDWIDTH" != "0" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
        fi

	## Set compression executable and extension
        if [ "$COMPRESSION_PROGRAM" == "xz" ] && type -p xz > /dev/null 2>&1
        then
                COMPRESSION_EXTENSION=.xz
        elif [ "$COMPRESSION_PROGRAM" == "lzma" ] && type -p lzma > /dev/null 2>&1
        then
                COMPRESSION_EXTENSION=.lzma
        elif [ "$COMPRESSION_PROGRAM" == "gzip" ] && type -p gzip > /dev/null 2>&1
        then
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        else
                COMPRESSION_EXTENSION=
        fi
}

function Main
{
	if [ "$BACKUP_SQL" != "no" ]
	then
		ListDatabases
	fi
	if [ "$BACKUP_FILES" != "no" ]
	then
		ListDirectories
		GetDirectoriesSize
	fi
	if [ $dryrun -ne 1 ]
	then
		CreateLocalStorageDirectories
	else
		Log "DB backup list: $DATABASES_TO_BACKUP"
	        Log "DB exclude list: $DATABASES_EXCLUDED_LIST"
        	Log "Dirs backup list: $DIRECTORIES_TO_BACKUP"
        	Log "Dirs exclude list: $DIRECTORIES_EXCLUDED_LIST"
	fi

	CheckSpaceRequirements

	# Actual backup process
	if [ "$BACKUP_SQL" != "no" ]
	then
		if [ $dryrun -ne 1 ]
		then
			if [ "$ROTATE_BACKUPS" == "yes" ]
			then
				RotateBackups $LOCAL_SQL_STORAGE
			fi
			BackupDatabases
		else
			Log "DRYRUN: databases not backed up."
		fi
	fi

	if [ "$BACKUP_FILES" != "no" ]
	then
		if [ $dryrun -ne 1 ]
		then
			if [ "$ROTATE_BACKUPS" == "yes" ]
			then
				RotateBackups $LOCAL_FILE_STORAGE
			fi
		fi
		RsyncExcludePattern
		FilesBackup
	fi
	# Be a happy sysadmin (and drink a coffee ? Nahh... it's past midnight.)
}

function Usage
{
	echo "Obackup $OBACKUP_VERSION $OBACKUP_BUILD"
	echo ""
	echo "usage: obackup /path/to/backup.conf [--dry] [--silent] [--verbose] [--no-maxtime]"
	echo ""
	echo "--dry: will run obackup without actually doing anything, just testing"
	echo "--silent: will run obackup without any output to stdout, usefull for cron backups"
	echo "--verbose: adds command outputs"
	echo "--no-maxtime: disables any soft and hard execution time checks"
	exit 128
}

# Command line argument flags
dryrun=0
silent=0
no_maxtime=0
if [ "$DEBUG" == "yes" ]
then
	verbose=1
else
	verbose=0
fi
# Alert flags
soft_alert_total=0
error_alert=0

if [ $# -eq 0 ]
then
	Usage
fi

for i in "$@"
do
	case $i in
		--dry)
		dryrun=1
		;;
		--silent)
		silent=1
		;;
		--verbose)
		verbose=1
		;;
		--no-maxtime)
		no_maxtime=1
		;;
		--help|-h|--version|-v)
		Usage
		;;
	esac
done

CheckEnvironment
if [ $? == 0 ]
then
	if [ "$1" != "" ]	
	then
		LoadConfigFile $1
		if [ $? == 0 ]
		then
			Init
			DATE=$(date)
			Log "--------------------------------------------------------------------"
			Log "$DRY_WARNING $DATE - Obackup v$OBACKUP_VERSION script begin."
			Log "--------------------------------------------------------------------"
			Log "Backup task [$BACKUP_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)"
			if [ $no_maxtime -eq 1 ]
                        then
                                SOFT_MAX_EXEC_TIME=0
                                HARD_MAX_EXEC_TIME=0
                        fi
			OLD_IFS=$IFS
			RunBeforeHook
			Main
			IFS=$OLD_IFS
			RunAfterHook
			CleanUp
		else
			LogError "Configuration file could not be loaded."
			exit 1
		fi
	else
		LogError "No configuration file provided."
		exit 1
	fi
else
	LogError "Environment not suitable to run obackup."
fi
