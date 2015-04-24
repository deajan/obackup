#!/usr/bin/env bash

PROGRAM="Obackup-batch" # Batch program to run obackup instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2014 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/obackup - ozy@netpower.fr"
PROGRAM_BUILD=2404201501

## Runs an obackup instance for every conf file found
## If an instance fails, run it again if time permits

## Configuration file path. The path where all the obackup conf files are, usually /etc/obackup
CONF_FILE_PATH=/etc/obackup

## If maximum execution time is not reached, failed instances will be rerun. Max exec time is in seconds. Example is set to 10 hours.
MAX_EXECUTION_TIME=36000

## Specifies the number of reruns an instance may get
MAX_RERUNS=3


## Obackup executable full path can be set here if it cannot be found on the system
if ! type -p obackup.sh > /dev/null 2>&1
then
	OBACKUP_EXECUTABLE=./obackup.sh
else
	OBACKUP_EXECUTABLE=$(type -p obackup.sh)
fi

## Log file path
if [ -w /var/log ]
then
        LOG_FILE=/var/log/obackup-batch.log
else
        LOG_FILE=./obackup-batch.log
fi

# No need to edit under this line ##############################################################

function Log
{
        prefix="TIME: $SECONDS - "
        echo -e "$prefix$1" >> "$LOG_FILE"

        if [ $silent -eq 0 ]
        then
                echo -e "$prefix$1"
        fi
}


function Batch
{
	## Get list of .conf files
	for i in $(ls $CONF_FILE_PATH/*.conf)
	do
		if [ "$RUN" == "" ]
		then
			RUN="$i"
		else
			RUN=$RUN" $i"
		fi
	done

	RERUNS=0
	while [ $MAX_EXECUTION_TIME -gt $SECONDS ] && [ "$RUN" != "" ] && [ $MAX_RERUNS -gt $RERUNS ]
	do
		Log "Obackup instances will be run for: $RUN"
		for i in $RUN
		do
			$OBACKUP_EXECUTABLE "$i" $opts
			if [ $? != 0 ]
			then
				Log "Run instance $(basename $i) failed"
				if [ "RUN_AGAIN" == "" ]
				then
					RUN_AGAIN="$i"
				else
					RUN_AGAIN=$RUN_AGAIN" $i"
				fi
			elif [ $verbose -eq 1 ]
			then
				Log "Run instance $(basename $i) succeed."
			fi
		done
		RUN="$RUN_AGAIN"
		RUN_AGAIN=""
		RERUNS=$(($RERUNS + 1))
	done
}

function Usage
{
        echo "$PROGRAM $PROGRAM_BUILD"
        echo $AUTHOR
        echo $CONTACT
        echo ""
        echo "Batch script to sequentially run obackup instances and rerun failed ones."
        echo "Usage: obackup-batch.sh [OPTIONS]"
        echo ""
        echo "[OPTIONS]"
	echo "--path=/path/to/conf      Path to obackup conf files, defaults to /etc/obackup"
	echo "--max-reruns=X            Number of runs  max for failed instances, (defaults to 3)"
	echo "--max-exec-time=X         Retry failed instances only if max execution time not reached (defaults to 36000 seconds)"
        echo "--dry                     Will run obackup without actually doing anything; just testing"
        echo "--silent                  Will run obackup without any output to stdout, used for cron jobs"
        echo "--verbose                 Increases output"
        exit 128
}

silent=0
dry=0
verbose=0
opts=""
for i in "$@"
do
        case $i in
                --silent)
                silent=1
		opts=$opts" --silent"
                ;;
                --dry)
                dry=1
		opts=$opts" --dry"
                ;;
                --verbose)
                verbose=1
                opts=$opts" --verbose"
		;;
		--path=*)
		CONF_FILE_PATH=${i##*=}
		;;
		--max-reruns=*)
		MAX_RERUNS=${i##*=}
		;;
		--max-exec-time=*)
		MAX_EXECUTION_TIME=${i##*=}
		;;
		--help|-h)
		Usage
		;;
		*)
		Log "Unknown param '$i'"
		Usage
		;;
	esac
done

Log "$(date) Obackup batch run"
Batch
