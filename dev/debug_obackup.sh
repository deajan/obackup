#!/usr/bin/env bash

#TODO: do we rotate encrypted files too or only temp files in storage dir (pull / local question)

###### Remote push/pull (or local) backup script for files & databases
PROGRAM="obackup"
AUTHOR="(C) 2013-2017 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.1-beta2
PROGRAM_BUILD=2017021001
IS_STABLE=no

#### Execution order					#__WITH_PARANOIA_DEBUG
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


_OFUNCTIONS_VERSION=2.1-RC3+dev
_OFUNCTIONS_BUILD=2017031401
_OFUNCTIONS_BOOTSTRAP=true

## BEGIN Generic bash functions written in 2013-2017 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_SILENT=true/false
## _LOGGER_VERBOSE=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

## Logger sets {ERROR|WARN}_ALERT variable when called with critical / error / warn loglevel
## When called from subprocesses, variable of main process can't be set. Status needs to be get via $RUN_DIR/$PROGRAM.Logger.{error|warn}.$SCRIPT_PID.$TSTAMP

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

## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

SCRIPT_PID=$$
TSTAMP=$(date '+%Y%m%dT%H%M%S.%N')

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
elif [ -w . ]; then
	LOG_FILE="./$PROGRAM.log"
else
	LOG_FILE="/tmp/$PROGRAM.log"
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
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	sleep $SLEEP_TIME
}

#### Logger SUBSET ####

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

# General log function with log levels:

# Environment variables
# _LOGGER_SILENT: Disables any output to stdout & stderr
# _LOGGER_ERR_ONLY: Disables any output to stdout except for ALWAYS loglevel
# _LOGGER_VERBOSE: Allows VERBOSE loglevel messages to be sent to stdout

# Loglevels
# Except for VERBOSE, all loglevels are ALWAYS sent to log file

# CRITICAL, ERROR, WARN sent to stderr, color depending on level, level also logged
# NOTICE sent to stdout
# VERBOSE sent to stdout if _LOGGER_VERBOSE = true
# ALWAYS is sent to stdout unless _LOGGER_SILENT = true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=yes
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT isn't set in main when Logger is called from a subprocess. Need to keep this flag.
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.warn.$SCRIPT_PID.$TSTAMP"
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
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "$prefix$value" "$prefix\e[35m$value\e[0m"	#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}
#### Logger SUBSET END ####

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

	if [ "$_LOGGER_SILENT" == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Warning: pgrep does not exist in cygwin, have this checked in CheckEnvironment
	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			Logger "Launching KillChilds \"$child\" true" "DEBUG"	#__WITH_PARANOIA_DEBUG
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		if kill -0 "$pid" > /dev/null 2>&1; then
			kill -s TERM "$pid"
			Logger "Sent SIGTERM to process [$pid]." "DEBUG"
			if [ $? != 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? != 0 ]; then
					Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
					return 1
				fi	# Simplify the return 0 logic here
			else
				return 0
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

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	__CheckArguments 0-1 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		attachment=false
	else
		attachment=true
	fi
	if [ -e "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" ]; then
		if [ "$MAIL_BODY_CHARSET" != "" ] && type iconv > /dev/null 2>&1; then
			iconv -f UTF-8 -t $MAIL_BODY_CHARSET "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" > "$RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP"
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP)"
		else
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP)"
		fi
	fi

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
		subject="Finished run - $subject"
	fi

	if [ "$attachment" == true ]; then
		attachmentFile="$ALERT_LOG_FILE"
	fi

	SendEmail "$subject" "$body" "$DESTINATION_MAILS" "$attachmentFile" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"

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

	__CheckArguments 3-10 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ]; then
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if type sendmail > /dev/null 2>&1; then
			if [ "$encryption" == "tls" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -tls1_2 -starttls smtp -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			elif [ "$encryption" == "ssl" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
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
		# We need to replace spaces with comma in order for mutt to be able to process multiple destinations
		echo "$message" | $(type -p mutt) -x -s "$subject" "${destinationMails// /,}" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		# We need to detect which version of mail is installed
		if ! $(type -p mail) -V > /dev/null 2>&1; then
			# This may be MacOS mail program
			attachment_command=""
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
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
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

function LoadConfigFile {
	local configFile="${1}"

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG


	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		#printf "\b\b\b\b\b\b"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}


# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION_$callerName that contains list of failed pids in format pid1:result1;pid2:result2
# Also sets a global variable called HARD_MAX_EXEC_TIME_REACHED_$callerName to true if hardMaxTime is reached

# Standard wait $! emulation would be WaitForTaskCompletion $! 0 0 1 0 true false true false

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local softMaxTime="${2:-0}"	# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${3:-0}"	# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${4:-.05}"	# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${5:-0}"	# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${6:-true}"	# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${7:-true}"	# Show spinner (true), don't show anything (false)
	local noErrorLog="${8:-false}"	# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"
	Logger "${FUNCNAME[0]} called by [$callerName]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 8 $# "$@"				#__WITH_PARANOIA_DEBUG

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

	local hasPids=false # Are any valable pids given to function ?		#__WITH_PARANOIA_DEBUG

	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	# Set global var default
	eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
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
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			return $errorcount
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "${FUNCNAME[0]} called by [$callerName] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_$callerName\")" == "" ]; then
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"$pid:$retval\""
						else
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\";$pid:$retval\""
						fi
					fi
				fi
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR" 		##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG

		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime
	done

	Logger "${FUNCNAME[0]} ended for [$callerName] using [$pidCount] subprocesses with [$errorcount] errors." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG

	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value
	if [ $pidCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
# Only 2 first arguments are mandatory
# Sets a global variable called HARD_MAX_EXEC_TIME_REACHED to true if hardMaxTime is reached

function ParallelExec {
	local numberOfProcesses="${1}" 		# Number of simultaneous commands to run
	local commandsArg="${2}" 		# Semi-colon separated list of commands, or path to file containing one command per line
	local readFromFile="${3:-false}" 	# commandsArg is a file (true), or a string (false)
	local softMaxTime="${4:-0}"		# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${5:-0}"		# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${6:-.05}"		# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${7:-0}"		# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${8:-true}"		# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${9:-false}"		# Show spinner (true), don't show spinner (false)
	local noErrorLog="${10:-false}"		# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"
	__CheckArguments 2-10 $# "$@"				#__WITH_PARANOIA_DEBUG

	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

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

	local hasPids=false # Are any valable pids given to function ?		#__WITH_PARANOIA_DEBUG

	# Set global var default
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

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

		if [ $spinner == true ]; then
			Spinner
		fi

		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
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
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi
		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			# Return the number of commands that haven't run / finished run
			return $((commandCount - counter + ${#pidsArray[@]}))
		fi

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$callerName.$SCRIPT_PID.$TSTAMP" 2>&1 &
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
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR"			##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime
	done

	return $errorCount
}

function CleanUp {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
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
function UrlEncode {
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

function UrlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: [ $(ArrayContains "needle" "${haystack[@]}") -eq 1 ]
function ArrayContains () {
	local needle="${1}"
	local haystack="${2}"
	local e

	if [ "$needle" != "" ] && [ "$haystack" != "" ]; then
		for e in "${@:2}"; do
			if [ "$e" == "$needle" ]; then
				echo 1
				return
			fi
		done
	fi
	echo 0
	return
}

function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi

	case $localOsVar in
		# Android uname contains both linux and android, keep it before linux entry
		*"Android"*)
		LOCAL_OS="Android"
		;;
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac
	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$localOsVar]." "DEBUG"
	fi

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME")
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION")
	fi

	# Add a global variable for statistics in installer
	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer)"
}


function GetRemoteOS {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		return 0
	fi

	local remoteOsVar

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1

function GetOs {
	local localOsVar
	local localOsName
	local localOsVer

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi
	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME")
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION")
	fi

	echo "$localOsVar ($localOsName $localOsVer)"
}

GetOs

ENDSSH

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		remoteOsVar=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")
		case $remoteOsVar in
			*"Android"*)
			REMOTE_OS="Android"
			;;
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*|*"MSYS"*)
			REMOTE_OS="msys"
			;;
			*"CYGWIN"*)
			REMOTE_OS="Cygwin"
			;;
			*"Microsoft"*)
			REMOTE_OS="WinNT10"
			;;
			*"Darwin"*)
			REMOTE_OS="MacOSX"
			;;
			*"BusyBox"*)
			REMOTE_OS="BusyBox"
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
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &

	WaitForTaskCompletion $! 0 $hardMaxTime $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
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
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG


	if [ "$REMOTE_OPERATION" != "yes" ]; then
		Logger "Ignoring remote command [$command] because remote host is not configured." "WARN"
		return 0
	fi

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "env _REMOTE_TOKEN="'$_REMOTE_TOKEN'" $command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hardMaxTime $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ] && ([ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 60 180 $SLEEP_TIME $KEEP_LOGGING true true false
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
	fi											#__WITH_PARANOIA_DEBUG
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local remote3rdPartySuccess
	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 180 360 $SLEEP_TIME $KEEP_LOGGING true true false
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
	fi											#__WITH_PARANOIA_DEBUG
}

#__BEGIN_WITH_PARANOIA_DEBUG
function __CheckArguments {
	# Checks the number of arguments of a function and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then
		local numberOfArguments="${1}" # Number of arguments the tested function should have, can be a number of a range, eg 0-2 for zero to two arguments
		local numberOfGivenArguments="${2}" # Number of arguments that have been passed

		local minArgs
		local maxArgs

		# All arguments of the function to check are passed as array in ${3} (the function call waits for $@)
		# If any of the arguments contains spaces, bash things there are two aguments
		# In order to avoid this, we need to iterate over ${3} and count

		callerName="${FUNCNAME[1]}"

		local iterate=3
		local fetchArguments=true
		local argList=""
		local countedArguments
		while [ $fetchArguments == true ]; do
			cmd='argument=${'$iterate'}'
			eval $cmd
			if [ "$argument" == "" ]; then
				fetchArguments=false
			else
				argList="$argList[Argument $((iterate-2)): $argument] "
				iterate=$((iterate+1))
			fi
		done

		countedArguments=$((iterate-3))

		if [ $(IsInteger "$numberOfArguments") -eq 1 ]; then
			minArgs=$numberOfArguments
			maxArgs=$numberOfArguments
		else
			IFS='-' read minArgs maxArgs <<< "$numberOfArguments"
		fi

		Logger "Entering function [$callerName]." "PARANOIA_DEBUG"

		if ! ([ $countedArguments -ge $minArgs ] && [ $countedArguments -le $maxArgs ]); then
			Logger "Function $callerName may have inconsistent number of arguments. Expected min: $minArgs, max: $maxArgs, count: $countedArguments, bash seen: $numberOfGivenArguments." "ERROR"
			Logger "$callerName arguments: $argList" "ERROR"
		else
			if [ ! -z "$argList" ]; then
				Logger "$callerName arguments: $argList" "PARANOIA_DEBUG"
			fi
		fi
	fi
}

#__END_WITH_PARANOIA_DEBUG

function RsyncPatternsAdd {
	local patternType="${1}"	# exclude or include
	local pattern="${2}"
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local rest

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str="${rest%%$PATH_SEPARATOR_CHAR*}"
		# Handle the last case
		if [ "$rest" == "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest="${rest#*$PATH_SEPARATOR_CHAR}"
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
	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename $patternFrom)" == "$patternFrom" ]; then
		patternFrom="$(dirname $CONFIG_FILE)/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"-from=\"$patternFrom\""
	fi
}

function RsyncPatterns {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
	 __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
		COMMAND_SUDO="sudo -E"
	else
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="$RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO=""
	fi

	## Set compression executable and extension
	if [ "$(IsInteger $COMPRESSION_LEVEL)" -eq 0 ]; then
		COMPRESSION_LEVEL=3
	fi
}

function PostInit {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

function SetCompression {
	## Busybox fix (Termux xz command doesn't support compression at all)
	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$REMOTE_OS" == "Android" ]; then
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
			if [ "$LOCAL_OS" != "MacOSX" ]; then
				COMPRESSION_OPTIONS=--rsyncable
			fi
		elif type gzip > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| gzip -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
			if [ "$LOCAL_OS" != "MacOSX" ]; then
				COMPRESSION_OPTIONS=--rsyncable
			fi
		else
			COMPRESSION_PROGRAM=
			COMPRESSION_EXTENSION=
		fi
	fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function InitLocalOSDependingSettings {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		FIND_CMD=$(dirname $BASH)/find
		PING_CMD='$SYSTEMROOT\system32\ping -n 2'

	# On BSD, when not root, min ping interval is 1s
	elif [ "$LOCAL_OS" == "BSD" ] && [ "$LOCAL_USER" != "root" ]; then
		FIND_CMD=find
		PING_CMD="ping -c 2 -i 1"
	else
		FIND_CMD=find
		PING_CMD="ping -c 2 -i .2"
	fi

	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		PROCESS_STATE_CMD="echo none"
		DF_CMD="df"
	else
		PROCESS_STATE_CMD='ps -p$pid -o state= 2 > /dev/null'
		# CentOS 5 needs -P for one line output
		DF_CMD="df -P"
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		# Tested on BSD and Mac
		STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
	else
		# Tested on GNU stat, busybox and Cygwin
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
	fi

	# Set compression first time when we know what local os we have
	SetCompression
}

# Gets executed regardless of the need of remote connections. It's just that this code needs to get executed after we know if there is a remote os, and if yes, which one
function InitRemoteOSDependingSettings {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
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

	## Set rsync default arguments
	RSYNC_ARGS="-rltD -8"
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
	if [ "$PRESERVE_EXECUTABILITY" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" --executability"
	fi
	if [ "$PRESERVE_ACL" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ] && [ "$LOCAL_OS" != "Android" ] && [ "$REMOTE_OS" != "Android" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
		else
			Logger "Disabling ACL synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"

		fi
	fi
	if [ "$PRESERVE_XATTR" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
		else
			Logger "Disabling extended attributes synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$RSYNC_COMPRESS" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_ARGS=$RSYNC_ARGS" -zz --skip-compress=gz/xz/lz/lzma/lzo/rz/jpg/mp3/mp4/7z/bz2/rar/zip/sfark/s7z/ace/apk/arc/cab/dmg/jar/kgb/lzh/lha/lzx/pak/sfx"
		else
			Logger "Disabling compression skips on synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$COPY_SYMLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -K"
	fi
	if [ "$RSYNC_OPTIONAL_ARGS" != "" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" "$RSYNC_OPTIONAL_ARGS
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

	# Set compression options again after we know what remote OS we're dealing with
	SetCompression
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

# Neat version compare function found at http://stackoverflow.com/a/4025065/2635443
# Returns 0 if equal, 1 if $1 > $2 and 2 if $1 < $2
vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

function GetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value

        value=$(grep "^$name=" "$file")
        if [ $? == 0 ]; then
                value="${value##*=}"
                echo "$value"
        else
		Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
        fi
}

function SetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value="${3}"
	local separator="${4:-#}"

        if grep "^$name=" "$file" > /dev/null; then
                # Using -i.tmp for BSD compat
                sed -i.tmp "s$separator^$name=.*$separator$name=$value$separator" "$file"
                rm -f "$file.tmp"
		Logger "Set [$name] to [$value] in config file [$file]." "DEBUG"
        else
		Logger "Cannot set value [$name] to [$value] in config file [$file]." "ERROR"
        fi
}

# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap
_OFUNCTIONS_BOOTSTRAP=true
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

	if ! type pgrep > /dev/null 2>&1 ; then
		Logger "pgrep not present. $0 cannot start." "CRITICAL"
		exit 1
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
		_LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
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
	sqlCmd="$SSH_CMD \"env _REMOTE_TOKEN=$_REMOTE_TOKEN mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
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
			 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
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

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env RECURSIVE_DIRECTORY_LIST="'$RECURSIVE_DIRECTORY_LIST'" env PATH_SEPARATOR_CHAR="'$PATH_SEPARATOR_CHAR'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

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
		 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
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

function _GetDirectoriesSizeRemote {
	local dirList="${1}"
	__CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	local cmd
	local retval

	# Error output is different from stdout because not all files in list may fail at once
$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" dirList="'$dirList'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

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

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env dirToCreate="'$dirToCreate'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

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

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env DF_CMD="'$DF_CMD'" \
env pathToCheck="'$pathToCheck'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

function _GetDiskSpaceRemoteSub {
	if [ -d "$pathToCheck" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		cmd="$DF_CMD \"$pathToCheck\""
		eval $cmd
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
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
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
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions | $SSH_CMD 'env _REMOTE_TOKEN=$_REMOTE_TOKEN $COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension\" > /dev/null' 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"

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
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
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

	local drySqlCmd=$SSH_CMD' "env _REMOTE_TOKEN=$_REMOTE_TOKEN mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'
	local sqlCmd=$SSH_CMD' "env _REMOTE_TOKEN=$_REMOTE_TOKEN mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension'" 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'

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
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
			eval "$sqlCmd" &
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
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
			Logger "Encryption error." "ERROR"
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
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$sourceDir\" \"$destinationDir\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		destinationDir=$(EscapeSpaces "$destinationDir")
		_CreateDirectoryRemote "$destinationDir"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$sourceDir\" \"$REMOTE_USER@$REMOTE_HOST:$destinationDir\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	fi

	Logger "Launching command [$rsyncCmd]." "DEBUG"
	eval "$rsyncCmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed to backup [$sourceDir] to [$destinationDir]." "ERROR"
		 _LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
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
						 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
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
					 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
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
				 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -ne 0 ]; then
				Logger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			fi

		else
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 $SLEEP_TIME $KEEP_LOGGING true true false
			if [ $? -ne 0 ]; then
				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			fi
		fi
	done
}

function _RotateBackupsRemote {
	local backupPath="${1}"
	local rotateCopies="${2}"
	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" env rotateCopies="'$rotateCopies'" env backupPath="'$backupPath'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

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
