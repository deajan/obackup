#!/usr/bin/env bash

#TODO: do we rotate encrypted files too or only temp files in storage dir (pull / local question)

###### Remote push/pull (or local) backup script for files & databases
PROGRAM="obackup"
AUTHOR="(C) 2013-2019 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.1-dev-postRC1
PROGRAM_BUILD=2020031501
IS_STABLE=true

CONFIG_FILE_REVISION_REQUIRED=2.1


_OFUNCTIONS_VERSION=2.3.0-RC4
_OFUNCTIONS_BUILD=2020031503
_OFUNCTIONS_BOOTSTRAP=true

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

## Default umask for file creation
umask 0077

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


## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

# The variables SCRIPT_PID and TSTAMP needs to be declared as soon as the program begins. The function PoorMansRandomGenerator is needed for TSTAMP (since some systems date function does not give nanoseconds)

SCRIPT_PID=$$

# Get a random number of digits length on Windows BusyBox alike, also works on most Unixes that have dd
function PoorMansRandomGenerator {
	local digits="${1}" # The number of digits to generate
	local number

	# Some read bytes can't be used, se we read twice the number of required bytes
	dd if=/dev/urandom bs=$digits count=2 2> /dev/null | while read -r -n1 char; do
		number=$number$(printf "%d" "'$char")
		if [ ${#number} -ge $digits ]; then
			echo ${number:0:$digits}
			break;
		fi
	done
}

# Initial TSTMAP value before function declaration
TSTAMP=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)

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

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
## If the same program gets remotely executed, add _REMOTE_EXECUTION=true to it's environment so it knows it has to write into a separate directory
## This will thus not affect local $RUN_DIR variables
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
fi

# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
set -o pipefail
set -o errtrace


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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
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
# VERBOSE sent to stdout if _LOGGER_VERBOSE=true
# ALWAYS is sent to stdout unless _LOGGER_SILENT=true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=true
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date '+%Y-%m-%d %H:%M:%S') - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/env _REMOTE_TOKEN=__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/env _REMOTE_TOKEN=__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT is not set in main when Logger is called from a subprocess. Need to keep this flag.
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
			_Logger "$prefix($level):$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}

# Function is busybox compatible since busybox ash does not understand direct regex, we use expr
function IsInteger {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[0-9]+$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Paranoid checks, we can safely assume that $pid should not be 0 nor 1
	if [ $(IsInteger "$pid") -eq 0 ] || [ "$pid" == "" ] || [ "$pid" == "0" ] || [ "$pid" == "1" ]; then
		Logger "Bogus pid given [$pid]." "CRITICAL"
		return 1
	fi

	if kill -0 "$pid" > /dev/null 2>&1; then
		if children="$(pgrep -P "$pid")"; then
			if [[ "$pid" == *"$children"* ]]; then
				Logger "Bogus pgrep implementation." "CRITICAL"
				children="${children/$pid/}"
			fi
			for child in $children; do
				KillChilds "$child" true
			done
		fi
	fi

	# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		# We need to check for pid again because it may have disappeared after recursive function call
		if kill -0 "$pid" > /dev/null 2>&1; then
			kill -s TERM "$pid"
			Logger "Sent SIGTERM to process [$pid]." "DEBUG"
			if [ $? -ne 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? -ne 0 ]; then
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


	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid $self
		if [ $? -ne 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

function GenericTrapQuit {
	local exitcode=0

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
		exitcode=2
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
		exitcode=1
	fi

	CleanUp
	exit $exitcode
}


function CleanUp {
	# Exit controlmaster before it's socket gets deleted
	if [ "$SSH_CONTROLMASTER" == true ] && [ "$SSH_CMD" != "" ]; then
		$SSH_CMD -O exit
	fi

	if [ "$_DEBUG" != true ]; then
		# Removing optional remote $RUN_DIR that goes into local $RUN_DIR
		if [ -d "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP" ]; then
			rm -rf "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
                fi
		# Removing all temporary run files
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}



# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run
	local attachment="${2:-true}" # Should we send the log file as attachment


	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == true ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	if [ $attachment == true ]; then
		attachmentFile="$LOG_FILE"
		if type "$COMPRESSION_PROGRAM" > /dev/null 2>&1; then
			eval "cat \"$LOG_FILE\" \"$COMPRESSION_PROGRAM\" > \"$ALERT_LOG_FILE\""
			if [ $? -eq 0 ]; then
				attachmentFile="$ALERT_LOG_FILE"
			fi
		fi
	fi

	body="$MAIL_ALERT_MSG"$'\n\n'"Last 1000 lines of current log"$'\n\n'"$(tail -n 1000 "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP")"

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

# If text is received as attachment ATT00001.bin or noname, consider adding the following to /etc/mail.rc
#set ttycharset=iso-8859-1
#set sendcharsets=iso-8859-1
#set encoding=8bit

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


	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	local i

	if [ "${destinationMails}" != "" ]; then
		for i in "${destinationMails[@]}"; do
			if [ $(CheckRFC822 "$i") -ne 1 ]; then
				Logger "Given email [$i] does not seem to be valid." "WARN"
			fi
		done
	else
		Logger "No valid email addresses given." "WARN"
		return 1
	fi

	# Prior to sending an email, convert its body if needed
	if [ "$MAIL_BODY_CHARSET" != "" ]; then
		if type iconv > /dev/null 2>&1; then
			echo "$message" | iconv -f UTF-8 -t $MAIL_BODY_CHARSET -o "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP"
			message="$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP")"
		else
			Logger "iconv utility not installed. Will not convert email charset." "NOTICE"
		fi
	fi

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
			elif [ "$encryption" == "none" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
				Logger "Bogus email encryption used [$encryption]." "WARN"
			fi

			if [ $? -ne 0 ]; then
				Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
				# Do not bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Will not send any mail" "WARN"
			return 1
		fi
	fi

	if type mutt > /dev/null 2>&1 ; then
		# We need to replace spaces with comma in order for mutt to be able to process multiple destinations
		echo "$message" | $(type -p mutt) -x -s "$subject" "${destinationMails// /,}" $attachment_command
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
			if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? -ne 0 ]; then
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
	local revisionRequired="${2}"


	local revisionPresent

	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		revisionPresent="$(GetConfFileValue "$configFile" "CONFIG_FILE_REVISION" true)"
		if [ "$(IsNumeric "${revisionPresent%%.*}")" -eq 0 ]; then
			Logger "Missing CONFIG_FILE_REVISION. Please provide a valid config file, or run the config update script." "WARN"
			Logger "CONFIG_FILE_REVISION does not seem numeric [$revisionPresent]." "DEBUG"
		elif [ "$revisionRequired" != "" ]; then
			if [ $(VerComp "$revisionPresent" "$revisionRequired") -eq 2 ]; then
				Logger "Configuration file seems out of date. Required version [$revisionRequired]. Actual version [$revisionPresent]." "CRITICAL"
				exit 1
			fi
		fi
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

# Quick and dirty performance logger only used for debugging

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ] || [ "$_SYNC_ON_CHANGES" == "initiator" ] || [ "$_SYNC_ON_CHANGES" == "target" ] ; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}

# WaitForTaskCompletion function emulation, now uses ExecTasks
function WaitForTaskCompletion {
	local pids="${1}"
	local softMaxTime="${2:-0}"
	local hardMaxTime="${3:-0}"
	local sleepTime="${4:-.05}"
	local keepLogging="${5:-0}"
	local counting="${6:-true}"
	local spinner="${7:-true}"
	local noErrorLog="${8:-false}"
	local id="${9-base}"

	ExecTasks "$pids" "$id" false 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorlog"
}

# ParallelExec function emulation, now uses ExecTasks
function ParallelExec {
	local numberOfProcesses="${1}"
	local commandsArg="${2}"
	local readFromFile="${3:-false}"
	local softMaxTime="${4:-0}"
	local hardMaxTime="${5:-0}"
	local sleepTime="${6:-.05}"
	local keepLogging="${7:-0}"
	local counting="${8:-true}"
	local spinner="${9:-false}"
	local noErrorLog="${10:-false}"

	if [ $readFromFile == true ]; then
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	else
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	fi
}

## Main asynchronous execution function
## Function can work in:
## WaitForTaskCompletion mode: monitors given pid in background, and stops them if max execution time is reached. Suitable for multiple synchronous pids to monitor and wait for
## ParallExec mode: takes list of commands to execute in parallel per batch, and stops them if max execution time is reahed.

## Example of improved wait $!
## ExecTasks $! "some_identifier" false 0 0 0 0 true 1 1800 false
## Example: monitor two sleep processes, warn if execution time is higher than 10 seconds, stop after 20 seconds
## sleep 15 &
## pid=$!
## sleep 20 &
## pid2=$!
## ExecTasks "some_identifier" 0 0 10 20 1 1800 true true false false 1 "$pid;$pid2"

## Example of parallel execution of four commands, only if directories exist. Warn if execution takes more than 300 seconds. Stop if takes longer than 900 seconds. Exeute max 3 commands in parallel.
## commands="du -csh /var;du -csh /etc;du -csh /home;du -csh /usr"
## conditions="[ -d /var ];[ -d /etc ];[ -d /home];[ -d /usr]"
## ExecTasks "$commands" "some_identifier" false 0 0 300 900 true 1 1800 true false false 3 "$conditions"

## Bear in mind that given commands and conditions need to be quoted

## ExecTasks has the following ofunctions subfunction requirements:
## Spinner
## Logger
## JoinString
## KillChilds

## Full call
##ExecTasks "$mainInput" "$id" $readFromFile $softPerProcessTime $hardPerProcessTime $softMaxTime $hardMaxTime $counting $sleepTime $keepLogging $spinner $noTimeErrorLog $noErrorLogsAtAll $numberOfProcesses $auxInput $maxPostponeRetries $minTimeBetweenRetries $validExitCodes

function ExecTasks {
	# Mandatory arguments
	local mainInput="${1}"				# Contains list of pids / commands separated by semicolons or filepath to list of pids / commands

	# Optional arguments
	local id="${2:-base}"				# Optional ID in order to identify global variables from this run (only bash variable names, no '-'). Global variables are WAIT_FOR_TASK_COMPLETION_$id and HARD_MAX_EXEC_TIME_REACHED_$id
	local readFromFile="${3:-false}"		# Is mainInput / auxInput a semicolon separated list (true) or a filepath (false)
	local softPerProcessTime="${4:-0}"		# Max time (in seconds) a pid or command can run before a warning is logged, unless set to 0
	local hardPerProcessTime="${5:-0}"		# Max time (in seconds) a pid or command can run before the given command / pid is stopped, unless set to 0
	local softMaxTime="${6:-0}"			# Max time (in seconds) for the whole function to run before a warning is logged, unless set to 0
	local hardMaxTime="${7:-0}"			# Max time (in seconds) for the whole function to run before all pids / commands given are stopped, unless set to 0
	local counting="${8:-true}"			# Should softMaxTime and hardMaxTime be accounted since function begin (true) or since script begin (false)
	local sleepTime="${9:-.5}"			# Seconds between each state check. The shorter the value, the snappier ExecTasks will be, but as a tradeoff, more cpu power will be used (good values are between .05 and 1)
	local keepLogging="${10:-1800}"			# Every keepLogging seconds, an alive message is logged. Setting this value to zero disables any alive logging
	local spinner="${11:-true}"			# Show spinner (true) or do not show anything (false) while running
	local noTimeErrorLog="${12:-false}"		# Log errors when reaching soft / hard execution times (false) or do not log errors on those triggers (true)
	local noErrorLogsAtAll="${13:-false}"		# Do not log any errros at all (useful for recursive ExecTasks checks)

	# Parallelism specific arguments
	local numberOfProcesses="${14:-0}"		# Number of simulanteous commands to run, given as mainInput. Set to 0 by default (WaitForTaskCompletion mode). Setting this value enables ParallelExec mode.
	local auxInput="${15}"				# Contains list of commands separated by semicolons or filepath fo list of commands. Exit code of those commands decide whether main commands will be executed or not
	local maxPostponeRetries="${16:-3}"		# If a conditional command fails, how many times shall we try to postpone the associated main command. Set this to 0 to disable postponing
	local minTimeBetweenRetries="${17:-300}"	# Time (in seconds) between postponed command retries
	local validExitCodes="${18:-0}"			# Semi colon separated list of valid main command exit codes which will not trigger errors


	local i


	# Since ExecTasks takes up to 17 arguments, do a quick preflight check in DEBUG mode
	if [ "$_DEBUG" == true ]; then
		declare -a booleans=(readFromFile counting spinner noTimeErrorLog noErrorLogsAtAll)
		for i in "${booleans[@]}"; do
			test="if [ \$$i != false ] && [ \$$i != true ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
		declare -a integers=(softPerProcessTime hardPerProcessTime softMaxTime hardMaxTime keepLogging numberOfProcesses maxPostponeRetries minTimeBetweenRetries)
		for i in "${integers[@]}"; do
			test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
	fi

	# Expand validExitCodes into array
	IFS=';' read -r -a validExitCodes <<< "$validExitCodes"

	# ParallelExec specific variables
	local auxItemCount=0		# Number of conditional commands
	local commandsArray=()		# Array containing commands
	local commandsConditionArray=() # Array containing conditional commands
	local currentCommand		# Variable containing currently processed command
	local currentCommandCondition	# Variable containing currently processed conditional command
	local commandsArrayPid=()	# Array containing commands indexed by pids
	local commandsArrayOutput=()	# Array containing command results indexed by pids
	local postponedRetryCount=0	# Number of current postponed commands retries
	local postponedItemCount=0	# Number of commands that have been postponed (keep at least one in order to check once)
	local postponedCounter=0
	local isPostponedCommand=false	# Is the current command from a postponed file ?
	local postponedExecTime=0	# How much time has passed since last postponed condition was checked
	local needsPostponing		# Does currentCommand need to be postponed
	local temp

	# Common variables
	local pid			# Current pid working on
	local pidState			# State of the process
	local mainItemCount=0		# number of given items (pids or commands)
	local readFromFile		# Should we read pids / commands from a file (true)
	local counter=0
	local log_ttime=0		# local time instance for comparaison

	local seconds_begin=$SECONDS	# Seconds since the beginning of the script
	local exec_time=0		# Seconds since the beginning of this function

	local retval=0			# return value of monitored pid process
	local subRetval=0		# return value of condition commands
	local errorcount=0		# Number of pids that finished with errors
	local pidsArray			# Array of currently running pids
	local newPidsArray		# New array of currently running pids for next iteration
	local pidsTimeArray		# Array containing execution begin time of pids
	local executeCommand		# Boolean to check if currentCommand can be executed given a condition
	local functionMode
	local softAlert=false		# Does a soft alert need to be triggered, if yes, send an alert once
	local failedPidsList		# List containing failed pids with exit code separated by semicolons (eg : 2355:1;4534:2;2354:3)
	local randomOutputName		# Random filename for command outputs
	local currentRunningPids	# String of pids running, used for debugging purposes only

	# Initialise global variable
	eval "WAIT_FOR_TASK_COMPLETION_$id=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$id=false"

	# Init function variables depending on mode

	if [ $numberOfProcesses -gt 0 ]; then
		functionMode=ParallelExec
	else
		functionMode=WaitForTaskCompletion
	fi

	if [ $readFromFile == false ]; then
		if [ $functionMode == "WaitForTaskCompletion" ]; then
			IFS=';' read -r -a pidsArray <<< "$mainInput"
			mainItemCount="${#pidsArray[@]}"
		else
			IFS=';' read -r -a commandsArray <<< "$mainInput"
			mainItemCount="${#commandsArray[@]}"
			IFS=';' read -r -a commandsConditionArray <<< "$auxInput"
			auxItemCount="${#commandsConditionArray[@]}"
		fi
	else
		if [ -f "$mainInput" ]; then
			mainItemCount=$(wc -l < "$mainInput")
			readFromFile=true
		else
			Logger "Cannot read main file [$mainInput]." "WARN"
		fi
		if [ "$auxInput" != "" ]; then
			if [ -f "$auxInput" ]; then
				auxItemCount=$(wc -l < "$auxInput")
			else
				Logger "Cannot read aux file [$auxInput]." "WARN"
			fi
		fi
	fi

	if [ $functionMode == "WaitForTaskCompletion" ]; then
		# Force first while loop condition to be true because we don't deal with counters but pids in WaitForTaskCompletion mode
		counter=$mainItemCount
	fi


	# soft / hard execution time checks that needs to be a subfunction since it is called both from main loop and from parallelExec sub loop
	function _ExecTasksTimeCheck {
		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			# This log solely exists for readability purposes before having next set of logs
			if [ ${#pidsArray[@]} -eq $numberOfProcesses ] && [ $log_ttime -eq 0 ]; then
				log_ttime=$exec_time
				Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
			fi
			if [ $(((exec_time + 1) % keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1 second
					log_ttime=$exec_time
					if [ $functionMode == "WaitForTaskCompletion" ]; then
						Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					elif [ $functionMode == "ParallelExec" ]; then
						Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					fi
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ "$softAlert" != true ] && [ $softMaxTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
				Logger "Max soft execution time [$softMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				softAlert=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noTimeErrorLog != true ]; then
				Logger "Max hard execution time [$hardMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? -eq 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					if [ $noErrorLogsAtAll != true ]; then
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noTimeErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$id=true"
			if [ $functionMode == "WaitForTaskCompletion" ]; then
				return $errorcount
			else
				return 129
			fi
		fi
	}

	function _ExecTasksPidsCheck {
		newPidsArray=()

		if [ "$currentRunningPids" != "$(joinString " " ${pidsArray[@]})" ]; then
			Logger "ExecTask running for pids [$(joinString " " ${pidsArray[@]})]." "DEBUG"
			currentRunningPids="$(joinString " " ${pidsArray[@]})"
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then

						# Check if pid hasn't run more than soft/hard perProcessTime
						pidsTimeArray[$pid]=$((SECONDS - seconds_begin))
						if [ ${pidsTimeArray[$pid]} -gt $softPerProcessTime ]; then
							if [ "$softAlert" != true ] && [ $softPerProcessTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
								Logger "Max soft execution time [$softPerProcessTime] exceeded for pid [$pid]." "WARN"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
								softAlert=true
								SendAlert true
							fi
						fi


						if [ ${pidsTimeArray[$pid]} -gt $hardPerProcessTime ] && [ $hardPerProcessTime -ne 0 ]; then
							if [ $noTimeErrorLog != true ] && [ $noErrorLogsAtAll != true ]; then
								Logger "Max hard execution time [$hardPerProcessTime] exceeded for pid [$pid]. Stopping command execution." "ERROR"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
							fi
							KillChilds $pid true
							if [ $? -eq 0 ]; then
								 Logger "Command with pid [$pid] stopped successfully." "NOTICE"
							else
								if [ $noErrorLogsAtAll != true ]; then
								Logger "Could not stop command with pid [$pid]." "ERROR"
								fi
							fi
							errorcount=$((errorcount+1))

							if [ $noTimeErrorLog != true ]; then
								SendAlert true
							fi
						fi

						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get its exit code from wait command
					wait $pid
					retval=$?
					# Check for valid exit codes
					if [ $(ArrayContains $retval "${validExitCodes[@]}") -eq 0 ]; then
						if [ $noErrorLogsAtAll != true ]; then
							Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "ERROR"
							if [ "$functionMode" == "ParallelExec" ]; then
								Logger "Command was [${commandsArrayPid[$pid]}]." "ERROR"
							fi
							if [ -f "${commandsArrayOutput[$pid]}" ]; then
								Logger "Truncated output:\n$(head -c16384 "${commandsArrayOutput[$pid]}")" "ERROR"
							fi
						fi
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$failedPidsList" == "" ]; then
							failedPidsList="$pid:$retval"
						else
							failedPidsList="$failedPidsList;$pid:$retval"
						fi
					else
						Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
					fi
				fi
			fi
		done

		# hasPids can be false on last iteration in ParallelExec mode
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime


	}

	while [ ${#pidsArray[@]} -gt 0 ] || [ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]; do
		_ExecTasksTimeCheck
		retval=$?
		if [ $retval -ne 0 ]; then
			return $retval;
		fi

		# The following execution bloc is only needed in ParallelExec mode since WaitForTaskCompletion does not execute commands, but only monitors them
		if [ $functionMode == "ParallelExec" ]; then
			while [ ${#pidsArray[@]} -lt $numberOfProcesses ] && ([ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]); do
				_ExecTasksTimeCheck
				retval=$?
				if [ $retval -ne 0 ]; then
					return $retval;
				fi

				executeCommand=false
				isPostponedCommand=false
				currentCommand=""
				currentCommandCondition=""
				needsPostponing=false

				if [ $readFromFile == true ]; then
					# awk identifies first line as 1 instead of 0 so we need to increase counter
					currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$mainInput")
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$auxInput")
					fi

					# Check if we need to fetch postponed commands
					if [ "$currentCommand" == "" ]; then
						currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP")
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP")
						isPostponedCommand=true
					fi
				else
					currentCommand="${commandsArray[$counter]}"
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition="${commandsConditionArray[$counter]}"
					fi

					if [ "$currentCommand" == "" ]; then
						currentCommand="${postponedCommandsArray[$postponedCounter]}"
						currentCommandCondition="${postponedCommandsConditionArray[$postponedCounter]}"
						isPostponedCommand=true
					fi
				fi

				# Check if we execute postponed commands, or if we delay them
				if [ $isPostponedCommand == true ]; then
					# Get first value before '@'
					postponedExecTime="${currentCommand%%@*}"
					postponedExecTime=$((SECONDS-postponedExecTime))
					# Get everything after first '@'
					temp="${currentCommand#*@}"
					# Get first value before '@'
					postponedRetryCount="${temp%%@*}"
					# Replace currentCommand with actual filtered currentCommand
					currentCommand="${temp#*@}"

					# Since we read a postponed command, we may decrase postponedItemCounter
					postponedItemCount=$((postponedItemCount-1))
					#Since we read one line, we need to increase the counter
					postponedCounter=$((postponedCounter+1))

				else
					postponedRetryCount=0
					postponedExecTime=0
				fi
				if ([ $postponedRetryCount -lt $maxPostponeRetries ] && [ $postponedExecTime -ge $minTimeBetweenRetries ]) || [ $isPostponedCommand == false ]; then
					if [ "$currentCommandCondition" != "" ]; then
						Logger "Checking condition [$currentCommandCondition] for command [$currentCommand]." "DEBUG"
						eval "$currentCommandCondition" &
						ExecTasks $! "subConditionCheck" false 0 0 1800 3600 true $SLEEP_TIME $KEEP_LOGGING true true true
						subRetval=$?
						if [ $subRetval -ne 0 ]; then
							# is postponing enabled ?
							if [ $maxPostponeRetries -gt 0 ]; then
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Postponing command." "NOTICE"
								postponedRetryCount=$((postponedRetryCount+1))
								if [ $postponedRetryCount -ge $maxPostponeRetries ]; then
									Logger "Max retries reached for postponed command [$currentCommand]. Skipping command." "NOTICE"
								else
									needsPostponing=true
								fi
								postponedExecTime=0
							else
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Ignoring command." "NOTICE"
							fi
						else
							executeCommand=true
						fi
					else
						executeCommand=true
					fi
				else
					needsPostponing=true
				fi

				if [ $needsPostponing == true ]; then
					postponedItemCount=$((postponedItemCount+1))
					if [ $readFromFile == true ]; then
						echo "$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP"
						echo "$currentCommandCondition" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP"
					else
						postponedCommandsArray+=("$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand")
						postponedCommandsConditionArray+=("$currentCommandCondition")
					fi
				fi

				if [ $executeCommand == true ]; then
					Logger "Running command [$currentCommand]." "DEBUG"
					randomOutputName=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)
					eval "$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP" 2>&1 &
					pid=$!
					pidsArray+=($pid)
					commandsArrayPid[$pid]="$currentCommand"
					commandsArrayOutput[$pid]="$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP"
					# Initialize pid execution time array
					pidsTimeArray[$pid]=0
				else
					Logger "Skipping command [$currentCommand]." "DEBUG"
				fi

				if [ $isPostponedCommand == false ]; then
					counter=$((counter+1))
				fi
				_ExecTasksPidsCheck
			done
		fi

	_ExecTasksPidsCheck
	done


	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value

	eval "WAIT_FOR_TASK_COMPLETION_$id=\"$failedPidsList\""

	if [ $mainItemCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
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

# Usage var=$(EscapeDoubleQuotes "$var") or var="$(EscapeDoubleQuotes "$var")"
function EscapeDoubleQuotes {
	local value="${1}"

	echo "${value//\"/\\\"}"
}

# Usage [ $(IsNumeric $var) -eq 1 ]
function IsNumeric {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[-+]\{0,1\}[0-9]*\.\{0,1\}[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	echo $(IsNumeric "$value")
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

# Checks email address validity
function CheckRFC822 {
	local mail="${1}"
	local rfc822="^[a-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[a-z0-9!#$%&'*+/=?^_\`{|}~-]+)*@([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?\$"

	if [[ $mail =~ $rfc822 ]]; then
		echo 1
	else
		echo 0
	fi
}

## Modified version of https://gist.github.com/cdown/1163649
function UrlEncode {
	local length="${#1}"

	local i

	local LANG=C
	for i in $(seq 0 $((length-1))); do
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

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	elif set -o | grep "winxp" > /dev/null; then
		localOsVar="BusyBox-w32"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? -ne 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? -ne 0 ]; then
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
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*|*"MS/Windows"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == true ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName="$(GetConfFileValue "/etc/os-release" "NAME" true)"
		localOsVer="$(GetConfFileValue "/etc/os-release" "VERSION" true)"
	elif [ "$LOCAL_OS" == "BusyBox" ]; then
		localOsVer="$(ls --help 2>&1 | head -1 | cut -f2 -d' ')"
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "WinNT10" ]; then
		localOsVar="$localOsVar $(uname -a)"
		if [ "$PROGRAMW6432" != "" ]; then
			LOCAL_OS_BITNESS=64
			LOCAL_OS_FAMILY="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			LOCAL_OS_BITNESS=32
			LOCAL_OS_FAMILY="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$LOCAL_OS" == "BusyBox" ]; then
			LOCAL_OS_FAMILY="Unix"
		fi
	# Get Host info for Unix
	else
		LOCAL_OS_FAMILY="Unix"
	fi

	if [ "$LOCAL_OS_FAMILY" == "Unix" ]; then
		if uname -m | grep '64' > /dev/null 2>&1; then
			LOCAL_OS_BITNESS=64
		else
			LOCAL_OS_BITNESS=32
		fi
	fi

	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer) $LOCAL_OS_BITNESS-bit $LOCAL_OS_FAMILY"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}



function GetRemoteOS {

	if [ "$REMOTE_OPERATION" != true ]; then
		return 0
	fi

	local remoteOsVar

$SSH_CMD env LC_ALL=C env _REMOTE_TOKEN="$_REMOTE_TOKEN" bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1
_REMOTE_TOKEN="(o_0)"

function GetOs {
	local localOsVar
	local localOsName
	local localOsVer
	local localOsBitness
	local localOsFamily

	local osInfo="/etc/os-release"

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? -ne 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? -ne 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi
	# Get linux versions
	if [ -f "$osInfo" ]; then
		localOsName=$(grep "^NAME=" "$osInfo")
		localOsName="${localOsName##*=}"
		localOsVer=$(grep "^VERSION=" "$osInfo")
		localOsVer="${localOsVer##*=}"
	elif [ "$localOsVar" == "BusyBox" ]; then
		localOsVer=$(ls --help 2>&1 | head -1 | cut -f2 -d' ')
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	case $localOsVar in
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*|*"CYGWIN*"|*"Microsoft"*|*"WinNT10*")
		if [ "$PROGRAMW6432" != "" ]; then
			localOsBitness=64
			localOsFamily="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			localOsBitness=32
			localOsFamily="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$localOsVar" == "BusyBox" ]; then
			localOsFamily="Unix"
		fi
		;;
		*)
		localOsFamily="Unix"
		if uname -m | grep '64' > /dev/null 2>&1; then
			localOsBitness=64
		else
			localOsBitness=32
		fi
		;;
	esac

	echo "$localOsVar ($localOsName $localOsVer) $localOsBitness-bit $localOsFamily"
}

GetOs

ENDSSH
	if [ $? -ne 0 ]; then
		Logger "Cannot connect to remote system [$REMOTE_HOST] port [$REMOTE_PORT] as [$REMOTE_USER]." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "ERROR"
		fi
		exit 1
	fi


	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		remoteOsVar="$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")"
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
			*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
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
			if [ "$IGNORE_OS_TYPE" == true ]; then		#DOC: Undocumented debug only setting
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
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &

	ExecTasks $! "${FUNCNAME[0]}" false 0 0 0 $hardMaxTime true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ]; then
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == true ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand {
	local command="${1}" # Command to run
	local hardMaxTime="${2}" # Max time to wait for command to compleet


	if [ "$REMOTE_OPERATION" != true ]; then
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
	cmd=$SSH_CMD' "env LC_ALL=C env _REMOTE_TOKEN="'$_REMOTE_TOKEN'" $command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	ExecTasks $! "${FUNCNAME[0]}" false  0 0 0 $hardMaxTime true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ] && ([ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ])
	then
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == true ] && [ $retval -ne 0 ]; then
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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
	fi
}

function CheckConnectivityRemoteHost {

	local retval


		if [ "$REMOTE_HOST_PING" != false ] && [ "$REMOTE_OPERATION" != false ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
}

function CheckConnectivity3rdPartyHosts {

	local remote3rdPartySuccess
	local retval
	local i


		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
				retval=$?
				if [ $retval -ne 0 ]; then
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
}

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
		str="${rest%%$PATH_SEPARATOR_CHAR*}"
		# Handle the last case
		if [ "$rest" == "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest="${rest#*$PATH_SEPARATOR_CHAR}"
		fi
			if [ "$RSYNC_PATTERNS" == "" ]; then
			RSYNC_PATTERNS="--$patternType=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --$patternType=\"$str\""
		fi
	done
	set +f
}

function RsyncPatternsFromAdd {
	local patternType="${1}"
	local patternFrom="${2}"

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename "$patternFrom")" == "$patternFrom" ]; then
		patternFrom="$(dirname "$CONFIG_FILE")/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --$patternType-from=\"$patternFrom\""
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
			RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
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
		# osync target-helper specific clause
		if [ "$_SYNC_ON_CHANGES" != "target" ]; then
			Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
		fi
	fi
}

function PreInit {

	local compressionString

	## SSH compression
	if [ "$SSH_COMPRESSION" != false ]; then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Ignore SSH known host verification
	if [ "$SSH_IGNORE_KNOWN_HOSTS" == true ]; then
		SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
	fi

	## SSH ControlMaster Multiplexing
	if [ "$SSH_CONTROLMASTER" == true ]; then
		SSH_OPTS="$SSH_OPTS -o ControlMaster=auto -o ControlPersist=yes -o ControlPath=\"$RUN_DIR/$PROGRAM.ctrlm.%r@%h.$SCRIPT_PID.$TSTAMP\""
	fi

	## Optional SSH arguments
	if [ "$SSH_OPTIONAL_ARGS" != "" ]; then
		SSH_OPTS="$SSH_OPTS $SSH_OPTIONAL_ARGS"
	fi

	## Support for older config files without RSYNC_EXECUTABLE option
	if [ "$RSYNC_EXECUTABLE" == "" ]; then
		RSYNC_EXECUTABLE=rsync
	fi

	## Sudo execution option
	if [ "$SUDO_EXEC" == true ]; then
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

	# Define remote commands
	if [ -f "$SSH_RSA_PRIVATE_KEY" ]; then
		SSH_CMD="$(type -p ssh) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
	elif [ -f "$SSH_PASSWORD_FILE" ]; then
		SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP -q $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p scp) $SSH_COMP -q -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP -q $SSH_OPTS -p $REMOTE_PORT"
	else
		SSH_PASSWORD=""
		SSH_CMD=""
		SCP_CMD=""
		RSYNC_SSH_CMD=""
	fi
}

function SetCompression {
	## Busybox fix (Termux xz command does not support compression at all)
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

	if [ ".${ALERT_LOG_FILE##*.}" != "$COMPRESSION_EXTENSION" ]; then
		ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
	fi
}

function InitLocalOSDependingSettings {

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "Microsoft" ] || [ "$LOCAL_OS" == "WinNT10" ]; then

		# Newer bash on Win10 finally uses integrated find command instead of windows one
		if [ -f "/usr/bin/find" ]; then
			FIND_CMD="/usr/bin/find"
		elif [ -f "/bin/find" ]; then
			FIND_CMD="/bin/find"
		else
			FIND_CMD="$(dirname $BASH)/find"
		fi

		# Newer bash on Windows 10 uses integrated ping whereas cygwin & msys use Windows version
		if [ "$LOCAL_OS" == "WinNT10" ]; then
			PING_CMD="ping -c 2 -i 1"
		else
			PING_CMD='$SYSTEMROOT\system32\ping -n 2'
		fi

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
		SED_REGEX_ARG="-E"
	else
		# Tested on GNU stat, busybox and Cygwin
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
		SED_REGEX_ARG="-r"
	fi

	# Set compression first time when we know what local os we have
	SetCompression
}

# Gets executed regardless of the need of remote connections. It is just that this code needs to get executed after we know if there is a remote os, and if yes, which one
function InitRemoteOSDependingSettings {

	if [ "$REMOTE_OS" == "msys" ] || [ "$REMOTE_OS" == "Cygwin" ]; then
		REMOTE_FIND_CMD="$(dirname $BASH)/find"
	else
		REMOTE_FIND_CMD=find
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$REMOTE_OS" == "MacOSX" ] || [ "$REMOTE_OS" == "BSD" ]; then
		REMOTE_STAT_CMD="stat -f \"%Sm\""
		REMOTE_STAT_CTIME_MTIME_CMD="stat -f \\\"%N;%c;%m\\\""
	else
		REMOTE_STAT_CMD="stat --format %y"
		REMOTE_STAT_CTIME_MTIME_CMD="stat -c \\\"%n;%Z;%Y\\\""
	fi

	## Set rsync default arguments (complete with -r or -d depending on recursivity later)
	RSYNC_DEFAULT_ARGS="-ltD -8"
	if [ "$_DRYRUN" == true ]; then
		RSYNC_DRY_ARG="-n"
		DRY_WARNING="/!\ DRY RUN "
	else
		RSYNC_DRY_ARG=""
	fi

	RSYNC_ATTR_ARGS=""
	if [ "$PRESERVE_PERMISSIONS" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -p"
	fi
	if [ "$PRESERVE_OWNER" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -o"
	fi
	if [ "$PRESERVE_GROUP" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -g"
	fi
	if [ "$PRESERVE_EXECUTABILITY" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" --executability"
	fi
	if [ "$PRESERVE_ACL" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ] && [ "$LOCAL_OS" != "Android" ] && [ "$REMOTE_OS" != "Android" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
		else
			Logger "Disabling ACL synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"

		fi
	fi
	if [ "$PRESERVE_XATTR" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
		else
			Logger "Disabling extended attributes synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$RSYNC_COMPRESS" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -zz --skip-compress=3fr/3g2/3gp/3gpp/7z/aac/ace/amr/apk/appx/appxbundle/arc/arj/arw/asf/avi/bz/bz2/cab/cr2/crypt[5678]/dat/dcr/deb/dmg/drc/ear/erf/flac/flv/gif/gpg/gz/iiq/jar/jp2/jpeg/jpg/h26[45]/k25/kdc/kgb/lha/lz/lzma/lzo/lzx/m4[apv]/mef/mkv/mos/mov/mp[34]/mpeg/mp[gv]/msi/nef/oga/ogg/ogv/opus/orf/pak/pef/png/qt/rar/r[0-9][0-9]/rz/rpm/rw2/rzip/s7z/sfark/sfx/sr2/srf/svgz/t[gb]z/tlz/txz/vob/wim/wma/wmv/xz/zip"
		else
			Logger "Disabling compression skips on synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$COPY_SYMLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -K"
	fi
	if [ "$RSYNC_OPTIONAL_ARGS" != "" ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" "$RSYNC_OPTIONAL_ARGS
	fi
	if [ "$PRESERVE_HARDLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -H"
	fi
	if [ "$CHECKSUM" == true ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --checksum"
	fi
	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --bwlimit=$BANDWIDTH"
	fi

	if [ "$PARTIAL" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
		RSYNC_PARTIAL_EXCLUDE="--exclude=\"$PARTIAL_DIR\""
	fi

	if [ "$DELTA_COPIES" != false ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --no-whole-file"
	else
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --whole-file"
	fi

	# Set compression options again after we know what remote OS we are dealing with
	SetCompression

	# Set recursive options
	RSYNC_DEFAULT_NONRECURSIVE_ARGS="-d $RSYNC_DEFAULT_ARGS"
	RSYNC_DEFAULT_ARGS="-r $RSYNC_DEFAULT_ARGS"
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
function VerComp () {
	if [ "$1" == "" ] || [ "$2" == "" ]; then
		Logger "Bogus Vercomp values [$1] and [$2]." "WARN"
		return 1
	fi

	if [[ "$1" == "$2" ]]
		then
			echo 0
		return
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
			echo 1
			return
		fi
		if ((10#${ver1[i]} < 10#${ver2[i]}))
		then
			echo 2
			return
		fi
	done

	echo 0
	return
}

function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? -eq 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		if [ $noError == true ]; then
			Logger "Cannot get value for [$name] in config file [$file]." "NOTICE"
		else
			Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
		fi
	fi
}


function SetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local value="${3}"
	local separator="${4:-#}"

	if [ -f "$file" ]; then
		if grep "^$name=" "$file" > /dev/null 2>&1; then
			# Using -i.tmp for BSD compat
			sed -i.tmp "s$separator^$name=.*$separator$name=$value$separator" "$file"
			if [ $? -ne 0 ]; then
				Logger "Cannot update value [$name] to [$value] in config file [$file]." "ERROR"
			fi
			rm -f "$file.tmp"
			Logger "Set [$name] to [$value] in config file [$file]." "DEBUG"
		else
			echo "$name=$value" >> "$file"
			if [ $? -ne 0 ]; then
				Logger "Cannot create value [$name] to [$value] in config file [$file]." "ERROR"
			fi
		fi
	else
		echo "$name=$value" > "$file"
		if [ $? -ne 0 ]; then
			Logger "Config file [$file] does not exist. Failed to create it witn value [$name]." "ERROR"
		fi
	fi
}

# Function can replace [ -f /some/file* ] tests
# Modified version of http://stackoverflow.com/a/6364244/2635443
function WildcardFileExists () {
	local file="${1}"
	local exists=0

	for f in $file; do
		## Check if the glob gets expanded to existing files.
		## If not, f here will be exactly the pattern above
		## and the exists test will evaluate to false.
		if [ -e "$f" ]; then
			exists=1
			break
		fi
	done

	if [ $exists -eq 1 ]; then
		echo 1
	else
		echo 0
	fi
}

# Some MacOS versions might loose file ownsership when using mv from /tmp dir (see #175)
# This is a "mv" function wrapper that helps out with macOS
function FileMove () {
	local source="${1}"
	local dest="${2}"

	# If file is symlink or OS is not Mac, just make a standard mv
	if [ -L "$source" ] || [ "$LOCAL_OS" != "MacOSX" ]; then
		mv -f "$source" "$dest"
		return $?
	elif [ -w "$source" ]; then
		[ -f "$dest" ] && rm -f "$dest"
		cp -p "$source" "$dest" && rm -f "$source"
		return $?
	else
		return -1
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
		if [ "$RUN_AFTER_CMD_ON_ERROR" == true ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with errors." "ERROR"
		SendAlert
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		if [ "$RUN_AFTER_CMD_ON_ERROR" == true ]; then
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

	if [ "$REMOTE_OPERATION" == true ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start backup." "CRITICAL"
			exit 1
		fi

		if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
			Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
			exit 1
		fi
	else
		if [ "$SQL_BACKUP" != false ]; then
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

	if [ "$FILE_BACKUP" != false ]; then
		if ! type rsync > /dev/null 2>&1 ; then
			Logger "rsync not present. Cannot backup files." "CRITICAL"
			CAN_BACKUP_FILES=false
		fi
	fi

	if [ "$ENCRYPTION" == true ]; then
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

	local test
	local booleans
	local num_vars

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	# v2 config will use true / false instead of yes / no
	# Check all variables that should contain "yes" or "no", true or false
	declare -a booleans=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SUDO_EXEC DATABASES_ALL PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
	for i in "${booleans[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ] && [ \"\$$i\" != true ] && [ \"\$$i\" != false ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
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

	if [ "$FILE_BACKUP" == true ]; then
		if [ "$DIRECTORY_LIST" == "" ] && [ "$RECURSIVE_DIRECTORY_LIST" == "" ]; then
			Logger "No directories specified in config file, no files to backup." "ERROR"
			CAN_BACKUP_FILES=false
		fi
	fi

	if [ "$REMOTE_OPERATION" == true ] && [ ! -f "$SSH_RSA_PRIVATE_KEY" ]; then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY]. Cannot connect to remote system." "CRITICAL"
		exit 1
	fi

	#WIP: Encryption use key file instead of recipient ?
	#if [ ! -f "$ENCRYPT_GPG_PYUBKEY" ]; then
	#	Logger "Cannot find gpg pubkey [$ENCRYPT_GPG_PUBKEY]. Cannot encrypt backup files." "CRITICAL"
	#	exit 1
	#fi

	if [ "$SQL_BACKUP" == true ] && [ "$SQL_STORAGE" == "" ]; then
		Logger "SQL_STORAGE not defined." "CRITICAL"
		exit 1
	fi

	if [ "$FILE_BACKUP" == true ] && [ "$FILE_STORAGE" == "" ]; then
		Logger "FILE_STORAGE not defined." "CRITICAL"
		exit 1
	fi

	if [ "$ENCRYPTION" == true ]; then
		if [ "$CRYPT_STORAGE" == "" ]; then
			Logger "CRYPT_STORAGE not defined." "CRITICAL"
			exit 1
		fi
		if [ "$GPG_RECIPIENT" == "" ]; then
			Logger "No GPG recipient defined." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$REMOTE_OPERATION" == true ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi
}

# Change all booleans with "yes" or "no" to true / false for v2 config syntax compatibility
function UpdateBooleans {
	local update
	local booleans

	declare -a booleans=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SUDO_EXEC DATABASES_ALL PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)

	for i in "${booleans[@]}"; do
		update="if [ \"\$$i\" == \"yes\" ]; then $i=true; fi; if [ \"\$$i\" == \"no\" ]; then $i=false; fi"
		eval "$update"
	done
}

function CheckRunningInstances {

	if [ -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID" ]; then
		pid="$(head -c16384 "$RUN_DIR/$PROGRAM.$INSTANCE_ID")"
		if ps aux | awk '{print $2}' | grep $pid > /dev/null; then
			Logger "Another instance [$INSTANCE_ID] of obackup is already running." "CRITICAL"
			exit 1
		fi
	fi

	echo $SCRIPT_PID > "$RUN_DIR/$PROGRAM.$INSTANCE_ID"
}

function _ListDatabasesLocal {

	local retval
	local sqlCmd

	sqlCmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	Logger "Launching command [$sqlCmd]." "DEBUG"
	eval "$sqlCmd" &
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Listing databases succeeded." "NOTICE"
	else
		Logger "Listing databases failed." "ERROR"
		_LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		return 1
	fi

}

function _ListDatabasesRemote {

	local sqlCmd
	local retval

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	sqlCmd="$SSH_CMD \"env _REMOTE_TOKEN=$_REMOTE_TOKEN mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	Logger "Command output: $sqlCmd" "DEBUG"
	eval "$sqlCmd" &
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Listing databases succeeded." "NOTICE"
	else
		Logger "Listing databases failed." "ERROR"
		Logger "Command output: $sqlCmd" "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		return $retval
	fi
}

function ListDatabases {

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

			if [ "$DATABASES_ALL" == true ]; then
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

	local cmd
	local directories
	local directory
	local retval
	local successfulRun=false
	local failuresPresent=false

	IFS=$PATH_SEPARATOR_CHAR read -r -a directories <<< "$RECURSIVE_DIRECTORY_LIST"
	for directory in "${directories[@]}"; do
		# Make sure there is only one trailing slash
		directory="${directory%/}/"
		# No sudo here, assuming you should have all necessary rights for local checks
		cmd="$FIND_CMD -L $directory -mindepth 1 -maxdepth 1 -type d >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		Logger "Launching command [$cmd]." "DEBUG"
		eval "$cmd"
		retval=$?
		if  [ $retval -ne 0 ]; then
			Logger "Could not enumerate directories in [$directory]." "ERROR"
			 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
			fi
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
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

	local retval

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env RECURSIVE_DIRECTORY_LIST="'$RECURSIVE_DIRECTORY_LIST'" env PATH_SEPARATOR_CHAR="'$PATH_SEPARATOR_CHAR'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
_REMOTE_TOKEN="(o_0)"

## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
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
		# Make sure there is only one trailing slash
		directory="${directory%/}/"
		cmd="$REMOTE_FIND_CMD -L \"$directory\" -mindepth 1 -maxdepth 1 -type d"
		Logger "Launching command [$cmd]." "DEBUG"
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
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP ]; then
			Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
	fi
	return $retval
}

function ListRecursiveBackupDirectories {

	local output_file
	local file_exclude
	local excluded
	local fileArray

	if [ "$RECURSIVE_DIRECTORY_LIST" != "" ]; then

		# Return values from subfunctions can be 0 (no error), 1 (only errors) or 2 (some errors). Do process output except on 1 return code
		Logger "Listing directories to backup." "NOTICE"
		if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]; then
			_ListRecursiveBackupDirectoriesLocal &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
			if [ $? -eq 1 ]; then
				output_file=""
			else
				output_file="$RUN_DIR/$PROGRAM._ListRecursiveBackupDirectoriesLocal.$SCRIPT_PID.$TSTAMP"
			fi
		elif [ "$BACKUP_TYPE" == "pull" ]; then
			_ListRecursiveBackupDirectoriesRemote &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
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


	local cmd
	local retval

	# No sudo here, assuming you should have all the necessary rights
	# This is not pretty, but works with all supported systems
	cmd="du -cs $dirList | tail -n1 | cut -f1 > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	Logger "Launching command [$cmd]." "DEBUG"
	eval "$cmd" &
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
	# $cmd will return 0 even if some errors found, so we need to check if there is an error output
	retval=$?
	if  [ $retval -ne  0 ] || [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "Could not get files size for some or all local directories." "ERROR"
		 _LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
	else
		Logger "File size fetched successfully." "NOTICE"
	fi

	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		TOTAL_FILES_SIZE="$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)"
		if [ $(IsInteger $TOTAL_FILES_SIZE) -eq 0 ]; then
			TOTAL_FILES_SIZE="$(HumanToNumeric $TOTAL_FILES_SIZE)"
		fi
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function _GetDirectoriesSizeRemote {
	local dirList="${1}"

	local cmd
	local retval

	# Error output is different from stdout because not all files in list may fail at once
$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
dirList="'$dirList'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
_REMOTE_TOKEN="(o_0)"

## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
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
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if  [ $retval -ne 0 ] || [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "Could not get files size for some or all remote directories." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
	else
		Logger "File size fetched successfully." "NOTICE"
	fi
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		TOTAL_FILES_SIZE="$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)"
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
		if [ "$FILE_BACKUP" != false ]; then
			_GetDirectoriesSizeLocal "$FILE_SIZE_LIST"
		fi
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$FILE_BACKUP" != false ]; then
			_GetDirectoriesSizeRemote "$FILE_SIZE_LIST"
		fi
	fi
}

function _CreateDirectoryLocal {
	local dirToCreate="${1}"

	local retval

	if [ ! -d "$dirToCreate" ]; then
		# No sudo, you should have all necessary rights
		mkdir -p "$dirToCreate" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1 &
		ExecTasks $! "${FUNCNAME[0]}" false 0 0 720 1800 true $SLEEP_TIME $KEEP_LOGGING
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create directory [$dirToCreate]" "CRITICAL"
			if [ -f $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP ]; then
				Logger "Truncated output: $(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
			fi
			return $retval
		fi
	fi
}

function _CreateDirectoryRemote {
	local dirToCreate="${1}"

	local cmd
	local retval

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env dirToCreate="'$dirToCreate'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &
_REMOTE_TOKEN="(o_0)"

## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
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
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 720 1800 true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		return $retval
	fi
}

function CreateStorageDirectories {

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != false ]; then
			_CreateDirectoryLocal "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != false ]; then
			_CreateDirectoryLocal "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == true ]; then
			_CreateDirectoryLocal "$CRYPT_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != false ]; then
			_CreateDirectoryRemote "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_SQL=false
			fi
		fi
		if [ "$FILE_BACKUP" != false ]; then
			_CreateDirectoryRemote "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				CAN_BACKUP_FILES=false
			fi
		fi
		if [ "$ENCRYPTION" == true ]; then
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


	local retval

	if [ -d "$pathToCheck" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		$DF_CMD "$pathToCheck" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &
		ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
		retval=$?
		if [ $retval -ne 0 ]; then
			DISK_SPACE=0
			Logger "Cannot get disk space in [$pathToCheck] on local system." "ERROR"
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
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


	local cmd
	local retval

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env DF_CMD="'$DF_CMD'" \
env pathToCheck="'$pathToCheck'" $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" &
_REMOTE_TOKEN="(o_0)"

## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
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
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -ne 0 ]; then
		DISK_SPACE=0
		Logger "Cannot get disk space in [$pathToCheck] on remote system." "ERROR"
		Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
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


	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != false ]; then
			GetDiskSpaceLocal "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				SQL_DISK_SPACE=0
				CAN_BACKUP_SQL=false
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != false ]; then
			GetDiskSpaceLocal "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				FILE_DISK_SPACE=0
				CAN_BACKUP_FILES=false
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
		if [ "$ENCRYPTION" != false ]; then
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
		if [ "$SQL_BACKUP" != false ]; then
			GetDiskSpaceRemote "$SQL_STORAGE"
			if [ $? -ne 0 ]; then
				SQL_DISK_SPACE=0
			else
				SQL_DISK_SPACE=$DISK_SPACE
				SQL_DRIVE=$DRIVE
			fi
		fi
		if [ "$FILE_BACKUP" != false ]; then
			GetDiskSpaceRemote "$FILE_STORAGE"
			if [ $? -ne 0 ]; then
				FILE_DISK_SPACE=0
			else
				FILE_DISK_SPACE=$DISK_SPACE
				FILE_DRIVE=$DRIVE
			fi
		fi
		if [ "$ENCRYPTION" != false ]; then
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

	if [ "$SQL_BACKUP" != false ] && [ $CAN_BACKUP_SQL == true ]; then
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

	if [ "$FILE_BACKUP" != false ] && [ $CAN_BACKUP_FILES == true ]; then
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

	if [ "$ENCRYPTION" == true ]; then
		if [ "$SQL_BACKUP" != false ]; then
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

		if [ "$FILE_BACKUP" != false ]; then
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

	if [ $BACKUP_SIZE_MINIMUM -gt $((TOTAL_DATABASES_SIZE+TOTAL_FILES_SIZE)) ] && [ "$GET_BACKUP_SIZE" != false ]; then
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

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > $SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
		fi
		Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
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

	local drySqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
	local sqlCmd="mysqldump -u $SQL_USER $exportOptions --databases $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS $encryptOptions | $SSH_CMD 'env _REMOTE_TOKEN=$_REMOTE_TOKEN $COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension\" > /dev/null' 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
		fi
		Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
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

	local drySqlCmd=$SSH_CMD' "env _REMOTE_TOKEN=$_REMOTE_TOKEN mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'
	local sqlCmd=$SSH_CMD' "env _REMOTE_TOKEN=$_REMOTE_TOKEN mysqldump -u '$SQL_USER' '$exportOptions' --databases '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS' '$encryptOptions'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION$encryptExtension'" 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP'"'

	if [ $_DRYRUN == false ]; then
		Logger "Launching command [$sqlCmd]." "DEBUG"
		eval "$sqlCmd" &
	else
		Logger "Launching command [$drySqlCmd]." "DEBUG"
		eval "$drySqlCmd" &
	fi
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP" ]; then
		if [ $_DRYRUN == false ]; then
			 _LOGGER_SILENT=true Logger "Command was [$sqlCmd]." "WARN"
		else
			 _LOGGER_SILENT=true Logger "Command was [$drySqlCmd]." "WARN"
		fi
		Logger "Truncated error output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP)" "ERROR"
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

	if [ "$ENCRYPTION" == true ]; then
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
				Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "DEBUG"
				errorCounter=$((errorCounter+1))
			else
				successCounter=$((successCounter+1))
			fi
		fi
	#TODO: This redirection does not work with busybox since there is no subshell support
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
		ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_TOTAL $HARD_MAX_EXEC_TIME_TOTAL true $SLEEP_TIME $KEEP_LOGGING true false false $PARALLEL_ENCRYPTION_PROCESSES "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Encryption error." "ERROR"
			# Output file is defined in ParallelExec
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.ExecTasks.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "DEBUG"
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
				Logger "Truncated output\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
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

		ExecTasks "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.parallel.$SCRIPT_PID.$TSTAMP" "${FUNCNAME[0]}" true 0 0 $softMaxExecTime $hardMaxExecTime true $SLEEP_TIME $KEEP_LOGGING true false $PARALLEL_ENCRYPTION_PROCESSES
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Decrypting error.." "ERROR"
			# Output file is defined in ParallelExec
			Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.ParallelExec.EncryptFiles.$SCRIPT_PID.$TSTAMP)" "DEBUG"
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
	local recursive="${3:-true}"	# Backup only files at toplevel of directory


	local rsyncCmd
	local retval

	local rsyncArgs

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
	if [ $recursive == false ]; then
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion
		rsyncArgs="$RSYNC_DEFAULT_ARGS -f '- /*/*/'"
	else
		rsyncArgs="$RSYNC_DEFAULT_ARGS"
	fi

	# Creating subdirectories because rsync cannot handle multiple subdirectory creation
	if [ "$BACKUP_TYPE" == "local" ]; then
		_CreateDirectoryLocal "$destinationDir"
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $rsyncArgs $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$sourceDir\" \"$destinationDir\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_CreateDirectoryLocal "$destinationDir"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		sourceDir=$(EscapeSpaces "$sourceDir")
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $rsyncArgs $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$sourceDir\" \"$destinationDir\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		destinationDir=$(EscapeSpaces "$destinationDir")
		_CreateDirectoryRemote "$destinationDir"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) $rsyncArgs $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$sourceDir\" \"$REMOTE_USER@$REMOTE_HOST:$destinationDir\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	fi

	Logger "Launching command [$rsyncCmd]." "DEBUG"
	eval "$rsyncCmd" &
	ExecTasks $! "${FUNCNAME[0]}" false 0 0 $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed to backup [$sourceDir] to [$destinationDir]." "ERROR"
		 _LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		Logger "Truncated output:\n $(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
	else
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
		Logger "File backup succeed." "NOTICE"
	fi

	return $retval
}

function FilesBackup {

	local backupTask
	local backupTasks
	local destinationDir
	local encryptDir


	IFS=$PATH_SEPARATOR_CHAR read -r -a backupTasks <<< "$FILE_BACKUP_TASKS"
	for backupTask in "${backupTasks[@]}"; do
	# Backup directories from simple list

		if [ "$KEEP_ABSOLUTE_PATHS" != false ]; then
			# Fix for backup of '/'
			if [ "${backupTask#/}/" == "/" ]; then
				destinationDir="$FILE_STORAGE/"
			else
				destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}/")
			fi
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning file backup of [$backupTask] to [$destinationDir] as $BACKUP_TYPE backup." "NOTICE"
		if [ "$ENCRYPTION" == true ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == true ] && [ "$BACKUP_TYPE" == "pull" ]; then
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
	# Backup recursive directories without recursion

		if [ "$KEEP_ABSOLUTE_PATHS" != false ]; then
			# Fix for backup of '/'
			if [ "${backupTask#/}/" == "/" ]; then
				destinationDir="$FILE_STORAGE/"
			else
				destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}/")
			fi
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning non recursive file backup of [$backupTask] to [$destinationDir] as $BACKUP_TYPE backup." "NOTICE"
		if [ "$ENCRYPTION" == true ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" false true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" false
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == true ] && [ "$BACKUP_TYPE" == "pull" ]; then
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

		if [ "$KEEP_ABSOLUTE_PATHS" != false ]; then
			# Fix for backup of '/'
			if [ "${backupTask#/}/" == "/" ]; then
				destinationDir="$FILE_STORAGE/"
			else
				destinationDir=$(dirname "$FILE_STORAGE/${backupTask#/}/")
			fi
			encryptDir="$FILE_STORAGE/${backupTask#/}"
		else
			destinationDir="$FILE_STORAGE"
			encryptDir="$FILE_STORAGE"
		fi

		Logger "Beginning recursive child file backup of [$backupTask] to [$destinationDir] as $BACKUP_TYPE backup." "NOTICE"
		if [ "$ENCRYPTION" == true ] && ([ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "push" ]); then
			EncryptFiles "$backupTask" "$CRYPT_STORAGE" "$GPG_RECIPIENT" true true
			if [ $? -eq 0 ]; then
				Rsync "$CRYPT_STORAGE/$backupTask" "$destinationDir" true
			else
				Logger "backup failed." "ERROR"
			fi
		elif [ "$ENCRYPTION" == true ] && [ "$BACKUP_TYPE" == "pull" ]; then
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
					ExecTasks $! "${FUNCNAME[0]}" false 0 0 3600 0 true $SLEEP_TIME $KEEP_LOGGING
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
				ExecTasks $! "${FUNCNAME[0]}" false 0 0 3600 0 true $SLEEP_TIME $KEEP_LOGGING
				if [ $? -ne 0 ]; then
					Logger "Cannot move [$path] to [$backup.$PROGRAM.$copy]." "ERROR"
					_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
				fi

			fi
			copy=$((copy-1))
		done

		# TODO: Describe new behavior: Always copy instead of move in order to make delta copies
		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		# Whereas sql files will always be moved because we don't do deltas on sql files
		if [[ $backup == *.sql.* ]]; then
			cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 3600 0 true $SLEEP_TIME $KEEP_LOGGING
			if [ $? -ne 0 ]; then
				Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			fi

		else
		#elif [ "$REMOTE_OPERATION" == true ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			Logger "Launching command [$cmd]." "DEBUG"
			eval "$cmd" &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 3600 0 true $SLEEP_TIME $KEEP_LOGGING
			if [ $? -ne 0 ]; then
				Logger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			fi

		#else
		#	cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
		#	Logger "Launching command [$cmd]." "DEBUG"
		#	eval "$cmd" &
		#	ExecTasks $! "${FUNCNAME[0]}" false 0 0 3600 0 true $SLEEP_TIME $KEEP_LOGGING
		#	if [ $? -ne 0 ]; then
		#		Logger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
		#		_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
		#	fi
		fi
	done
}

function _RotateBackupsRemote {
	local backupPath="${1}"
	local rotateCopies="${2}"

$SSH_CMD env _REMOTE_TOKEN=$_REMOTE_TOKEN \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" env rotateCopies="'$rotateCopies'" env backupPath="'$backupPath'" \
$COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
_REMOTE_TOKEN="(o_0)"

## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
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

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
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
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

function _RotateBackupsRemoteSSH {
	local backup
	local copy
	local cmd
	local path

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
			copy=$((copy-1))
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

		else
		#elif [ "$REMOTE_OPERATION" == true ]; then
			cmd="cp -R \"$backup\" \"$backup.$PROGRAM.1\""
			RemoteLogger "Launching command [$cmd]." "DEBUG"
			eval "$cmd"
			if [ $? -ne 0 ]; then
				RemoteLogger "Cannot copy [$backup] to [$backup.$PROGRAM.1]." "ERROR"
				RemoteLogger "Command was [$cmd]." "WARN"
			fi

		#else
		#	cmd="mv \"$backup\" \"$backup.$PROGRAM.1\""
		#	RemoteLogger "Launching command [$cmd]." "DEBUG"
		#	eval "$cmd"
		#	if [ $? -ne 0 ]; then
		#		RemoteLogger "Cannot move [$backup] to [$backup.$PROGRAM.1]." "ERROR"
		#		RemoteLogger "Command was [$cmd]." "WARN"
		#	fi
		fi
	done
}

	_RotateBackupsRemoteSSH

ENDSSH

	ExecTasks $! "${FUNCNAME[0]}" false 0 0 1800 0 true $SLEEP_TIME $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		Logger "Could not rotate backups in [$backupPath]." "ERROR"
		Logger "Truncated output:\n$(head -c16384 $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
	else
		Logger "Remote rotation succeed." "NOTICE"
	fi        ## Need to add a trivial sleep time to give ssh time to log to local file
	#sleep 5


}

#TODO: test find cmd for backup rotation with regex on busybox / mac
function RotateBackups {
	local backupPath="${1}"
	local rotateCopies="${2}"


	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		Logger "Rotating local backups in [$backupPath] for [$rotateCopies] copies." "NOTICE"
		_RotateBackupsLocal "$backupPath" "$rotateCopies"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		Logger "Rotating remote backups in [$backupPath] for [$rotateCopies] copies." "NOTICE"
		_RotateBackupsRemote "$backupPath" "$rotateCopies"
	fi
}

function Init {

	local uri
	local hosturiandpath
	local hosturi

	## Test if target dir is a ssh uri, and if yes, break it down it its values
	if [ "${REMOTE_SYSTEM_URI:0:6}" == "ssh://" ] && [ "$BACKUP_TYPE" != "local" ]; then
		REMOTE_OPERATION=true

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

	## Add update to default RSYNC_TYPE_ARGS
	RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" -u"

	if [ $_LOGGER_VERBOSE == true ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" -i"
	fi

	if [ "$DELETE_VANISHED_FILES" == true ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --delete"
	fi

	if [ $stats == true ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --stats"
	fi

	## Fix for symlink to directories on target cannot get updated
	RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --force"
}

function Main {

	if [ "$SQL_BACKUP" != false ] && [ $CAN_BACKUP_SQL == true ]; then
		ListDatabases
	fi
	if [ "$FILE_BACKUP" != false ] && [ $CAN_BACKUP_FILES == true ]; then
		ListRecursiveBackupDirectories
		if [ "$GET_BACKUP_SIZE" != false ]; then
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

	if [ "$CREATE_DIRS" != false ]; then
		CreateStorageDirectories
	fi
	CheckDiskSpace

	# Actual backup process
	if [ "$SQL_BACKUP" != false ] && [ $CAN_BACKUP_SQL == true ]; then
		if [ $_DRYRUN == false ] && [ "$ROTATE_SQL_BACKUPS" == true ]; then
			RotateBackups "$SQL_STORAGE" "$ROTATE_SQL_COPIES"
		fi
		BackupDatabases
	fi

	if [ "$FILE_BACKUP" != false ] && [ $CAN_BACKUP_FILES == true ]; then
		if [ $_DRYRUN == false ] && [ "$ROTATE_FILE_BACKUPS" == true ]; then
			RotateBackups "$FILE_STORAGE" "$ROTATE_FILE_COPIES"
		fi
		## Add Rsync include / exclude patterns
		RsyncPatterns
		FilesBackup
	fi
}

function Usage {


	if [ "$IS_STABLE" != true ]; then
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

#### SCRIPT ENTRY POINT ####
trap TrapQuit EXIT

# Command line argument flags
_DRYRUN=false
no_maxtime=false
stats=false
partial_transfers=false
delete_vanished=false
dont_get_backup_size=false
_DECRYPT_MODE=false
DECRYPT_PATH=""
_ENCRYPT_MODE=false

function GetCommandlineArguments {
	local isFirstArgument=true

	if [ $# -eq 0 ]; then
		Usage
	fi

	for i in "$@"; do
		case "$i" in
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
			stats=true
			;;
			--partial)
			partial_transfers=true
			;;
			--no-maxtime)
			no_maxtime=true
			;;
			--delete)
			delete_vanished=true
			;;
			--dontgetsize)
			dont_get_backup_size=true
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
			;;
			*)
			if [ $isFirstArgument == false ]; then
				Logger "Unknown option '$i'" "CRITICAL"
				Usage
			fi
			;;
		esac
		isFirstArgument=false
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

# Reload GetCommandlineArguments to override config file with runtime arguments
GetCommandlineArguments "$@"

if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "${HOME}" != "" ] && [ -w "${HOME}" ]); then
		LOG_FILE="${HOME}/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE=./$PROGRAM.$INSTANCE_ID.log
	fi
else
	LOG_FILE="$LOGFILE"
fi

# v2.3 config syntax compatibility
UpdateBooleans

if [ ! -w "$(dirname $LOG_FILE)" ]; then
	echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
	Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi


if [ $no_maxtime == true ]; then
	SOFT_MAX_EXEC_TIME_DB_TASK=0
	SOFT_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_DB_TASK=0
	HARD_MAX_EXEC_TIME_FILE_TASK=0
	HARD_MAX_EXEC_TIME_TOTAL=0
fi

if [ $partial_transfers == true ]; then
	PARTIAL=true
fi

if [ $delete_vanished == true ]; then
	DELETE_VANISHED_FILES=true
fi

if [ $dont_get_backup_size == true ]; then
	GET_BACKUP_SIZE=false
fi

if [ "$IS_STABLE" != true ]; then
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
RunBeforeHook
Main
