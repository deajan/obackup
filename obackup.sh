#!/usr/bin/env bash

#TODO: missing files says Backup succeed
#TODO: ListingDatabases fail succeed
#TODO: Add .gpg extesion to RotateFiles ?

###### Remote push/pull (or local) backup script for files & databases
PROGRAM="obackup"
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.1-dev
PROGRAM_BUILD=2016111701
IS_STABLE=no

#### MINIMAL-FUNCTION-SET BEGIN ####

## FUNC_BUILD=2016111704
## BEGIN Generic bash functions written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_LOGGER_SILENT=true/false
## _LOGGER_LOGGER_VERBOSE=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

## Logger sets {ERROR|WARN}_ALERT variable when called with critical / error / warn loglevel
## When called from subprocesses, variable of main process can't be set. Status needs to be get via $RUN_DIR/$PROGRAM.Logger.{error|warn}.$SCRIPT_PID

#TODO: Rewrite Logger so we can decide what to send to stdout, stderr and logfile
#TODO: Windows checks, check sendmail & mailsend

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Environment variables that can be overriden by programs
_DRYRUN=false
_LOGGER_SILENT=false
_LOGGER_VERBOSE=false
_LOGGER_ERR_ONLY=false
_LOGGER_PREFIX="date"
if [ "$KEEP_LOGGING" == "" ]; then
        KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.05 # Tested under linux and FreeBSD bash, #TODO tests on cygwin / msys
	_LOGGER_VERBOSE=false
else
	if [ "$SLEEP_TIME" == "" ]; then # Set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
		SLEEP_TIME=.05
	fi
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

if [ "$PROGRAM" == "" ]; then
	PROGRAM="ofunctions"
fi

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE="/var/log/$PROGRAM.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM.log"
else
	LOG_FILE="./$PROGRAM.log"
fi

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi


# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {

	sleep $SLEEP_TIME
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStderr="${3:-false}"	# Log to stderr instead of stdout

	echo -e "$logValue" >> "$LOG_FILE"
	# Current log file
	echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStderr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# General log function with log levels:

# Environment variables
# _LOGGER_SILENT: Disables any output to stdout & stderr
# _LOGGER_STD_ERR: Disables any output to stdout except for ALWAYS loglevel
# _LOGGER_VERBOSE: Allows VERBOSE loglevel messages to be sent to stdout

# Loglevels
# Except for VERBOSE, all loglevels are ALWAYS sent to log file

# CRITICAL, ERROR, WARN sent to stderr, color depending on level, level also logged
# NOTICE sent to stdout
# VERBOSE sent to stdout if _LOGGER_VERBOSE = true
# ALWAYS is sent to stdout unless _LOGGER_SILENT = true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=yes
function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT isn't set in main when Logger is called from a subprocess. Need to keep this flag.
		echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.warn.$SCRIPT_PID"
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "$prefix:$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m"
		_Logger "Value was: $prefix$value"
	fi
}

# QuickLogger subfunction, can be called directly
function _QuickLogger {
	local value="${1}"
	local destination="${2}" # Destination: stdout, log, both


	if ([ "$destination" == "log" ] || [ "$destination" == "both" ]); then
		echo -e "$(date) - $value" >> "$LOG_FILE"
	elif ([ "$destination" == "stdout" ] || [ "$destination" == "both" ]); then
		echo -e "$value"
	fi
}

# Generic quick logging function
function QuickLogger {
	local value="${1}"


	if [ $_LOGGER_SILENT == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?


	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if ( [ "$self" == true ] && kill -0 $pid > /dev/null 2>&1); then
		Logger "Sending SIGTERM to process [$pid]." "DEBUG"
		kill -s TERM "$pid"
		if [ $? != 0 ]; then
			sleep 15
			Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
			kill -9 "$pid"
			if [ $? != 0 ]; then
				Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
				return 1
			fi
		else
			return 0
		fi
	else
		return 0
	fi
}

function KillAllChilds {
	local pids="${1}" # List of parent pids to kill separated by semi-colon
	local self="${2:-false}" # Should parent be killed too ?


	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid $self
		if [ $? != 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run


	local attachment
	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	# <OSYNC SPECIFIC>
	if [ "$_QUICK_SYNC" == "2" ]; then
		Logger "Current task is a quicksync task. Will not send any alert." "NOTICE"
		return 0
	fi
	# </OSYNC SPECIFIC>

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		attachment=false
	else
		attachment=true
	fi
	if [ -e "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID" ]; then
		body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID)"
	fi
	exit

	if [ $ERROR_ALERT == true ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT == true ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ $runAlert == true ]; then
		subject="Currently runing - $subject"
	else
		subject="Fnished run - $subject"
	fi

	if [ "$attachment" == true ]; then
		attachmentFile="$ALERT_LOG_FILE"
	fi

	SendEmail "$subject" "$body" "$DESTINATION_MAILS" "$attachmentFile" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$ENCRYPTION" "SMTP_USER" "$SMTP_PASSWORD"

	# Delete tmp log file
	if [ "$attachment" == true ]; then
		if [ -f "$ALERT_LOG_FILE" ]; then
			rm -f "$ALERT_LOG_FILE"
		fi
	fi
}

# Generic email sending function.
# Usage (linux / BSD), attachment is optional, can be "/path/to/my.file" or ""
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file"
# Usage (Windows, make sure you have mailsend.exe in executable path, see http://github.com/muquit/mailsend)
# attachment is optional but must be in windows format like "c:\\some\path\\my.file", or ""
# smtp_server.domain.tld is mandatory, as is smtpPort (should be 25, 465 or 587)
# encryption can be set to tls, ssl or none
# smtpUser and smtpPassword are optional
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file" "senderMail@example.com" "smtpServer.domain.tld" "smtpPort" "encryption" "smtpUser" "smtpPassword"
function SendEmail {
	local subject="${1}"
	local message="${2}"
	local destinationMails="${3}"
	local attachment="${4}"
	local senderMail="${5}"
	local smtpServer="${6}"
	local smtpPort="${7}"
	local encryption="${8}"
	local smtpUser="${9}"
	local smtpPassword="${10}"

	# CheckArguments will report a warning that can be ignored if used in Windows with paranoia debug enabled

	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	if [ ! -f "$attachment" ]; then
		attachment_command="-a $attachment"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		if type sendmail > /dev/null 2>&1; then
			if [ "$ENCRYPTION" == "tls" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -H "exec openssl s_client -quiet -tls1_2 -starttls smtp -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			elif [ "$ENCRYPTION" == "ssl" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -H "exec openssl s_client -quiet -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -S "$smtpServer:$SmtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			fi

			if [ $? != 0 ]; then
				Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
				# Don't bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Won't send any mail" "WARN"
			return 1
		fi
	fi

	if type mutt > /dev/null 2>&1 ; then
		echo "$message" | $(type -p mutt) -x -s "$subject" "$destinationMails" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $attachment"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$attachment"
		else
			attachment_command=""
		fi
		echo "$message" | $(type -p mail) $attachment_command -s "$subject" "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
			if [ $? != 0 ]; then
				Logger "Cannot send mail via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
	if type "mailsend.exe" > /dev/null 2>&1 ; then
		if [ "$senderMail" == "" ]; then
			Logger "Missing sender email." "ERROR"
			return 1
		fi
		if [ "$smtpServer" == "" ]; then
			Logger "Missing smtp port." "ERROR"
			return 1
		fi
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if [ "$encryption" != "tls" ] && [ "$encryption" != "ssl" ]  && [ "$encryption" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$encryption" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$encryption" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$smtpUser" != "" ] && [ "$smtpPassword" != "" ]; then
			auth_string="-auth -user \"$smtpUser\" -pass \"$smtpPassword\""
		fi
		$(type mailsend.exe) -f "$senderMail" -t "$destinationMails" -sub "$subject" -M "$message" -attach "$attachment" -smtp "$smtpServer" -port "$smtpPort" $encryption_string $auth_string
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it is critical that no alert can be sent
	Logger "Cannot send mail (neither mutt, mail, sendmail, sendemail, mailsend (windows) or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m"
	fi
}

function LoadConfigFile {
	local configFile="${1}"



	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$configFile"
}

function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
		return 0
	fi

	case $toggle
	in
	1)
	echo -n " \ "
	echo -ne "\r"
	toggle="2"
	;;

	2)
	echo -n " | "
	echo -ne "\r"
	toggle="3"
	;;

	3)
	echo -n " / "
	echo -ne "\r"
	toggle="4"
	;;

	*)
	echo -n " - "
	echo -ne "\r"
	toggle="1"
	;;
	esac
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION that contains list of failed pids in format pid1:result1;pid2:result2
# Warning: Don't imbricate this function into another run if you plan to use the global variable output

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local softMaxTime="${2}" # If program with pid $pid takes longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${3}" # If program with pid $pid takes longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local callerName="${4}" # Who called this function
	local counting="${5:-true}" # Count time since function has been launched if true, since script has been launched if false
	local keepLogging="${6:-0}" # Log a standby message every X seconds. Set to zero to disable logging


	local soft_alert=false # Does a soft alert need to be triggered, if yes, send an alert once
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	local retval=0 # return value of monitored pid process
	local errorcount=0 # Number of pids that finished with errors

	local pid	# Current pid working on
	local pidCount # number of given pids
	local pidState # State of the process

	local pidsArray # Array of currently running pids
	local newPidsArray # New array of currently running pids


	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	WAIT_FOR_TASK_COMPLETION=""

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		Spinner
		if [ $counting == true ]; then
			exec_time=$(($SECONDS - $seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			if [ $((($exec_time + 1) % $keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1s
					log_ttime=$exec_time
					Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ $soft_alert == true ] && [ $softMaxTime -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				soft_alert=true
				SendAlert true

			fi
			if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
				for pid in "${pidsArray[@]}"; do
					KillChilds $pid true
					if [ $? == 0 ]; then
						Logger "Task with pid [$pid] stopped successfully." "NOTICE"
					else
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				done
				SendAlert true
			fi
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					#TODO(high): have this tested on *BSD, Mac, Win & busybox.
					#TODO(high): propagate changes to ParallelExec
					#pidState=$(ps -p$pid -o state= 2 > /dev/null)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						errorcount=$((errorcount+1))
						Logger "${FUNCNAME[0]} called by [$callerName] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						if [ "$WAIT_FOR_TASK_COMPLETION" == "" ]; then
							WAIT_FOR_TASK_COMPLETION="$pid:$retval"
						else
							WAIT_FOR_TASK_COMPLETION=";$pid:$retval"
						fi
					fi
				fi
			fi
		done


		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done


	# Return exit code if only one process was monitored, else return number of errors
	if [ $pidCount -eq 1 ] && [ $errorcount -eq 0 ]; then
		return $errorcount
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
function ParallelExec {
	local numberOfProcesses="${1}" # Number of simultaneous commands to run
	local commandsArg="${2}" # Semi-colon separated list of commands, or file containing one command per line
	local readFromFile="${3:-false}" # Is commandsArg a file or a string ?
	local softMaxTime="${4:-0}"
	local hardMaxTime="${5:-0}"
	local callerName="${6}" # Who called this function
	local counting="${7:-true}" # Count time since function has been launched if true, since script has been launched if false
	local keepLogging="${8:-0}" # Log a standby message every X seconds. Set to zero to disable logging


	local commandCount
	local command
	local pid
	local counter=0
	local commandsArray
	local pidsArray
	local newPidsArray
	local retval
	local errorCount=0
	local pidState
	local commandsArrayPid


	if [ $readFromFile == true ];then
		if [ -f "$commandsArg" ]; then
			commandCount=$(wc -l < "$commandsArg")
		else
			commandCount=0
		fi
	else
		IFS=';' read -r -a commandsArray <<< "$commandsArg"
		commandCount=${#commandsArray[@]}
	fi

	Logger "Runnning $commandCount commands in $numberOfProcesses simultaneous processes." "DEBUG"

	while [ $counter -lt "$commandCount" ] || [ ${#pidsArray[@]} -gt 0 ]; do

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				#TODO: Checked on FreeBSD 10, also check on Win
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
			pid=$!
			pidsArray+=($pid)
			commandsArrayPid[$pid]="$command"
			counter=$((counter+1))
		done


		newPidsArray=()
		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
				if kill -0 $pid > /dev/null 2>&1; then
					#pidState=$(ps -p$pid -o state= 2 > /dev/null)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "Command [${commandsArrayPid[$pid]}] failed with exit code [$retval]." "ERROR"
						errorCount=$((errorCount+1))
					fi
				fi
			fi
		done

		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done

	return $errorCount
}

function CleanUp {

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.tmp"
	fi
}

# obsolete, use StripQuotes
function SedStripQuotes {
	echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

# Usage: var=$(StripSingleQuotes "$var")
function StripSingleQuotes {
	local string="${1}"

	string="${string/#\'/}" # Remove singlequote if it begins string
	string="${string/%\'/}" # Remove singlequote if it ends string
	echo "$string"
}

# Usage: var=$(StripDoubleQuotes "$var")
function StripDoubleQuotes {
	local string="${1}"

	string="${string/#\"/}"
	string="${string/%\"/}"
	echo "$string"
}

function StripQuotes {
	local string="${1}"

	echo "$(StripSingleQuotes $(StripDoubleQuotes $string))"
}

# Usage var=$(EscapeSpaces "$var") or var="$(EscapeSpaces "$var")"
function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped

	echo "${string// /\\ }"
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	local re="^-?[0-9]+([.][0-9]+)?$"

	if [[ $value =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

# Usage [ $(IsNumeric $var) -eq 1 ]
function IsNumeric {
	local value="${1}"

	if [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

function IsInteger {
	local value="${1}"

	if [[ $value =~ ^[0-9]+$ ]]; then
		echo 1
	else
		echo 0
	fi
}

# Converts human readable sizes into integer kilobyte sizes
# Usage numericSize="$(HumanToNumeric $humanSize)"
function HumanToNumeric {
	local value="${1}"

	local notation
	local suffix
	local suffixPresent
	local multiplier

	notation=(K M G T P E)
	for suffix in "${notation[@]}"; do
		multiplier=$((multiplier+1))
		if [[ "$value" == *"$suffix"* ]]; then
			suffixPresent=$suffix
			break;
		fi
	done

	if [ "$suffixPresent" != "" ]; then
		value=${value%$suffix*}
		value=${value%.*}
		# /1024 since we convert to kilobytes instead of bytes
		value=$((value*(1024**multiplier/1024)))
	else
		value=${value%.*}
	fi

	echo $value
}

## from https://gist.github.com/cdown/1163649
function urlEncode {
	local length="${#1}"

	local LANG=C
	for (( i = 0; i < length; i++ )); do
		local c="${1:i:1}"
		case $c in
			[a-zA-Z0-9.~_-])
			printf "$c"
			;;
			*)
			printf '%%%02X' "'$c"
			;;
		esac
	done
}

function urlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: arrayContains "needle" "${haystack[@]}"
arrayContains () {
	local e

	if [ "$2" == "" ]; then
		echo 0 && return 0
	fi

	for e in "${@:2}"; do
		[[ "$e" == "$1" ]] && echo 1 && return 1
	done
	echo 0 && return 0
}

function GetLocalOS {

	local localOsVar

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		localOsVar="$(uname -spio 2>&1)"
		if [ $? != 0 ]; then
			localOsVar="$(uname -v 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname)"
			fi
		fi
	fi

	case $localOsVar in
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"CYGWIN"*)
		LOCAL_OS="msys"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BUSYBOX"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#TODO(doc): Undocumented option
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$localOsVar]." "DEBUG"
}

#### MINIMAL-FUNCTION-SET END ####

function GetRemoteOS {

	local remoteOsVar

$SSH_CMD bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1

function GetOs {
	local localOsVar

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		localOsVar="$(uname -spio 2>&1)"
		if [ $? != 0 ]; then
			localOsVar="$(uname -v 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname)"
			fi
		fi
	fi

	echo "$localOsVar"
}

GetOs

ENDSSH

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		remoteOsVar=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID")
		case $remoteOsVar in
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*|*"CYGWIN"*)
			REMOTE_OS="msys"
			;;
			*"Darwin"*)
			REMOTE_OS="MacOSX"
			;;
			*"BusyBox"*)
			REMOTE_OS="BUSYBOX"
			;;
			*"ssh"*|*"SSH"*)
			Logger "Cannot connect to remote system." "CRITICAL"
			exit 1
			;;
			*)
			if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented debug only setting
				Logger "Running on unknown remote OS [$remoteOsVar]." "WARN"
				return
			fi
			Logger "Running on remote OS failed. Please report to the author if the OS is not supported." "CRITICAL"
			Logger "Remote OS said:\n$remoteOsVar" "CRITICAL"
			exit 1
		esac
		Logger "Remote OS: [$remoteOsVar]." "DEBUG"
	else
		Logger "Cannot get Remote OS" "CRITICAL"
	fi
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hardMaxTime="${2}" # Max time to wait for command to compleet

	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
	WaitForTaskCompletion $! 0 $hardMaxTime ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand {
	local command="${1}" # Command to run
	local hardMaxTime="${2}" # Max time to wait for command to compleet

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "$command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hardMaxTime ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ] && ([ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {

	local pids

	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE &
		pids="$!"
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE &
		pids="$pids;$!"
	fi
	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

function RunAfterHook {

	local pids

	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER &
		pids="$!"
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER &
		pids="$pids;$!"
	fi
	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

function CheckConnectivityRemoteHost {

	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 60 180 ${FUNCNAME[0]} true $KEEP_LOGGING
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {

	local remote3rdPartySuccess
	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 180 360 ${FUNCNAME[0]} true $KEEP_LOGGING
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot ping 3rd party host [$i]. Return code [$retval]." "NOTICE"
				else
					remote3rdPartySuccess=true
				fi
			done

			if [ $remote3rdPartySuccess == false ]; then
				Logger "No remote 3rd party host responded to ping. No internet ?" "WARN"
				return 1
			else
				return 0
			fi
		fi
	fi
}

#__BEGIN_WITH_PARANOIA_DEBUG
#__END_WITH_PARANOIA_DEBUG

function RsyncPatternsAdd {
	local patternType="${1}"	# exclude or include
	local pattern="${2}"

	local rest

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str=${rest%%;*} #TODO: replace ; with $PATH_SEPARATOR_CHAR
		# Handle the last case
		if [ "$rest" = "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest=${rest#*$PATH_SEPARATOR_CHAR}
		fi
			if [ "$RSYNC_PATTERNS" == "" ]; then
			RSYNC_PATTERNS="--"$patternType"=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"=\"$str\""
		fi
	done
	set +f
}

function RsyncPatternsFromAdd {
	local patternType="${1}"
	local patternFrom="${2}"

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename $patternFrom)" == "$patternFrom" ]; then
		patternFrom="$(dirname $CONFIG_FILE)/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"-from=\"$patternFrom\""
	fi
}

function RsyncPatterns {

       if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
		if [ "$RSYNC_EXCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
		fi
		if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
		fi
		if [ "$RSYNC_INCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
		fi
		if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
		fi
	# Use default include first for quicksync runs
	elif [ "$RSYNC_PATTERN_FIRST" == "include" ] || [ "$_QUICK_SYNC" == "2" ]; then
		if [ "$RSYNC_INCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
		fi
		if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
		fi
		if [ "$RSYNC_EXCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
		fi
		if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
		fi
	else
		Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
	fi
}

function PreInit {

	local compressionString

	## SSH compression
	if [ "$SSH_COMPRESSION" != "no" ]; then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Ignore SSH known host verification
	if [ "$SSH_IGNORE_KNOWN_HOSTS" == "yes" ]; then
		SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
	fi

	## Support for older config files without RSYNC_EXECUTABLE option
	if [ "$RSYNC_EXECUTABLE" == "" ]; then
		RSYNC_EXECUTABLE=rsync
	fi

	## Sudo execution option
	if [ "$SUDO_EXEC" == "yes" ]; then
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="sudo $RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="sudo $RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO="sudo"
	else
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="$RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO=""
	fi

	 ## Set rsync default arguments
	RSYNC_ARGS="-rltD"
	if [ "$_DRYRUN" == true ]; then
		RSYNC_DRY_ARG="-n"
		DRY_WARNING="/!\ DRY RUN "
	else
		RSYNC_DRY_ARG=""
	fi

	RSYNC_ATTR_ARGS=""
	if [ "$PRESERVE_PERMISSIONS" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -p"
	fi
	if [ "$PRESERVE_OWNER" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -o"
	fi
	if [ "$PRESERVE_GROUP" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -g"
	fi
	if [ "$PRESERVE_ACL" == "yes" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
	fi
	if [ "$PRESERVE_XATTR" == "yes" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
	fi
	if [ "$RSYNC_COMPRESS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -z"
	fi
	if [ "$COPY_SYMLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -K"
	fi
	if [ "$PRESERVE_HARDLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -H"
	fi
	if [ "$CHECKSUM" == "yes" ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --checksum"
	fi
	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
	fi

	if [ "$PARTIAL" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
		RSYNC_PARTIAL_EXCLUDE="--exclude=\"$PARTIAL_DIR\""
	fi

	if [ "$DELTA_COPIES" != "no" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --no-whole-file"
	else
		RSYNC_ARGS=$RSYNC_ARGS" --whole-file"
	fi

	 ## Set compression executable and extension
	if [ "$(IsInteger $COMPRESSION_LEVEL)" -eq 0 ]; then
		COMPRESSION_LEVEL=3
	fi

	## Busybox fix (Termux xz command doesn't support compression at all)
	if [ "$LOCAL_OS" == "BUSYBOX" ] || [ "$REMOTE_OS" == "BUSYBOX" ]; then
		compressionString=""
		if type gzip > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| gzip -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
		else
			COMPRESSION_PROGRAM=
			COMPRESSION_EXTENSION=
		fi
	else
		compressionString=" -$COMPRESSION_LEVEL"

		if type xz > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| xz -c$compressionString"
			COMPRESSION_EXTENSION=.xz
		elif type lzma > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| lzma -c$compressionString"
			COMPRESSION_EXTENSION=.lzma
		elif type pigz > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| pigz -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
			COMPRESSION_OPTIONS=--rsyncable
		elif type gzip > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| gzip -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
			COMPRESSION_OPTIONS=--rsyncable
		else
			COMPRESSION_PROGRAM=
			COMPRESSION_EXTENSION=
		fi
	fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function PostInit {

	# Define remote commands
	if [ -f "$SSH_RSA_PRIVATE_KEY" ]; then
		SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
	elif [ -f "$SSH_PASSWORD_FILE" ]; then
		SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p scp) $SSH_COMP -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP $SSH_OPTS -p $REMOTE_PORT"
	else
		SSH_PASSWORD=""
		SSH_CMD=""
		SCP_CMD=""
		RSYNC_SSH_CMD=""
	fi
}

function InitLocalOSSettings {

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ]; then
		FIND_CMD=$(dirname $BASH)/find
		PING_CMD='$SYSTEMROOT\system32\ping -n 2'
	else
		FIND_CMD=find
		PING_CMD="ping -c 2 -i .2"
	fi

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		PROCESS_STATE_CMD="echo none"
	else
		PROCESS_STATE_CMD='ps -p$pid -o state= 2 > /dev/null'
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		# Tested on BSD and Mac
		STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
	else
		# Tested on GNU stat and busybox
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
	fi
}

function InitRemoteOSSettings {

	## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
	if [ "$PRESERVE_EXECUTABILITY" != "no" ];then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -E"
		fi
	fi

	if [ "$REMOTE_OS" == "msys" ]; then
		REMOTE_FIND_CMD=$(dirname $BASH)/find
	else
		REMOTE_FIND_CMD=find
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		REMOTE_STAT_CMD="stat -f \"%Sm\""
		REMOTE_STAT_CTIME_MTIME_CMD="stat -f \\\"%N;%c;%m\\\""
	else
		REMOTE_STAT_CMD="stat --format %y"
		REMOTE_STAT_CTIME_MTIME_CMD="stat -c \\\"%n;%Z;%Y\\\""
	fi

}

## IFS debug function
function PrintIFS {
	printf "IFS is: %q" "$IFS"
}

# Process debugging
# Recursive function to get all parents from a pid
function ParentPid {
	local pid="${1}" # Pid to analyse
	local parent

	parent=$(ps -p $pid -o ppid=)
	echo "$pid is a child of $parent"
	if [ $parent -gt 0 ]; then
		ParentPid $parent
	fi
}

## END Generic functions

_LOGGER_PREFIX="time"

## Working directory for partial downloads
PARTIAL_DIR=".obackup_workdir_partial"

## File extension for encrypted files
CRYPT_FILE_EXTENSION=".obackup.gpg"

# List of runtime created global variables
# $SQL_DISK_SPACE, disk space available on target for sql backups
# $FILE_DISK_SPACE, disk space available on target for file backups
# $SQL_BACKUP_TASKS, list of all databases to backup, space separated
# $SQL_EXCLUDED_TASKS, list of all database to exclude from backup, space separated
# $FILE_BACKUP_TASKS list of directories to backup, found in config file
# $FILE_RECURSIVE_BACKUP_TASKS, list of directories to backup, computed from config file recursive list
# $FILE_RECURSIVE_EXCLUDED_TASKS, list of all directories excluded from recursive list
# $FILE_SIZE_LIST_LOCAL, list of all directories to include in GetDirectoriesSize, enclosed by escaped doublequotes for local command
# $FILE_SIZE_LIST_REMOTE, list of all directories to include in GetDirectoriesSize, enclosed by escaped singlequotes for remote command

CAN_BACKUP_SQL=true
CAN_BACKUP_FILES=true

function TrapStop {
	Logger "/!\ Manual exit of backup script. Backups may be in inconsistent state." "WARN"
	exit 2
}

function TrapQuit {
	local exitcode

	if [ $ERROR_ALERT == true ]; then
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with errors." "ERROR"
		SendAlert
		CleanUp
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with warnings." "WARN"
		SendAlert
		CleanUp
		exitcode=2
	else
		RunAfterHook
		Logger "$PROGRAM finshed without errors." "NOTICE"
		CleanUp
		exitcode=0
	fi

	if [ -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID" ]; then
		rm -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID"
	fi

	KillChilds $$ > /dev/null 2>&1
	exit $exitcode
}

function CheckEnvironment {

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start backup." "CRITICAL"
			exit 1
		fi

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

		if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
			Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
			exit 1
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

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SUDO_EXEC DATABASES_ALL PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
	for i in "${yes_no_vars[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value [$$i] defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$BACKUP_TYPE" != "local" ] && [ "$BACKUP_TYPE" != "pull" ] && [ "$BACKUP_TYPE" != "push" ]; then
		Logger "Bogus BACKUP_TYPE value in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(BACKUP_SIZE_MINIMUM SQL_WARN_MIN_SPACE FILE_WARN_MIN_SPACE SOFT_MAX_EXEC_TIME_DB_TASK HARD_MAX_EXEC_TIME_DB_TASK COMPRESSION_LEVEL SOFT_MAX_EXEC_TIME_FILE_TASK HARD_MAX_EXEC_TIME_FILE_TASK BANDWIDTH SOFT_MAX_EXEC_TIME_TOTAL HARD_MAX_EXEC_TIME_TOTAL ROTATE_SQL_COPIES ROTATE_FILE_COPIES KEEP_LOGGING MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [$$i] defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$FILE_BACKUP" == "yes" ]; then
		if [ "$DIRECTORY_LIST" == "" ] && [ "$RECURSIVE_DIRECTORY_LIST" == "" ]; then
			Logger "No directories specified in config file, no files to backup." "ERROR"
			CAN_BACKUP_FILES=false
		fi
	fi

	#TODO-v2.1(ongoing WIP): Add runtime variable tests (RSYNC_ARGS etc)
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

	local sqlCmd=

	sqlCmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	Logger "cmd: $sqlCmd" "DEBUG"
	eval "$sqlCmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? -eq 0 ]; then
		Logger "Listing databases succeeded." "NOTICE"
	else
		Logger "Listing databases failed." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		fi
		return 1
	fi

}

function _ListDatabasesRemote {

	local sqlCmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	sqlCmd="$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\" 2>&1"
	Logger "cmd: $sqlCmd" "DEBUG"
	eval "$sqlCmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? -eq 0 ]; then
		Logger "Listing databases succeeded." "NOTICE"
	else
		Logger "Listing databases failed." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		fi
		return 1
	fi
}

function ListDatabases {

	local outputFile	# Return of subfunction
	local dbName
	local dbSize
	local dbBackup

	local dbArray

	if [ $CAN_BACKUP_SQL == false ]; then
		Logger "Cannot list databases." "ERROR"
		return 1
	fi

	Logger "Listing databases." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		_ListDatabasesLocal
		if [ $? != 0 ]; then
			outputFile=""
		else
			outputFile="$RUN_DIR/$PROGRAM._ListDatabasesLocal.$SCRIPT_PID"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_ListDatabasesRemote
		if [ $? != 0 ]; then
			outputFile=""
		else
			outputFile="$RUN_DIR/$PROGRAM._ListDatabasesRemote.$SCRIPT_PID"
		fi
	fi

	if [ -f "$outputFile" ] && [ $CAN_BACKUP_SQL == true ]; then
		while read -r line; do
			while read -r name size; do dbName=$name; dbSize=$size; done <<< "$line"

			if [ "$DATABASES_ALL" == "yes" ]; then
				dbBackup=1
				IFS=$PATH_SEPARATOR_CHAR read -r -a dbArray <<< "$DATABASES_ALL_EXCLUDE_LIST"
				for j in "${dbArray[@]}"; do
					if [ "$dbName" == "$j" ]; then
						dbBackup=0
					fi
				done
			else
				dbBackup=0
				IFS=$PATH_SEPARATOR_CHAR read -r -a dbArray <<< "$DATABASES_LIST"
				for j in "${dbArray[@]}"; do
					if [ "$dbName" == "$j" ]; then
						dbBackup=1
					fi
				done
			fi

			if [ $dbBackup -eq 1 ]; then
				if [ "$SQL_BACKUP_TASKS" != "" ]; then
					SQL_BACKUP_TASKS="$SQL_BACKUP_TASKS $dbName"
				else
				SQL_BACKUP_TASKS="$dbName"
				fi
				TOTAL_DATABASES_SIZE=$((TOTAL_DATABASES_SIZE+$dbSize))
			else
				SQL_EXCLUDED_TASKS="$SQL_EXCLUDED_TASKS $dbName"
			fi
		done < "$outputFile"

		Logger "Database backup list: $SQL_BACKUP_TASKS" "DEBUG"
		Logger "Database exclude list: $SQL_EXCLUDED_TASKS" "DEBUG"
	else
		Logger "Will not execute database backup." "ERROR"
		CAN_BACKUP_SQL=false
	fi
}

function _ListRecursiveBackupDirectoriesLocal {

	local cmd
	local directories
	local directory
	local retval

	IFS=$PATH_SEPARATOR_CHAR read -r -a directories <<< "$RECURSIVE_DIRECTORY_LIST"
	for directory in "${directories[@]}"; do
		# No sudo here, assuming you should have all necessary rights for local checks
		cmd="$FIND_CMD -L $directory/ -mindepth 1 -maxdepth 1 -type d >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
		if  [ $? != 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID ]; then
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID ]; then
				Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
			fi
			retval=1
		else
			retval=0
		fi
	done
	return $retval
}

function _ListRecursiveBackupDirectoriesRemote {

	local cmd
	local directories
	local directory
	local retval

	IFS=$PATH_SEPARATOR_CHAR read -r -a directories <<< "$RECURSIVE_DIRECTORY_LIST"
	for directory in "${directories[@]}"; do
		#TODO(med): Uses local home directory for remote lookup...
		cmd=$SSH_CMD' "'$COMMAND_SUDO' '$REMOTE_FIND_CMD' -L '$directory'/ -mindepth 1 -maxdepth 1 -type d" >> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
		if  [ $? != 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID ]; then
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID ]; then
				Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
			fi
			retval=1
		else
			retval=0
		fi
	done
	return $retval
}

function ListRecursiveBackupDirectories {

	local output_file
	local file_exclude
	local excluded
	local fileArray

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
					FILE_SIZE_LIST_LOCAL="\"$line\""
					FILE_SIZE_LIST_REMOTE="\'$line\'"
					FILE_RECURSIVE_BACKUP_TASKS="$line"
				else
					FILE_SIZE_LIST_LOCAL="$FILE_SIZE_LIST_LOCAL \"$line\""
					FILE_SIZE_LIST_REMOTE="$FILE_SIZE_LIST_REMOTE \'$line\'"
					FILE_RECURSIVE_BACKUP_TASKS="$FILE_RECURSIVE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$line"
				fi
			else
				FILE_RECURSIVE_EXCLUDED_TASKS="$FILE_RECURSIVE_EXCLUDED_TASKS$PATH_SEPARATOR_CHAR$line"
			fi
		done < "$output_file"
	fi

	IFS=$PATH_SEPARATOR_CHAR read -r -a fileArray <<< "$DIRECTORY_LIST"
	for directory in "${fileArray[@]}"; do
		if [ "$FILE_SIZE_LIST_LOCAL" == "" ]; then
			FILE_SIZE_LIST_LOCAL="\"$directory\""
			FILE_SIZE_LIST_REMOTE="\'$directory\'"
		else
			FILE_SIZE_LIST_LOCAL="$FILE_SIZE_LIST_LOCAL \"$directory\""
			FILE_SIZE_LIST_REMOTE="$FILE_SIZE_LIST_REMOTE \'$directory\'"
		fi

		if [ "$FILE_BACKUP_TASKS" == "" ]; then
			FILE_BACKUP_TASKS="$directory"
		else
			FILE_BACKUP_TASKS="$FILE_BACKUP_TASKS$PATH_SEPARATOR_CHAR$directory"
		fi
	done
}

function _GetDirectoriesSizeLocal {
	local dir_list="${1}"

	local cmd

	# No sudo here, assuming you should have all the necessary rights
	# This is not pretty, but works with all supported systems
	cmd="du -cs $dir_list | tail -n1 | cut -f1 > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
	if  [ $? != 0 ] || [ -s $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID ]; then
		Logger "Could not get files size for some or all directories." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
		fi
	else
		Logger "File size fetched successfully." "NOTICE"
	fi

	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)"
		if [ $(IsInteger $TOTAL_FILES_SIZE) -eq 0 ]; then
			TOTAL_FILES_SIZE="$(HumanToNumeric $TOTAL_FILES_SIZE)"
		fi
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function _GetDirectoriesSizeRemote {
	local dir_list="${1}"

	local cmd

	# Error output is different from stdout because not all files in list may fail at once
	cmd=$SSH_CMD' '$COMMAND_SUDO' du -cs '$dir_list' | tail -n1 | cut -f1 > '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
	if  [ $? != 0 ] || [ -s $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID ]; then
		Logger "Could not get files size for some or all directories." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
			Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
		fi
	else
		Logger "File size fetched successfully." "NOTICE"
	fi
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		TOTAL_FILES_SIZE="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)"
		if [ $(IsInteger $TOTAL_FILES_SIZE) -eq 0 ]; then
			TOTAL_FILES_SIZE="$(HumanToNumeric $TOTAL_FILES_SIZE)"
		fi
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function GetDirectoriesSize {

	Logger "Getting files size" "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$FILE_BACKUP" != "no" ]; then
			_GetDirectoriesSizeLocal "$FILE_SIZE_LIST_LOCAL"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$FILE_BACKUP" != "no" ]; then
			_GetDirectoriesSizeRemote "$FILE_SIZE_LIST_REMOTE"
		fi
	fi
}

function _CreateDirectoryLocal {
	local dir_to_create="${1}"

	if [ ! -d "$dir_to_create" ]; then
		# No sudo, you should have all necessary rights
		mkdir -p "$dir_to_create" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create directory [$dir_to_create]" "CRITICAL"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID ]; then
				Logger "Command output: $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			fi
			return 1
		fi
	fi
}

function _CreateDirectoryRemote {
	local dir_to_create="${1}"

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	cmd=$SSH_CMD' "if ! [ -d \"'$dir_to_create'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$dir_to_create'\"; fi" > '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? != 0 ]; then
		Logger "Cannot create remote directory [$dir_to_create]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		return 1
	fi
}

function CreateStorageDirectories {

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$FILE_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == "yes" ]; then
			_CreateDirectoryLocal "$CRYPT_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$FILE_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == "yes" ]; then
			_CreateDirectoryLocal "$CRYPT_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
	fi
}

function GetDiskSpaceLocal {
	# GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	# GLOBAL VARIABLE DRIVE to pass variable to parent function
	local path_to_check="${1}"

	if [ -d "$path_to_check" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		df "$path_to_check" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			DISK_SPACE=0
			Logger "Cannot get disk space in [$path_to_check] on local system." "ERROR"
			Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		else
			DISK_SPACE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" | awk '{print $4}')
			DRIVE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" | awk '{print $1}')
			if [ $(IsInteger $DISK_SPACE) -eq 0 ]; then
				DISK_SPACE="$(HumanToNumeric $DISK_SPACE)"
			fi
		fi
	else
		Logger "Storage path [$path_to_check] does not exist." "CRITICAL"
		return 1
	fi
}

function GetDiskSpaceRemote {
	# USE GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	local path_to_check="${1}"

	local cmd

	cmd=$SSH_CMD' "if [ -d \"'$path_to_check'\" ]; then '$COMMAND_SUDO' df \"'$path_to_check'\"; else exit 1; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? != 0 ]; then
		DISK_SPACE=0
		Logger "Cannot get disk space in [$path_to_check] on remote system." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		return 1
	else
		DISK_SPACE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" | awk '{print $4}')
		DRIVE=$(tail -1 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" | awk '{print $1}')
		if [ $(IsInteger $DISK_SPACE) -eq 0 ]; then
			DISK_SPACE="$(HumanToNumeric $DISK_SPACE)"
		fi
	fi
}

function CheckDiskSpace {
	# USE OF GLOBAL VARIABLES TOTAL_DATABASES_SIZE, TOTAL_FILES_SIZE, BACKUP_SIZE_MINIMUM, STORAGE_WARN_SIZE, STORAGE_SPACE


	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$SQL_STORAGE"
			if [ $? != 0 ]; then
				SQL_DISK_SPACE=0
				CAN_BACKUP_SQL=false
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			GetDiskSpaceLocal "$FILE_STORAGE"
			if [ $? != 0 ]; then
				FILE_DISK_SPACE=0
				CAN_BACKUP_FILES=false
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
		if [ "$ENCRYPTION" != "no" ]; then
			GetDiskSpaceLocal "$CRYPT_STORAGE"
			if [ $? != 0 ]; then
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
		if [ "$ENCRYPTION" != "no" ]; then
			GetDiskSpaceLocal "$CRYPT_STORAGE"
			if [ $? != 0 ]; then
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

	if [ $BACKUP_SIZE_MINIMUM -gt $(($TOTAL_DATABASES_SIZE+$TOTAL_FILES_SIZE)) ] && [ "$GET_BACKUP_SIZE" != "no" ]; then
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


	if [ $encrypt == true ]; then
		encryptOptions="| $CRYPT_TOOL --encrypt --recipient=\"$GPG_RECIPIENT\""
		encryptExtension="$CRYPT_FILE_EXTENSION"
	fi

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > $SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"

	if [ $_DRYRUN == false ]; then
		Logger "cmd: $sqlCmd" "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "cmd: $drySqlCmd" "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
	fi
	return $retval
}

function _BackupDatabaseLocalToRemote {
	local database="${1}" # Database to backup
	local exportOptions="${2}" # export options
	local encrypt="${3:-false}" # Does the file need to be encrypted


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

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions | $SSH_CMD '$COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension\" > /dev/null' 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"

	if [ $_DRYRUN == false ]; then
		Logger "cmd: $sqlCmd" "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "cmd: $drySqlCmd" "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
	fi
	return $retval
}

function _BackupDatabaseRemoteToLocal {
	local database="${1}" # Database to backup
	local exportOptions="${2}" # export options
	local encrypt="${3:-false}" # Does the file need to be encrypted ?


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

	local drySqlCmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID'"'
	local sqlCmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension'" 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID'"'

	if [ $_DRYRUN == false ]; then
		Logger "cmd: $sqlCmd" "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "cmd: $drySqlCmd" "DEBUG"
		eval "$drySqlCmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
		# Dirty fix for mysqldump return code not honored
		retval=1
	fi
	return $retval
}

function BackupDatabase {
	local database="${1}"

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

	local database

	for database in $SQL_BACKUP_TASKS
	do
		BackupDatabase $database
		CheckTotalExecutionTime
	done
}

#TODO: exclusions don't work for encrypted files
#TODO: add ParallelExec here ?
function EncryptFiles {
	local filePath="${1}"	# Path of files to encrypt
	local destPath="${2}"    # Path to store encrypted files
	local recipient="${3}"  # GPG recipient
	local recursive="${4:-true}" # Is recursive ?
	local keepFullPath="${5:-false}" # Should destpath become destpath + sourcepath ?


	local successCounter=0
	local errorCounter=0
	local cryptFileExtension="$CRYPT_FILE_EXTENSION"
	local recursiveArgs=""

	if [ ! -w "$destPath" ]; then
		Logger "Cannot write to crypt storage path [$destPath]." "ERROR"
		return 1
	fi

	if [ $recursive == false ]; then
		recursiveArgs="-mindepth 1 -maxdepth 1"
	fi

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
		$CRYPT_TOOL --batch --yes --out "$path/$file$cryptFileExtension" --recipient="$recipient" --encrypt "$sourceFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot encrypt [$sourceFile]." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "DEBUG"
			errorCounter=$((errorCounter+1))
		else
			successCounter=$((successCounter+1))
		fi
	done < <(find "$filePath" $recursiveArgs -type f ! -name "*$cryptFileExtension" -print0)
	Logger "Encrypted [$successCounter] files successfully." "NOTICE"
	if [ $errorCounter -gt 0 ]; then
		Logger "Failed to encrypt [$errorCounter] files." "CRITICAL"
	fi
	return $errorCounter
}

function DecryptFiles {
	local filePath="${1}"	 # Path to files to decrypt
	local passphraseFile="${2}"  # Passphrase file to decrypt files
	local passphrase="${3}"	# Passphrase to decrypt files


	local options
	local secret
	local successCounter=0
	local errorCounter=0
	local cryptFileExtension="$CRYPT_FILE_EXTENSION"

	if [ ! -w "$filePath" ]; then
		Logger "Directory [$filePath] is not writable. Cannot decrypt files." "CRITICAL"
		exit 1
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
		$CRYPT_TOOL $options --out "${encryptedFile%%$cryptFileExtension}" $secret --decrypt "$encryptedFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot decrypt [$encryptedFile]." "ERROR"
			Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "DEBUG"
			errorCounter=$((errorCounter+1))
		else
			successCounter=$((successCounter+1))
			rm -f "$encryptedFile"
			if [ $? != 0 ]; then
				Logger "Cannot delete original file [$encryptedFile] after decryption." "ERROR"
			fi
		fi
	done < <(find "$filePath" -type f -name "*$cryptFileExtension" -print0)
	Logger "Decrypted [$successCounter] files successfully." "NOTICE"
	if [ $errorCounter -gt 0 ]; then
		Logger "Failed to decrypt [$errorCounter] files." "CRITICAL"
	fi
	return $errorCounter
}

function Rsync {
	local backupDirectory="${1}"	# Which directory to backup
	local recursive="${2:-true}"	# Backup only files at toplevel of directory


	local fileStoragePath
	local withoutCryptPath
	local rsyncCmd
	local retval

	if [ "$KEEP_ABSOLUTE_PATHS" != "no" ]; then
		if [ "$ENCRYPTION" == "yes" ]; then
			withoutCryptPath="${backupDirectory#$CRYPT_STORAGE}"
			fileStoragePath=$(dirname "$FILE_STORAGE/${withoutCryptPath#/}")
		else
			fileStoragePath=$(dirname "$FILE_STORAGE/${backupDirectory#/}")
		fi
	else
		fileStoragePath="$FILE_STORAGE"
	fi

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
	if [ $recursive == false ]; then
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion, and excludes subdirectories
		RSYNC_NO_RECURSE_ARGS=" -k  --exclude=*/*/"
	else
		RSYNC_NO_RECURSE_ARGS=""
	fi

	# Creating subdirectories because rsync cannot handle multiple subdirectory creation
	if [ "$BACKUP_TYPE" == "local" ]; then
		_CreateDirectoryLocal "$fileStoragePath"
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$backupDirectory\" \"$fileStoragePath\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_CreateDirectoryLocal "$fileStoragePath"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		backupDirectory=$(EscapeSpaces "$backupDirectory")
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$backupDirectory\" \"$fileStoragePath\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		fileStoragePath=$(EscapeSpaces "$fileStoragePath")
		_CreateDirectoryRemote "$fileStoragePath"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$backupDirectory\" \"$REMOTE_USER@$REMOTE_HOST:$fileStoragePath\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	fi

	Logger "cmd: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ $retval != 0 ]; then
		Logger "Failed to backup [$backupDirectory] to [$fileStoragePath]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi

	return $retval
}

function FilesBackup {

	local backupTask
	local backupTasks

	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$FILE_BACKUP_TASKS"
	for backupTask in "${backupTasks[@]}"; do
		Logger "Beginning file backup of [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? == 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" true
			if [ $? == 0 ]; then
				EncryptFiles "$FILE_STORAGE" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true false
			fi
		else
			Rsync "$backupTask" true
		fi
		CheckTotalExecutionTime
	done

	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$RECURSIVE_DIRECTORY_LIST"
	for backupTask in "${backupTasks[@]}"; do
		Logger "Beginning non recursive file backup of [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" false true
			if [ $? == 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" false true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" false
			if [ $? == 0 ]; then
				EncryptFiles "$FILE_STORAGE" "$CRYPT_STORAGE" "$GPG_RECIPIENT" false false
			fi
		else
			Rsync "$backupTask" false
		fi
		CheckTotalExecutionTime
	done

	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$FILE_RECURSIVE_BACKUP_TASKS"
	for backupTask in "${backupTasks[@]}"; do
	# Backup sub directories of recursive directories
		Logger "Beginning recursive file backup of [$backupTask]." "NOTICE"
		if [ "$ENCRYPTION" == "yes" ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? == 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" true true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == "yes" ] && [ "$BACKUP_TYPE" == "pull" ]; then
			Rsync "$backupTask" true
			if [ $? == 0 ]; then
				EncryptFiles "$FILE_STORAGE" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true false
			fi
		else
			Rsync "$backupTask" true
		fi
		CheckTotalExecutionTime
	done
}

function CheckTotalExecutionTime {

	#### Check if max execution time of whole script as been reached
	if [ $SECONDS -gt $SOFT_MAX_EXEC_TIME_TOTAL ]; then
		Logger "Max soft execution time of the whole backup exceeded." "ERROR"
		WARN_ALERT=1
		SendAlert true
		if [ $SECONDS -gt $HARD_MAX_EXEC_TIME_TOTAL ] && [ $HARD_MAX_EXEC_TIME_TOTAL -ne 0 ]; then
			Logger "Max hard execution time of the whole backup exceeded, stopping backup process." "CRITICAL"
			exit 1
		fi
	fi
}

function _RotateBackupsLocal {
	local backup_path="${1}"
	local rotate_copies="${2}"

	local backup
	local copy
	local cmd
	local path

	#TODO: Replace this -name with regex .*$PROGRAM\.[1-9][0-9]+
	find "$backup_path" -mindepth 1 -maxdepth 1 ! -name "*.$PROGRAM.[0-9]*" -print0 | while IFS= read -r -d $'\0' backup; do
		copy=$rotate_copies
		while [ $copy -gt 1 ]; do
			if [ $copy -eq $rotate_copies ]; then
				path="$backup.$PROGRAM.$copy"
				if [ -f "$path" ] || [ -d "$path" ]; then
					cmd="rm -rf \"$path\""
					Logger "cmd: $cmd" "DEBUG"
					eval "$cmd" &
					WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]} true $KEEP_LOGGING
					if [ $? != 0 ]; then
						Logger "Cannot delete oldest copy [$path]." "ERROR"
					fi
				fi
			fi

			path="$backup.$PROGRAM.$(($copy-1))"
			if [ -f "$path" ] || [ -d "$path" ]; then
				cmd="mv \"$path\" \"$backup.$PROGRAM.$copy\""
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]} true $KEEP_LOGGING
				if [ $? != 0 ]; then
					Logger "Cannot move [$path] to [$backup.$PROGRAM.$copy]." "ERROR"
				fi

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]} true $KEEP_LOGGING
			if [ $? != 0 ]; then
				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]} true $KEEP_LOGGING
			if [ $? != 0 ]; then
				Logger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi

		else
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]} true $KEEP_LOGGING
			if [ $? != 0 ]; then
				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi
		fi
	done
}

function _RotateBackupsRemote {
	local backup_path="${1}"
	local rotate_copies="${2}"

$SSH_CMD PROGRAM=$PROGRAM REMOTE_OPERATION=$REMOTE_OPERATION _DEBUG=$_DEBUG COMMAND_SUDO=$COMMAND_SUDO rotate_copies=$rotate_copies backup_path="$backup_path" 'bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &

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
	else
		_RemoteLogger "\e[41mLogger function called without proper loglevel.\e[0m"
		_RemoteLogger "$prefix$value"
	fi
}

function _RotateBackupsRemoteSSH {
	find "$backup_path" -mindepth 1 -maxdepth 1 ! -name "*.$PROGRAM.[0-9]*" -print0 | while IFS= read -r -d $'\0' backup; do
		copy=$rotate_copies
		while [ $copy -gt 1 ]; do
			if [ $copy -eq $rotate_copies ]; then
				path="$backup.$PROGRAM.$copy"
				if [ -f "$path" ] || [ -d "$path" ]; then
					cmd="$COMMAND_SUDO rm -rf \"$path\""
					RemoteLogger "cmd: $cmd" "DEBUG"
					eval "$cmd"
					if [ $? != 0 ]; then
						RemoteLogger "Cannot delete oldest copy [$path]." "ERROR"
					fi
				fi
			fi
			path="$backup.$PROGRAM.$(($copy-1))"
			if [ -f "$path" ] || [ -d "$path" ]; then
				cmd="$COMMAND_SUDO mv \"$path\" \"$backup.$PROGRAM.$copy\""
				RemoteLogger "cmd: $cmd" "DEBUG"
				eval "$cmd"
				if [ $? != 0 ]; then
					RemoteLogger "Cannot move [$path] to [$backup.$PROGRAM.$copy]." "ERROR"
				fi

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="$COMMAND_SUDO mv \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
				RemoteLogger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="$COMMAND_SUDO cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
				RemoteLogger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi

		else
			cmd="$COMMAND_SUDO mv \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "cmd: $cmd" "DEBUG"
			eval "$cmd"
			if [ $? != 0 ]; then
				RemoteLogger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
			fi
		fi
	done
}

	_RotateBackupsRemoteSSH

ENDSSH

	WaitForTaskCompletion $! 1800 0 ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? != 0 ]; then
		Logger "Could not rotate backups in [$backup_path]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
	else
		Logger "Remote rotation succeed." "NOTICE"
	fi        ## Need to add a trivial sleep time to give ssh time to log to local file
	#sleep 5


}

function RotateBackups {
	local backup_path="${1}"
	local rotate_copies="${2}"

	Logger "Rotating backups in [$backup_path] for [$rotate_copies] copies." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		_RotateBackupsLocal "$backup_path" "$rotate_copies"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_RotateBackupsRemote "$backup_path" "$rotate_copies"
	fi
}

function SetTraps {
	trap TrapStop INT QUIT TERM HUP
	trap TrapQuit EXIT
}

function Init {

	local uri
	local hosturiandpath
	local hosturi

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
	echo "--dry             will run obackup without actually doing anything, just testing"
	echo "--silent          will run obackup without any output to stdout, usefull for cron backups"
	echo "--errors-only     Output only errors (can be combined with silent or verbose)"
	echo "--verbose         adds command outputs"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      disables any soft and hard execution time checks"
	echo "--delete          Deletes files on destination that vanished on source"
	echo "--dontgetsize     Does not try to evaluate backup size"
	echo ""
	echo "Batch processing usage:"
	echo -e "\e[93mDecrypt\e[0m a backup encrypted with $PROGRAM"
	echo  "$0 --decrypt=/path/to/encrypted_backup --passphrase-file=/path/to/passphrase"
	echo  "$0 --decrypt=/path/to/encrypted_backup --passphrase=MySecretPassPhrase (security risk)"
	echo ""
	echo "Batch encrypt a directory in separate gpg files"
	echo "$0 --encrypt=/path/to/files --destination=/path/to/encrypted/files --recipient=\"Your Name\""
	exit 128
}

# Command line argument flags
_DRYRUN=false
_LOGGER_SILENT=false
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
		esac
	done
}

SetTraps
GetCommandlineArguments "$@"
if [ "$_DECRYPT_MODE" == true ]; then
	CheckCryptEnvironnment
	DecryptFiles "$DECRYPT_PATH" "$PASSPHRASE_FILE" "$PASSPHRASE"
	exit $?
fi

if [ "$_ENCRYPT_MODE" == true ]; then
	CheckCryptEnvironnment
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
Logger "$DRY_WARNING$DATE - $PROGRAM v$PROGRAM_VERSION $BACKUP_TYPE script begin." "NOTICE"
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "Backup instance [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

GetLocalOS
InitLocalOSSettings
CheckRunningInstances
PreInit
Init
CheckEnvironment
PostInit
CheckCurrentConfig

if [ "$REMOTE_OPERATION" == "yes" ]; then
	GetRemoteOS
	InitRemoteOSSettings
fi

if [ $no_maxtime == true ]; then
	SOFT_MAX_EXEC_TIME_DB_TASK=0
	SOFT_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_DB_TASK=0
	HARD_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_TOTAL=0
fi

RunBeforeHook
Main
