#!/bin/bash

###### Remote (or local) backup script for files & databases
###### (L) 2013-2015 by Orsiris "Ozy" de Jong (www.netpower.fr)
AUTHOR="(L) 2013-2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=1.9pre
PROGRAM_BUILD=2404201502

## type doesn't work on platforms other than linux (bash). If if doesn't work, always assume output is not a zero exitcode
if ! type -p "$BASH" > /dev/null
then
        echo "Please run this script only with bash shell. Tested on bash >= 3.2"
        exit 127
fi

## allow debugging from command line with preceding ocsync with DEBUG=yes
if [ ! "$DEBUG" == "yes" ]
then
        DEBUG=no
        SLEEP_TIME=.1
else
        SLEEP_TIME=3
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -w /var/log ]
then
	LOG_FILE=/var/log/obackup.log
else
	LOG_FILE=./obackup.log
fi

## Default directory where to store run files
if [ -w /tmp ]
then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]
then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Working directory for partial downloads
PARTIAL_DIR=".obackup_workdir_partial"

## Log a state message every $KEEP_LOGGING seconds. Should generally not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

## Correct output of all system commands (language agnostic)
export LC_ALL=C

## Global variables and forked command results
DATABASES_TO_BACKUP=""					# Processed list of DBs that will be backed up
DATABASES_EXCLUDED_LIST=""				# Processed list of DBs that won't be backed up
TOTAL_DATABASES_SIZE=0					# Total DB size of $DATABASES_TO_BACKUP
DIRECTORIES_RECURSE_TO_BACKUP=""			# Processed list of recursive directories that will be backed up
DIRECTORIES_EXCLUDED_LIST=""				# Processed list of recursive directorires that won't be backed up
DIRECTORIES_TO_BACKUP=""				# Processed list of all directories to backup
TOTAL_FILES_SIZE=0					# Total file size of $DIRECTORIES_TO_BACKUP

# $RUN_DIR/obackup_remote_os_$SCRIPT_PID		Result of remote OS detection
# $RUN_DIR/obackup_dblist_$SCRIPT_PID                   Databases list and sizes
# $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID	Recursive directories list
# $RUN_DIR/obackup_local_sql_storage_$SCRIPT_PID	Local free space for sql backup
# $RUN_DIR/obackup_local_file_storage_$SCRIPT_PID	Local free space for file backup
# $RUN_DIR/obackup_fsize_$SCRIPT_PID			Size of $DIRECTORIES_TO_BACKUP
# $RUN_DIR/obackup_rsync_output_$SCRIPT_PID		Output of Rsync command
# $RUN_DIR/obackup_config_$SCRIPT_PID			Parsed configuration file
# $RUN_DIR/obackup_run_local_$SCRIPT_PID		Output of command to be run localy
# $RUN_DIR/obackup_run_remote_$SCRIPT_PID		Output of command to be run remotely

ALERT_LOG_FILE=$RUN_DIR/obackup_lastlog		# This is the path where to store a temporary log file to send by mail

function Log
{
	echo -e "TIME: $SECONDS - $1" >> "$LOG_FILE"
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

function LogDebug
{
        if [ "$DEBUG" == "yes" ]
        then
                Log "$1"
        fi
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
		## Added || : to return success even if there is no child process to kill
                pkill -TERM -P $$ || :
	elif [ "$LOCAL_OS" == "msys" ] || [ "$OSTYPE" == "msys" ]
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
	echo $(echo "$1" | sed 's/ /\\ /g')
}

function CleanUp
{
	if [ "$DEBUG" != "yes" ]
	then
		rm -f "$RUN_DIR/obackup_remote_os_$SCRIPT_PID"
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
	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	MAIL_ALERT_MSG=$MAIL_ALERT_MSG$'\n\n'$(tail -n 25 "$LOG_FILE")
        if type -p mutt > /dev/null 2>&1
        then
            echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s "Backup alert for $BACKUP_ID" $DESTINATION_MAILS -a "$ALERT_LOG_FILE"
            if [ $? != 0 ]
            then
                Log "WARNING: Cannot send alert email via $(type -p mutt) !!!"
			else
				Log "Sent alert mail using mutt."
            fi
        elif type -p mail > /dev/null 2>&1
		then
			echo $MAIL_ALERT_MSG | $(type -p mail) -a "$ALERT_LOG_FILE" -s "Backup alert for $BACKUP_ID" $DESTINATION_MAILS
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
	fi

	if [ -f "$ALERT_LOG_FILE" ]
	then
		rm "$ALERT_LOG_FILE"
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

function GetLocalOS
{
        LOCAL_OS_VAR=$(uname -spio 2>&1)
        if [ $? != 0 ]
        then
                LOCAL_OS_VAR=$(uname -v 2>&1)
                if [ $? != 0 ]
                then
                        LOCAL_OS_VAR=($uname)
                fi
        fi

        case $LOCAL_OS_VAR in
                *"Linux"*)
                LOCAL_OS="Linux"
                ;;
                *"BSD"*)
                LOCAL_OS="BSD"
                ;;
                *"MINGW32"*)
                LOCAL_OS="msys"
                ;;
                *"Darwin"*)
                LOCAL_OS="MacOSX"
                ;;
                *)
                LogError "Running on >> $LOCAL_OS_VAR << not supported. Please report to the author."
                exit 1
                ;;
        esac
        LogDebug "Local OS: [$LOCAL_OS_VAR]."
}

function GetRemoteOS
{
        if [ "$REMOTE_SYNC" == "yes" ]
        then
                CheckConnectivity3rdPartyHosts
                CheckConnectivityRemoteHost
                eval "$SSH_CMD \"uname -spio\" > $RUN_DIR/obackup_remote_os_$SCRIPT_PID 2>&1"
                child_pid=$!
                WaitForTaskCompletion $child_pid 120 240
                retval=$?
                if [ $retval != 0 ]
                then
                        eval "$SSH_CMD \"uname -v\" > $RUN_DIR/obackup_remote_os_$SCRIPT_PID 2>&1"
                        child_pid=$!
                        WaitForTaskCompletion $child_pid 120 240
                        retval=$?
                        if [ $retval != 0 ]
                        then
                                eval "$SSH_CMD \"uname\" > $RUN_DIR/obackup_remote_os_$SCRIPT_PID 2>&1"
                                child_pid=$!
                                WaitForTaskCompletion $child_pid 120 240
                                retval=$?
                                if [ $retval != 0 ]
                                then
                                        LogError "Cannot Get remote OS type."
                                fi
                        fi
                fi

                REMOTE_OS_VAR=$(cat $RUN_DIR/obackup_remote_os_$SCRIPT_PID)

                case $REMOTE_OS_VAR in
                        *"Linux"*)
                        REMOTE_OS="Linux"
                        ;;
                        *"BSD"*)
                        REMOTE_OS="BSD"
                        ;;
                        *"MINGW32"*)
                        REMOTE_OS="msys"
                        ;;
                        *"Darwin"*)
                        REMOTE_OS="MacOSX"
                        ;;
                        *"ssh"*|*"SSH"*)
                        LogError "Cannot connect to remote system."
                        exit 1
                        ;;
                        *)
                        LogError "Running on remote OS failed. Please report to the author if the OS is not supported."
                        LogError "Remote OS said:\n$REMOTE_OS_VAR"
                        exit 1
                esac

                LogDebug "Remote OS: [$REMOTE_OS_VAR]."
        fi
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds passed since current task execution unless $2 equals 0.
# Will stop task and log alert if $3 seconds passed since current task execution unless $3 equals 0.
function WaitForTaskCompletion
{
        soft_alert=0
	log_time=0
        SECONDS_BEGIN=$SECONDS
        while eval "$PROCESS_TEST_CMD" > /dev/null
        do
                Spinner
                EXEC_TIME=$(($SECONDS - $SECONDS_BEGIN))
                if [ $((($EXEC_TIME + 1) % $KEEP_LOGGING)) -eq 0 ]
                then
			if [ $log_time -ne $EXEC_TIME ]
			then
				log_time=$EXEC_TIME
                        	Log "Current task still running."
			fi
                fi
                if [ $EXEC_TIME -gt "$2" ]
                then
                        if [ $soft_alert -eq 0 ] && [ "$2" != 0 ]
                        then
                                LogError "Max soft execution time exceeded for task."
                                soft_alert=1
                        fi
                        if [ $EXEC_TIME -gt "$3" ] && [ "$3" != 0 ]
                        then
                                LogError "Max hard execution time exceeded for task. Stopping task execution."
                                kill -s SIGTERM $1
                                if [ $? == 0 ]
                                then
                                        LogError "Task stopped succesfully"
                                else
                                        LogError "Sending SIGTERM to proces failed. Trying the hard way."
                                        kill -9 $1
                                        if [ $? != 0 ]
                                        then
                                                LogError "Could not stop task."
                                        fi
                                fi
                                return 1
                        fi
                fi
                sleep $SLEEP_TIME
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
		return 0
	fi
	Log "Running command [$1] on local host."
	eval "$1" > $RUN_DIR/obackup_run_local_$SCRIPT_PID 2>&1 &
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $2
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Command succeded."
	else
		LogError "Command failed."
	fi

	if [ $verbose -eq 1 ] || [ $retval -ne 0 ]
	then
		Log "Command output:\n$(cat $RUN_DIR/obackup_run_local_$SCRIPT_PID)"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]
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
                return 0
        fi
	Log "Running command [$1] on remote host."
	eval "$SSH_CMD \"$1\" > $RUN_DIR/obackup_run_remote_$SCRIPT_PID 2>&1 &"
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $2
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Command succeded."
	else
		LogError "Command failed."
	fi

	if [ -f $RUN_DIR/obackup_run_remote_$SCRIPT_PID ] && ([ $verbose -eq 1 ] || $retval -ne 0 ]) 
	then
		Log "Command output:\n$(cat $RUN_DIR/obackup_run_remote_$SCRIPT_PID)"
	fi

        if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]
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
		if [ -w $LOCAL_SQL_STORAGE ]
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
			LogError "SQL storage path [$LOCAL_SQL_STORAGE] doesn't exist or cannot write to it."
		fi
	else
		LOCAL_SQL_SPACE=0
	fi

        if [ "$BACKUP_FILES" != "no" ]
        then
                if [ -w $LOCAL_FILE_STORAGE ]
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
                        LogError "File storage path [$LOCAL_FILE_STORAGE] doesn't exist or cannot write to it."
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
        if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_SYNC" != "no" ]
        then
                eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1"
                if [ $? != 0 ]
                then
                        LogError "Cannot ping $REMOTE_HOST"
                        exit 1
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
                        eval "$PING_CMD $i > /dev/null 2>&1"
                        if [ $? != 0 ]
                        then
                                Log "Cannot ping 3rd party host $i"
                        else
                                remote_3rd_party_success=1
                        fi
                done
                IFS=$OLD_IFS
                if [ $remote_3rd_party_success -ne 1 ]
                then
                        LogError "No remote 3rd party host responded to ping. No internet ?"
                        exit 1
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
		sql_cmd="$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > $RUN_DIR/obackup_dblist_$SCRIPT_PID &"
	else
		sql_cmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/obackup_dblist_$SCRIPT_PID &"
	fi

	LogDebug "$sql_cmd"
	eval "$sql_cmd 2>&1"
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

	if [ $verbose -eq 1 ]
	then
		Log "Database backup list: $DATABASES_TO_BACKUP"
		Log "Database exclude list: $DATABASES_EXCLUDED_LIST"
	fi
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
		dry_sql_cmd="$SSH_CMD mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 2>&1 > /dev/null"
		sql_cmd="$SSH_CMD mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION"
	elif [ "$REMOTE_BACKUP" == "yes" ] && [ "$COMPRESSION_REMOTE" == "yes" ]
	then
		CheckConnectivityRemoteHost
		if [ $? != 0 ]
		then
			LogError "Connectivity test failed. Stopping current task."
			exit 1
		fi
		dry_sql_cmd="$SSH_CMD \"mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS\" 2>&1 > /dev/null"
		sql_cmd="$SSH_CMD \"mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS\" > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION"
	else
		dry_sql_cmd="mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS 2>&1 > /dev/null"
		sql_cmd="mysqldump -u $SQL_USER --skip-lock-tables --single-transaction --database $1 $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > $LOCAL_SQL_STORAGE/$1.sql$COMPRESSION_EXTENSION"
	fi

	if [ $dryrun -ne 1 ]
	then
        	LogDebug "SQL_CMD: $sql_cmd"
		eval "$sql_cmd 2>&1"
	else
        	LogDebug "SQL_CMD: $dry_sql_cmd"
		eval "$dry_sql_cmd"
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
				eval "$SSH_CMD \"$COMMAND_SUDO $FIND_CMD -L $dir/ -mindepth 1 -maxdepth 1 -type d\" > $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID &"
			fi
		else
			eval "$COMMAND_SUDO $FIND_CMD -L $dir/ -mindepth 1 -maxdepth 1 -type d > $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID &"
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
		fi

		OLD_IFS=$IFS
		IFS=$' \n'
		for line in $(cat $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID)
		do
			file_exclude=0
			IFS=$PATH_SEPARATOR_CHAR
			for k in $DIRECTORIES_RECURSE_EXCLUDE_LIST
			do
				if [ "$k" == "$line" ]
				then
					file_exclude=1
				fi
			done
			IFS=$' \n'

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
		done
		Log "Listing of recursive directories succeeded for $dir"
		if [ $verbose -eq 1 ]
		then
			Log "\n$(cat $RUN_DIR/obackup_dirs_recurse_list_$SCRIPT_PID)"
		fi
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
	# Disable globbing so wildcards from exclusions don't get expanded 
	set -f
        rest="$RSYNC_EXCLUDE_PATTERN"
        while [ -n "$rest" ]
        do
                # Take the string until first occurence until $PATH_SEPARATOR_CHAR
                str=${rest%%;*}
                # Handle the last case
                if [ "$rest" = "${rest/$PATH_SEPARATOR_CHAR/}" ]
                then
                        rest=
                else
                        # Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
                        rest=${rest#*$PATH_SEPARATOR_CHAR}
                fi

                if [ "$RSYNC_EXCLUDE" == "" ]
                then
                        RSYNC_EXCLUDE="--exclude=\"$str\""
                else
                        RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$str\""
                fi
        done	
	set +f
}

function RsyncExcludeFrom
{
        if [ ! $RSYNC_EXCLUDE_FROM == "" ]
        then
                ## Check if the exclude list has a full path, and if not, add the config file path if there is one
                if [ "$(basename $RSYNC_EXCLUDE_FROM)" == "$RSYNC_EXCLUDE_FROM" ]
                then
                        RSYNC_EXCLUDE_FROM=$(dirname $ConfigFile)/$RSYNC_EXCLUDE_FROM
                fi

                if [ -e $RSYNC_EXCLUDE_FROM ]
                then
                        RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude-from=\"$RSYNC_EXCLUDE_FROM\""
                fi
        fi
}

function Rsync
{
	i="$(StripQuotes $1)"
	if [ "$LOCAL_STORAGE_KEEP_ABSOLUTE_PATHS" == "yes" ]
	then
		local_file_storage_path="$(dirname $LOCAL_FILE_STORAGE$i)"
	else
		local_file_storage_path=$LOCAL_FILE_STORAGE
	fi

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
        if [ "$2" == "no-recurse" ]
        then
		RSYNC_EXCLUDE=$RSYNC_EXCLUDE" --exclude=*/*/"
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion
                RSYNC_NO_RECURSE_ARGS=" -k"
	else
		RSYNC_NO_RECURSE_ARGS=""
        fi

	# Creating subdirectories because rsync cannot handle mkdir -p
	if [ ! -d $local_file_storage_path/$1 ]
	then
		mkdir -p "$local_file_storage_path/$1"
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
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$1\" \"$local_file_storage_path\" > $RUN_DIR/obackup_rsync_output_$SCRIPT_PID 2>&1"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$1\" \"$local_file_storage_path\" > $RUN_DIR/obackup_rsync_output_$SCRIPT_PID 2>&1"
	fi
	#### Eval is used so the full command is processed without bash adding single quotes round variables
	LogDebug "RSYNC_CMD: $rsync_cmd"

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
		Log "Beginning recursive file backup on $BACKUP_TASK"
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

        ## Also backup files at root of DIRECTORIES_RECURSE_LIST directories
        for BACKUP_TASK in $DIRECTORIES_RECURSE_LIST
        do
                BACKUP_TASK="$(StripQuotes $BACKUP_TASK)"
                Log "Beginning non recursive file backup on $BACKUP_TASK"
                SECONDS_BEGIN=$SECONDS
                Rsync $BACKUP_TASK "no-recurse" &
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
                Log "Beginning recursive file backup on $BACKUP_TASK"
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
				rm -rf "$1/$backup.obackup.$copy" &
				child_pid=$!
		                WaitForTaskCompletion $child_pid 0 0
			fi
			path="$1/$backup.obackup.$(($copy-1))"
			if [[ -f $path || -d $path ]]
			then
				mv $path "$1/$backup.obackup.$copy" &
				child_pid=$!
                                WaitForTaskCompletion $child_pid 0 0

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]
		then
			mv "$1/$backup" "$1/$backup.obackup.1" &
			child_pid=$!
                        WaitForTaskCompletion $child_pid 0 0

		elif [ "$REMOTE_BACKUP" == "yes" ]
		then
			cp -R "$1/$backup" "$1/$backup.obackup.1" &
			child_pid=$!
                        WaitForTaskCompletion $child_pid 0 0

		else
			mv "$1/$backup" "$1/$backup.obackup.1" &
			child_pid=$!
                        WaitForTaskCompletion $child_pid 0 0

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

	MAIL_ALERT_MSG="Warning: Execution of obackup instance $BACKUP_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors on $(date)."

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
			RSYNC_PATH="sudo $RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="sudo $RSYNC_EXECUTABLE"
                fi
		COMMAND_SUDO="sudo"
        else
		if [ "$RSYNC_REMOTE_PATH" != "" ]
                        then
                                RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
                        else
                                RSYNC_PATH="$RSYNC_EXECUTABLE"
                        fi
                COMMAND_SUDO=""
        fi

	## Set Rsync arguments
        RSYNC_ARGS=-rlptgoDu
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
	if [ "$COPY_SYMLINKS" != "no" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -L"
        fi
        if [ "$KEEP_DIRLINKS" != "no" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -K"
        fi
        if [ "$PRESERVE_HARDLINKS" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -H"
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
        if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
        fi

        if [ "$PARTIAL" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
                RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$PARTIAL_DIR\""
        fi

	if [ "$DELETE_VANISHED_FILES" == "yes" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" --delete"
	fi

	if [ "$DELTA_COPIES" != "no" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" --no-whole-file"
	else
		RSYNC_ARGS=$RSYNC_ARGS" --whole-file"
	fi

        if [ $stats -eq 1 ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" --stats"
        fi

	## Fix for symlink to directories on target can't get updated
	RSYNC_ARGS=$RSYNC_ARGS" --force"

        ## Set compression executable and extension
        if [ "$COMPRESSION_LEVEL" == "" ]
	then
		COMPRESSION_LEVEL=3
	fi
        if type -p xz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| xz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.xz
        elif type -p lzma > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| lzma -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.lzma
        elif type -p pigz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| pigz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        elif type -p gzip > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| gzip -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        else
                COMPRESSION_PROGRAM=
                COMPRESSION_EXTENSION=
        fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function InitLocalOSSettings
{
	## If running under Msys, some commands don't run the same way
        ## Using mingw version of find instead of windows one
        ## Getting running processes is quite different
        ## Ping command isn't the same
        if [ "$LOCAL_OS" == "msys" ]
        then
                FIND_CMD=$(dirname $BASH)/find
                ## TODO: The following command needs to be checked on msys. Does the $1 variable substitution work ?
		PROCESS_TEST_CMD='ps -a | awk "{\$1=\$1}\$1" | awk "{print \$1}" | grep $1'
                PING_CMD="ping -n 2"
        else
                FIND_CMD=find
                PROCESS_TEST_CMD='ps -p$1'
                PING_CMD="ping -c 2 -i .2"
        fi

        ## Stat command has different syntax on Linux and FreeBSD/MacOSX
        if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]
        then
                STAT_CMD="stat -f \"%Sm\""
        else
                STAT_CMD="stat --format %y"
        fi
}

function InitRemoteOSSettings
{
        ## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability
        if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -E"
        fi

        if [ "$REMOTE_OS" == "msys" ]
        then
                REMOTE_FIND_CMD=$(dirname $BASH)/find
        else
                REMOTE_FIND_CMD=find
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
		if [ "$dontgetsize" -ne 1 ] || [ "$DONT_GET_BACKUP_FILE_SIZE" == "no" ]
		then
			GetDirectoriesSize
		fi
	fi
	if [ $dryrun -ne 1 ]
	then
		CreateLocalStorageDirectories
	fi

	if [ "$dontgetsize" -ne 1  ]
	then
		CheckSpaceRequirements
	fi

	# Actual backup process
	if [ "$BACKUP_SQL" != "no" ]
	then
		if [ $dryrun -ne 1 ]
		then
			if [ "$ROTATE_BACKUPS" == "yes" ]
			then
				RotateBackups $LOCAL_SQL_STORAGE
			fi
		fi
		BackupDatabases
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
		## Add Rsync exclude patterns
	        RsyncExcludePattern
        	## Add Rsync exclude from file
        	RsyncExcludeFrom

		FilesBackup
	fi
	# Be a happy sysadmin (and drink a coffee ? Nahh... it's past midnight.)
}

function Usage
{
        echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "usage: obackup /path/to/backup.conf [--dry] [--silent] [--verbose] [--no-maxtime]"
	echo ""
	echo "--dry: will run obackup without actually doing anything, just testing"
	echo "--silent: will run obackup without any output to stdout, usefull for cron backups"
	echo "--verbose: adds command outputs"
        echo "--stats           Adds rsync transfer statistics to verbose output"
        echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      disables any soft and hard execution time checks"
	echo "--delete          Deletes files on destination that vanished on source"
	echo "--dontgetsize	Does not try to evaluate backup size"
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
dontgetsize=0
stats=0
PARTIAL=0
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
		dontgetsize=1
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
			if [ "$LOGFILE" == "" ]
			then
				if [ -w /var/log ]
				then
					LOG_FILE=/var/log/obackup_$BACKUP_ID.log
				else
					LOG_FILE=./obackup_$BACKUP_ID.log
				fi
			else
				LOG_FILE="$LOGFILE"
			fi

			GetLocalOS
			InitLocalOSSettings

			Init
			GetRemoteOS
			InitRemoteOSSettings
			DATE=$(date)
			Log "--------------------------------------------------------------------"
			Log "$DRY_WARNING $DATE - $PROGRAM v$PROGRAM_VERSION script begin."
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
	exit 1
fi
