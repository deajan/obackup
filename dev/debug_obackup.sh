#!/usr/bin/env bash

###### Remote push/pull (or local) backup script for files & databases
PROGRAM="obackup"
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_VERSION=2.0-RC1
PROGRAM_BUILD=2016071901
IS_STABLE=yes

## FUNC_BUILD=2016071901
## BEGIN Generic functions for osync & obackup written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

#### obackup & osync specific code BEGIN ####

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log will not be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

#### obackup & osync specific code END ####

#### MINIMAL-FUNCTION-SET BEGIN ####

# Environment variables
_DRYRUN=0
_SILENT=0

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=0
WARN_ALERT=0

## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.1
	_VERBOSE=0
else
	SLEEP_TIME=1
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=1
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

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
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG
	sleep .1
}

# Sub function of Logger
function _Logger {
	local svalue="${1}" # What to log to stdout
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	local evalue="${3}" # What to log to stderr
	echo -e "$lvalue" >> "$LOG_FILE"

	# <OSYNC SPECIFIC> Special case in daemon mode where systemctl doesn't need double timestamps
	if [ "$sync_on_changes" == "1" ]; then
		cat <<< "$evalue" 1>&2	# Log to stderr in daemon mode
	elif [ "$_SILENT" -eq 0 ]; then
		echo -e "$svalue"
	fi
}

# General log function with log levels
function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, NOTICE, WARN, ERROR, CRITIAL

	# <OSYNC SPECIFIC> Special case in daemon mode we should timestamp instead of counting seconds
	if [ "$sync_on_changes" == "1" ]; then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi
	# </OSYNC SPECIFIC>

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$level:$value" "$level:$value"
		WARN_ALERT=1
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then		#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then	#__WITH_PARANOIA_DEBUG
			_Logger "$prefix$value"			#__WITH_PARANOIA_DEBUG
			return					#__WITH_PARANOIA_DEBUG
		fi						#__WITH_PARANOIA_DEBUG
	else
		_Logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_Logger "$prefix$value"
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

	if [ "$_SILENT" -eq 1 ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}"
	local self="${2:-false}"

	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			Logger "Launching KillChilds \"$child\" true" "DEBUG"	#__WITH_PARANOIA_DEBUG
			KillChilds "$child" true
		done
	fi

	# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if ( [ "$self" == true ] && eval $PROCESS_TEST_CMD > /dev/null 2>&1); then
		Logger "Sending SIGTERM to process [$pid]." "DEBUG"
		kill -s SIGTERM "$pid"
		if [ $? != 0 ]; then
			sleep 15
			Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
			kill -9 "$pid"
			if [ $? != 0 ]; then
				Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
				return 1
			fi
		fi
		return 0
	else
		return 0
	fi
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local mail_no_attachment=
	local attachment_command=
	local subject=

	# Windows specific settings
	local encryption_string=
	local auth_string=

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
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi
	MAIL_ALERT_MSG="$MAIL_ALERT_MSG"$'\n\n'$(tail -n 50 "$LOG_FILE")
	if [ $ERROR_ALERT -eq 1 ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT -eq 1 ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ "$mail_no_attachment" -eq 0 ]; then
		attachment_command="-a $ALERT_LOG_FILE"
	fi
	if type mutt > /dev/null 2>&1 ; then
		echo "$MAIL_ALERT_MSG" | $(type -p mutt) -x -s "$subject" $DESTINATION_MAILS $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $ALERT_LOG_FILE"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$ALERT_LOG_FILE"
		else
			attachment_command=""
		fi
		echo "$MAIL_ALERT_MSG" | $(type -p mail) $attachment_command -s "$subject" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$MAIL_ALERT_MSG" | $(type -p mail) -s "$subject" $DESTINATION_MAILS
			if [ $? != 0 ]; then
				Logger "Cannot send alert mail via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent alert mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent alert mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "Subject:$subject\r\n$MAIL_ALERT_MSG" | $(type -p sendmail) $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
        if type "mailsend.exe" > /dev/null 2>&1 ; then

		if [ "$SMTP_ENCRYPTION" != "tls" ] && [ "$SMTP_ENCRYPTION" != "ssl" ]  && [ "$SMTP_ENCRYPTION" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$SMTP_ENCRYPTION" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$SMTP_ENCRYPTION" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_USER" != "" ]; then
			auth_string="-auth -user \"$SMTP_USER\" -pass \"$SMTP_PASSWORD\""
		fi
                $(type mailsend.exe) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -sub "$subject" -M "$MAIL_ALERT_MSG" -attach "$attachment" -smtp "$SMTP_SERVER" -port "$SMTP_PORT" $encryption_string $auth_string
                if [ $? != 0 ]; then
                        Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
                else
                        Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
                        return 0
                fi
        fi

	# Windows specific, kept for compatibility (sendemail from http://caspian.dotconf.net/menu/Software/SendEmail/)
	if type sendemail > /dev/null 2>&1 ; then
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_PASSWORD" != "" ]; then
			SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t "$DESTINATION_MAILS" -u "$subject" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$MAIL_ALERT_MSG" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send alert mail via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent alert mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it's critical that no alert can be sent
	Logger "Cannot send alert (neither mutt, mail, sendmail, mailsend, sendemail or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue

	# Delete tmp log file
	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
	fi
}

# Generic email sending function.
# Usage (linux / BSD), attachment is optional, can be "/path/to/my.file" or ""
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file"
# Usage (Windows, make sure you have mailsend.exe in executable path, see http://github.com/muquit/mailsend)
# attachment is optional but must be in windows format like "c:\\some\path\\my.file", or ""
# smtp_server.domain.tld is mandatory, as is smtp_port (should be 25, 465 or 587)
# encryption can be set to tls, ssl or none
# smtp_user and smtp_password are optional
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file" "sender_email@example.com" "smtp_server.domain.tld" "smtp_port" "encryption" "smtp_user" "smtp_password"
function SendEmail {
	local subject="${1}"
	local message="${2}"
	local destination_mails="${3}"
	local attachment="${4}"
	local sender_email="${5}"
	local smtp_server="${6}"
	local smtp_port="${7}"
	local encryption="${8}"
	local smtp_user="${9}"
	local smtp_password="${10}"

	# CheckArguments will report a warning that can be ignored if used in Windows with paranoia debug enabled
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	if [ ! -f "$attachment" ]; then
		attachment_command="-a $ALERT_LOG_FILE"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi

	if type mutt > /dev/null 2>&1 ; then
		echo "$message" | $(type -p mutt) -x -s "$subject" "$destination_mails" $attachment_command
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
		echo "$message" | $(type -p mail) $attachment_command -s "$subject" "$destination_mails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destination_mails"
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
		echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) "$destination_mails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
        if type "mailsend.exe" > /dev/null 2>&1 ; then
		if [ "$sender_email" == "" ]; then
			Logger "Missing sender email." "ERROR"
			return 1
		fi
		if [ "$smtp_server" == "" ]; then
			Logger "Missing smtp port." "ERROR"
			return 1
		fi
		if [ "$smtp_port" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtp_port=25
		fi
		if [ "$encryption" != "tls" ] && [ "$encryption" != "ssl" ]  && [ "$encryption" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$encryption" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$encryption" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$smtp_user" != "" ] && [ "$smtp_password" != "" ]; then
			auth_string="-auth -user \"$smtp_user\" -pass \"$smtp_password\""
		fi
                $(type mailsend.exe) -f "$sender_email" -t "$destination_mails" -sub "$subject" -M "$message" -attach "$attachment" -smtp "$smtp_server" -port "$smtp_port" $encryption_string $auth_string
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

	# If function has not returned 0 yet, assume it's critical that no alert can be sent
	Logger "Cannot send mail (neither mutt, mail, sendmail, sendemail, mailsend (windows) or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"
	if [ $_SILENT -eq 0 ]; then
		echo -e " /!\ ERROR in ${job}: Near line ${line}, exit code ${code}"
	fi
}

function LoadConfigFile {
	local config_file="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG


	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Cannot start." "CRITICAL"
		exit 1
	else
		grep '^[^ ]*=[^;&]*' "$config_file" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" # WITHOUT COMMENTS
		# Shellcheck source=./sync.conf
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$config_file"
}

#### MINIMAL-FUNCTION-SET END ####

function Spinner {
	if [ $_SILENT -eq 1 ]; then
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

function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped
	echo "${string// /\ }"
}

function IsNumeric {
	eval "local value=\"${1}\"" # Needed so variable variables can be processed

	local re="^-?[0-9]+([.][0-9]+)?$"
	if [[ $value =~ $re ]]; then
		echo 1
	else
		echo 0
	fi
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
    local url_encoded="${1//+/ }"

    printf '%b' "${url_encoded//%/\\x}"
}

function CleanUp {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.tmp"
	fi
}

function GetLocalOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local local_os_var=

	local_os_var="$(uname -spio 2>&1)"
	if [ $? != 0 ]; then
		local_os_var="$(uname -v 2>&1)"
		if [ $? != 0 ]; then
			local_os_var="$(uname)"
		fi
	fi

	case $local_os_var in
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
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented option
			Logger "Running on unknown local OS [$local_os_var]." "WARN"
			return
		fi
		Logger "Running on >> $local_os_var << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$local_os_var]." "DEBUG"
}

function GetRemoteOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=
	local remote_os_var=


	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		cmd=$SSH_CMD' "uname -spio" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-1"
		retval=$?
		if [ $retval != 0 ]; then
			cmd=$SSH_CMD' "uname -v" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-2"
			retval=$?
			if [ $retval != 0 ]; then
				cmd=$SSH_CMD' "uname" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-3"
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot Get remote OS type." "ERROR"
				fi
			fi
		fi

		remote_os_var=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID")

		case $remote_os_var in
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
			*"ssh"*|*"SSH"*)
			Logger "Cannot connect to remote system." "CRITICAL"
			exit 1
			;;
			*)
			if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented option
				Logger "Running on unknown remote OS [$remote_os_var]." "WARN"
				return
			fi
			Logger "Running on remote OS failed. Please report to the author if the OS is not supported." "CRITICAL"
			Logger "Remote OS said:\n$remote_os_var" "CRITICAL"
			exit 1
		esac

		Logger "Remote OS: [$remote_os_var]." "DEBUG"
	fi
}

function WaitForTaskCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	Logger "${FUNCNAME[0]} called by [$caller_name]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	while eval "$PROCESS_TEST_CMD" > /dev/null
	do
		Spinner
		exec_time=$(($SECONDS - $seconds_begin))
		if [ $((($exec_time + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_ttime -ne $exec_time ]; then
				log_ttime=$exec_time
				Logger "Current task still running with pid [$pid]." "NOTICE"
			fi
		fi
		if [ $exec_time -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$caller_name] with pid [$pid]." "WARN"
				soft_alert=1
				SendAlert

			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$caller_name] with pid [$pid]. Stopping task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					return 0
				else
					return 1
				fi
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	local retval=$?
	Logger "${FUNCNAME[0]} ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function WaitForCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	Logger "${FUNCNAME[0]} called by [$caller_name]" "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
	local log_time=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	while eval "$PROCESS_TEST_CMD" > /dev/null
	do
		Spinner
		if [ $((($SECONDS + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_time -ne $SECONDS ]; then
				log_time=$SECONDS
				Logger "Current task still running." "NOTICE"
			fi
		fi
		if [ $SECONDS -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time != 0 ]; then
				Logger "Max soft execution time exceeded for script." "WARN"
				soft_alert=1
				SendAlert
			fi
			if [ $SECONDS -gt $hard_max_time ] && [ $hard_max_time != 0 ]; then
				Logger "Max hard execution time exceeded for script in [$caller_name]. Stopping current task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					return 0
				else
					return 1
				fi
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	retval=$?
	Logger "${FUNCNAME[0]} ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
	WaitForTaskCompletion $! 0 $hard_max_time ${FUNCNAME[0]}
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ]; then
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
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "$command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hard_max_time ${FUNCNAME[0]}
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ] && ([ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 180 180 ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				Logger "Cannot ping $REMOTE_HOST" "ERROR"
				return 1
			fi
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote_3rd_party_success=0
			OLD_IFS=$IFS
			IFS=$' \t\n'
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 360 360 ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					Logger "Cannot ping 3rd party host $i" "NOTICE"
				else
					remote_3rd_party_success=1
				fi
			done
			IFS=$OLD_IFS
			if [ $remote_3rd_party_success -ne 1 ]; then
				Logger "No remote 3rd party host responded to ping. No internet ?" "ERROR"
				return 1
			fi
		fi
	fi
}

#__BEGIN_WITH_PARANOIA_DEBUG
function __CheckArguments {
	# Checks the number of arguments of a function and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then
                local number_of_arguments="${1}" # Number of arguments the tested function should have
                local number_of_given_arguments="${2}" # Number of arguments that have been passed
                local function_name="${3}" # Function name that called __CheckArguments

		if [ "$_PARANOIA_DEBUG" == "yes" ]; then
			Logger "Entering function [$function_name]." "DEBUG"
		fi

                # All arguments of the function to check are passed as array in ${4} (the function call waits for $@)
                # If any of the arguments contains spaces, bash things there are two aguments
                # In order to avoid this, we need to iterate over ${4} and count

                local iterate=4
                local fetch_arguments=1
                local arg_list=""
                while [ $fetch_arguments -eq 1 ]; do
                        cmd='argument=${'$iterate'}'
                        eval $cmd
                        if [ "$argument" = "" ]; then
                                fetch_arguments=0
                        else
                                arg_list="$arg_list [Argument $(($iterate-3)): $argument]"
                                iterate=$(($iterate+1))
                        fi
                done
                local counted_arguments=$((iterate-4))

                if [ $counted_arguments -ne $number_of_arguments ]; then
                        Logger "Function $function_name may have inconsistent number of arguments. Expected: $number_of_arguments, count: $counted_arguments, bash seen: $number_of_given_arguments. see log file." "ERROR"
                        Logger "Arguments passed: $arg_list" "ERROR"
                fi
	fi
}

#__END_WITH_PARANOIA_DEBUG

function RsyncPatternsAdd {
	local pattern_type="${1}"	# exclude or include
	local pattern="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local rest=

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
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
			if [ "$RSYNC_PATTERNS" == "" ]; then
			RSYNC_PATTERNS="--"$pattern_type"=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --"$pattern_type"=\"$str\""
		fi
	done
	set +f
}

function RsyncPatternsFromAdd {
        local pattern_type="${1}"
        local pattern_from="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local pattern_from=

        ## Check if the exclude list has a full path, and if not, add the config file path if there is one
        if [ "$(basename $pattern_from)" == "$pattern_from" ]; then
                pattern_from="$(dirname $CONFIG_FILE)/$pattern_from"
        fi

        if [ -e "$pattern_from" ]; then
                RSYNC_PATTERNS="$RSYNC_PATTERNS --"$pattern_type"-from=\"$pattern_from\""
        fi
}

function RsyncPatterns {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
                RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
                if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
                fi
                RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
                if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
                fi
        elif [ "$RSYNC_PATTERN_FIRST" == "include" ]; then
                RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
                if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
                fi
                RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
                if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
                fi
        else
                Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
        fi
}

function PreInit {
	 __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
	RSYNC_ATTR_ARGS="-pgo"
	if [ "$_DRYRUN" -eq 1 ]; then
		RSYNC_DRY_ARG="-n"
                DRY_WARNING="/!\ DRY RUN"
	else
		RSYNC_DRY_ARG=""
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
        COMPRESSION_LEVEL=3
        if type xz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| xz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.xz
        elif type lzma > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| lzma -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.lzma
        elif type pigz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| pigz -$COMPRESSION_LEVEL"
              	COMPRESSION_EXTENSION=.gz
		# obackup specific
                COMPRESSION_OPTIONS=--rsyncable
        elif type gzip > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| gzip -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
		# obackup specific
                COMPRESSION_OPTIONS=--rsyncable
        else
                COMPRESSION_PROGRAM=
                COMPRESSION_EXTENSION=
        fi
        ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function PostInit {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	# Define remote commands
        SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
        SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
        RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
}

function InitLocalOSSettings {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        ## If running under Msys, some commands do not run the same way
        ## Using mingw version of find instead of windows one
        ## Getting running processes is quite different
        ## Ping command is not the same
        if [ "$LOCAL_OS" == "msys" ]; then
                FIND_CMD=$(dirname $BASH)/find
                # PROCESS_TEST_CMD assumes there is a variable $pid
		# Tested on MSYS and cygwin
                PROCESS_TEST_CMD='ps -a | awk "{\$1=\$1}\$1" | awk "{print \$1}" | grep $pid'
                PING_CMD='$SYSTEMROOT\system32\ping -n 2'
        else
                FIND_CMD=find
                # PROCESS_TEST_CMD assumes there is a variable $pid
                PROCESS_TEST_CMD='ps -p$pid'
                PING_CMD="ping -c 2 -i .2"
        fi

        ## Stat command has different syntax on Linux and FreeBSD/MacOSX
        if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
                STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
        else
                STAT_CMD="stat --format %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
        fi
}

function InitRemoteOSSettings {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        ## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
        if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
                RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -E"
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

## END Generic functions

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
	Logger "/!\ Manual exit of backup script. Backups may be in inconsistent state." "WARN"
	exit 1
}

function TrapQuit {
	local exitcode

	if [ $ERROR_ALERT -ne 0 ]; then
		SendAlert
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "Backup script finished with errors." "ERROR"
		exitcode=1
	elif [ $WARN_ALERT -ne 0 ]; then
		SendAlert
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "Backup script finished with warnings." "WARN"
		exitcode=2
	else
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "Backup script finshed." "NOTICE"
		exitcode=0
	fi

	if [ -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID" ]; then
		rm -f "$RUN_DIR/$PROGRAM.$INSTANCE_ID"
	fi

	KillChilds $$ > /dev/null 2>&1
	exit $exitcode
}

function CheckEnvironment {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(SQL_BACKUP FILE_BACKUP ENCRYPTION CREATE_DIRS KEEP_ABSOLUTE_PATHS GET_BACKUP_SIZE SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SUDO_EXEC DATABASES_ALL PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS RSYNC_COMPRESS PARTIAL DELETE_VANISHED_FILES DELTA_COPIES ROTATE_SQL_BACKUPS ROTATE_FILE_BACKUPS STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
	for i in "${yes_no_vars[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$BACKUP_TYPE" != "local" ] && [ "$BACKUP_TYPE" != "pull" ] && [ "$BACKUP_TYPE" != "push" ]; then
		Logger "Bogus BACKUP_TYPE value in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(BACKUP_SIZE_MINIMUM SQL_WARN_MIN_SPACE FILE_WARN_MIN_SPACE SOFT_MAX_EXEC_TIME_DB_TASK HARD_MAX_EXEC_TIME_DB_TASK COMPRESSION_LEVEL SOFT_MAX_EXEC_TIME_FILE_TASK HARD_MAX_EXEC_TIME_FILE_TASK BANDWIDTH SOFT_MAX_EXEC_TIME_TOTAL HARD_MAX_EXEC_TIME_TOTAL ROTATE_SQL_COPIES ROTATE_FILE_COPIES MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumeric \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value defined in config file. Correct your config file or update it with the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	if [ "$FILE_BACKUP" == "yes" ]; then
		if [ "$DIRECTORY_LIST" == "" ] && [ "$RECURSIVE_DIRECTORY_LIST" == "" ]; then
			Logger "No directories specified in config file, no files to backup." "ERROR"
			CAN_BACKUP_FILES=0
		fi
	fi

	#TODO-v2.1: Add runtime variable tests (RSYNC_ARGS etc)
}

function CheckRunningInstances {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local sql_cmd=

	sql_cmd="mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;' > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	Logger "cmd: $sql_cmd" "DEBUG"
	eval "$sql_cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local sql_cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	sql_cmd="$SSH_CMD \"mysql -u $SQL_USER -Bse 'SELECT table_schema, round(sum( data_length + index_length ) / 1024) FROM information_schema.TABLES GROUP by table_schema;'\" > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID\" 2>&1"
	Logger "cmd: $sql_cmd" "DEBUG"
	eval "$sql_cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local output_file	# Return of subfunction
	local db_name
	local db_size
	local db_backup

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for directory in $RECURSIVE_DIRECTORY_LIST
	do
		# No sudo here, assuming you should have all necessary rights for local checks
		cmd="$FIND_CMD -L $directory/ -mindepth 1 -maxdepth 1 -type d >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
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
	IFS=$OLD_IFS
	return $retval
}

function _ListRecursiveBackupDirectoriesRemote {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	OLD_IFS=$IFS
	IFS=$PATH_SEPARATOR_CHAR
	for directory in $RECURSIVE_DIRECTORY_LIST
	do
		cmd=$SSH_CMD' "'$COMMAND_SUDO' '$REMOTE_FIND_CMD' -L '$directory'/ -mindepth 1 -maxdepth 1 -type d" >> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
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
	IFS=$OLD_IFS
	return $retval
}

function ListRecursiveBackupDirectories {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local output_file
	local file_exclude

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
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	# No sudo here, assuming you should have all the necessary rights
	cmd='echo "'$dir_list'" | xargs du -cs | tail -n1 | cut -f1 > '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
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
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function _GetDirectoriesSizeRemote {
	local dir_list="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	# Error output is different from stdout because not all files in list may fail at once
	cmd=$SSH_CMD' "echo '$dir_list' | xargs '$COMMAND_SUDO' du -cs | tail -n1 | cut -f1" > '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2> '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
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
	else
		TOTAL_FILES_SIZE=-1
	fi
}

function GetDirectoriesSize {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
	local dir_to_create="${1}"
		__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
		__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	cmd=$SSH_CMD' "if ! [ -d \"'$dir_to_create'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$dir_to_create'\"; fi" > '$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID' 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Cannot create remote directory [$dir_to_create]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		return 1
	fi
}

function CreateStorageDirectories {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=0
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryLocal "$FILE_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_FILES=0
			fi
		fi
	elif [ "$BACKUP_TYPE" == "push" ]; then
		if [ "$SQL_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$SQL_STORAGE"
			if [ $? != 0 ]; then
				CAN_BACKUP_SQL=0
			fi
		fi
		if [ "$FILE_BACKUP" != "no" ]; then
			_CreateDirectoryRemote "$FILE_STORAGE"
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
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	if [ -d "$path_to_check" ]; then
		# Not elegant solution to make df silent on errors
		# No sudo on local commands, assuming you should have all the necesarry rights to check backup directories sizes
		df -P "$path_to_check" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			DISK_SPACE=0
			Logger "Cannot get disk space in [$path_to_check] on local system." "ERROR"
			Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		else
			DISK_SPACE=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $4}')
			DRIVE=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $1}')
		fi
	else
		Logger "Storage path [$path_to_check] does not exist." "CRITICAL"
		return 1
	fi
}

function GetDiskSpaceRemote {
	# USE GLOBAL VARIABLE DISK_SPACE to pass variable to parent function
	local path_to_check="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local cmd

	cmd=$SSH_CMD' "if [ -d \"'$path_to_check'\" ]; then '$COMMAND_SUDO' df -P \"'$path_to_check'\"; else exit 1; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		DISK_SPACE=0
		Logger "Cannot get disk space in [$path_to_check] on remote system." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		return 1
	else
		DISK_SPACE=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $4}')
		DRIVE=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $1}')
	fi
}

function CheckDiskSpace {
	# USE OF GLOBAL VARIABLES TOTAL_DATABASES_SIZE, TOTAL_FILES_SIZE, BACKUP_SIZE_MINIMUM, STORAGE_WARN_SIZE, STORAGE_SPACE

	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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

	local dry_sql_cmd
	local sql_cmd
	local retval

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local dry_sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
	local sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > $SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
	fi
	return $retval
}

function _BackupDatabaseLocalToRemote {
	local database="${1}" # Database to backup
	local export_options="${2}" # export options

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local dry_sql_cmd
	local sql_cmd
	local retval

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	#TODO-v2.0: cannot catch mysqldump warnings
	local dry_sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS > /dev/null 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"
	local sql_cmd="mysqldump -u $SQL_USER $export_options --database $database $COMPRESSION_PROGRAM $COMPRESSION_OPTIONS | $SSH_CMD '$COMMAND_SUDO tee \"$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION\" > /dev/null' 2> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID"

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
	fi
	return $retval
}

function _BackupDatabaseRemoteToLocal {
	local database="${1}" # Database to backup
	local export_options="${2}" # export options

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local dry_sql_cmd
	local sql_cmd
	local retval

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	local dry_sql_cmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$export_options' --database '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS'" > /dev/null 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID'"'
	local sql_cmd=$SSH_CMD' "mysqldump -u '$SQL_USER' '$export_options' --database '$database' '$COMPRESSION_PROGRAM' '$COMPRESSION_OPTIONS'" > "'$SQL_STORAGE/$database.sql$COMPRESSION_EXTENSION'" 2> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID'"'

	if [ $_DRYRUN -ne 1 ]; then
		Logger "cmd: $sql_cmd" "DEBUG"
		eval "$sql_cmd" &
	else
		Logger "cmd: $dry_sql_cmd" "DEBUG"
		eval "$dry_sql_cmd" &
	fi
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID" ]; then
		Logger "Error output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID)" "ERROR"
	fi
	return $retval
}

function BackupDatabase {
	local database="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local mysql_options

	# Hack to prevent warning on table mysql.events, some mysql versions don't support --skip-events, prefer using --ignore-table
	if [ "$database" == "mysql" ]; then
		mysql_options='--skip-lock-tables --single-transaction --ignore-table=mysql.event'
	else
		mysql_options='--skip-lock-tables --single-transaction'
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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local database

	OLD_IFS=$IFS
	IFS=$' \t\n'
	for database in $SQL_BACKUP_TASKS
	do
		Logger "Backing up database [$database]." "NOTICE"
		BackupDatabase $database &
		WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_DB_TASK $HARD_MAX_EXEC_TIME_DB_TASK ${FUNCNAME[0]}
		CheckTotalExecutionTime
	done
	IFS=$OLD_IFS
}

function Rsync {
	local backup_directory="${1}"	# Which directory to backup
	local is_recursive="${2}"	# Backup only files at toplevel of directory

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local file_storage_path
	local rsync_cmd

	if [ "$KEEP_ABSOLUTE_PATHS" == "yes" ]; then
		file_storage_path="$(dirname $FILE_STORAGE/${backup_directory#/})"
	else
		file_storage_path="$FILE_STORAGE"
	fi

	## Manage to backup recursive directories lists files only (not recursing into subdirectories)
	if [ "$is_recursive" == "no-recurse" ]; then
		# Fixes symlinks to directories in target cannot be deleted when backing up root directory without recursion, and excludes subdirectories
		RSYNC_NO_RECURSE_ARGS=" -k  --exclude=*/*/"
	else
		RSYNC_NO_RECURSE_ARGS=""
	fi

	# Creating subdirectories because rsync cannot handle multiple subdirectory creation
	if [ "$BACKUP_TYPE" == "local" ]; then
		_CreateDirectoryLocal "$file_storage_path"
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" \"$backup_directory\" \"$file_storage_path\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "pull" ]; then
		_CreateDirectoryLocal "$file_storage_path"
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$REMOTE_USER@$REMOTE_HOST:$backup_directory\" \"$file_storage_path\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		_CreateDirectoryRemote "$file_storage_path"
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $RSYNC_NO_RECURSE_ARGS --stats $RSYNC_DELETE $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"$backup_directory\" \"$REMOTE_USER@$REMOTE_HOST:$file_storage_path\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1"
	fi

	Logger "cmd: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd" &
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Failed to backup [$backup_directory] to [$file_storage_path]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi
}

function Duplicity {
	local backup_directory="${1}"	# Which directory to backup
	local is_recursive="${2}"	# Backup only files at toplevel of directory

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local file_storage_path
	local duplicity_cmd

	Logger "Encrpytion not supported yet ! No backup done." "CRITICAL"
	return 1

	if [ "$KEEP_ABSOLUTE_PATHS" == "yes" ]; then
		file_storage_path="$(dirname $FILE_STORAGE$backup_directory)"
	else
		file_storage_path="$FILE_STORAGE"
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
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME_FILE_TASK $HARD_MAX_EXEC_TIME_FILE_TASK ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Failed to backup [$backup_directory] to [$file_storage_path]." "ERROR"
		Logger "Command output:\n $(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
	else
		Logger "File backup succeed." "NOTICE"
	fi

}

function FilesBackup {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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

function _RotateBackupsLocal {
	local backup_path="${1}"
	local rotate_copies="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local backup
	local copy
	local cmd
	local path

	OLD_IFS=$IFS
	IFS=$'\t\n'
	for backup in $(ls -I "*.$PROGRAM.*" "$backup_path")
	do
		copy=$rotate_copies
		while [ $copy -gt 1 ]
		do
			if [ $copy -eq $rotate_copies ]; then
				cmd="rm -rf \"$backup_path/$backup.$PROGRAM.$copy\""
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					Logger "Cannot delete oldest copy [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi
			fi
			path="$backup_path/$backup.$PROGRAM.$(($copy-1))"
			if [[ -f $path || -d $path ]]; then
				cmd="mv \"$path\" \"$backup_path/$backup.$PROGRAM.$copy\""
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					Logger "Cannot move [$path] to [$backup_path/$backup.$PROGRAM.$copy]." "ERROR"
				fi

			fi
			copy=$(($copy-1))
		done

		# Latest file backup will not be moved if script configured for remote backup so next rsync execution will only do delta copy instead of full one
		if [[ $backup == *.sql.* ]]; then
			cmd="mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				Logger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		elif [ "$REMOTE_OPERATION" == "yes" ]; then
			cmd="cp -R \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				Logger "Cannot copy [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi

		else
			cmd="mv \"$backup_path/$backup\" \"$backup_path/$backup.$PROGRAM.1\""
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 3600 0 ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				Logger "Cannot move [$backup_path/$backup] to [$backup_path/$backup.$PROGRAM.1]." "ERROR"
			fi
		fi
	done
	IFS=$OLD_IFS
}

function _RotateBackupsRemote {
	local backup_path="${1}"
	local rotate_copies="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
		copy=$rotate_copies
		while [ $copy -gt 1 ]
		do
			if [ $copy -eq $rotate_copies ]; then
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

	WaitForTaskCompletion $! 1800 0 ${FUNCNAME[0]}
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
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	Logger "Rotating backups." "NOTICE"

	if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "pull" ]; then
		_RotateBackupsLocal "$backup_path" "$rotate_copies"
	elif [ "$BACKUP_TYPE" == "push" ]; then
		_RotateBackupsRemote "$backup_path" "$rotate_copies"
	fi
}

function Init {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local uri
	local hosturiandpath
	local hosturi

	trap TrapStop SIGINT SIGQUIT SIGTERM SIGHUP
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

	if [ $_VERBOSE -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -i"
	fi

	if [ "$DELETE_VANISHED_FILES" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --delete"
	fi

	if [ $stats -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --stats"
	fi

	## Fix for symlink to directories on target cannot get updated
	RSYNC_ARGS=$RSYNC_ARGS" --force"
}

function Main {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		ListDatabases
	fi
	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES -eq 1 ]; then
		ListRecursiveBackupDirectories
		if [ "$GET_BACKUP_SIZE" != "no" ]; then
			GetDirectoriesSize
		else
			TOTAL_FILES_SIZE=0
		fi
	fi

	if [ "$CREATE_DIRS" != "no" ]; then
		CreateStorageDirectories
	fi
	CheckDiskSpace

	# Actual backup process
	if [ "$SQL_BACKUP" != "no" ] && [ $CAN_BACKUP_SQL -eq 1 ]; then
		if [ $_DRYRUN -ne 1 ] && [ "$ROTATE_SQL_BACKUPS" == "yes" ]; then
			RotateBackups "$SQL_STORAGE" "$ROTATE_SQL_COPIES"
		fi
		BackupDatabases
	fi

	if [ "$FILE_BACKUP" != "no" ] && [ $CAN_BACKUP_FILES -eq 1 ]; then
		if [ $_DRYRUN -ne 1 ] && [ "$ROTATE_FILE_BACKUPS" == "yes" ]; then
			RotateBackups "$FILE_STORAGE" "$ROTATE_FILE_COPIES"
		fi
		## Add Rsync include / exclude patterns
		RsyncPatterns
		FilesBackup
	fi
}

function Usage {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG


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
	echo "--dry             will run obackup without actually doing anything, just testing"
	echo "--silent          will run obackup without any output to stdout, usefull for cron backups"
	echo "--verbose         adds command outputs"
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
LoadConfigFile "$1"
if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
		LOG_FILE="$HOME/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE=./$PROGRAM.$INSTANCE_ID.log
	fi
else
	LOG_FILE="$LOGFILE"
fi

if [ "$IS_STABLE" != "yes" ]; then
	Logger "This is an unstable dev build. Please use with caution." "WARN"
fi

DATE=$(date)
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING $DATE - $PROGRAM v$PROGRAM_VERSION $BACKUP_TYPE script begin." "NOTICE"
Logger "--------------------------------------------------------------------" "NOTICE"
Logger "Backup instance [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

GetLocalOS
InitLocalOSSettings
CheckEnvironment
CheckRunningInstances
PreInit
Init
PostInit
CheckCurrentConfig

if [ "$REMOTE_OPERATION" == "yes" ]; then
	GetRemoteOS
	InitRemoteOSSettings
fi

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
