#!/usr/bin/env bash

PROGRAM=obackup
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SCRIPT_BUILD=2016032201

## osync / obackup daemon install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8 & 10
## Please adapt this to fit your distro needs

CONF_DIR=/etc/$PROGRAM
BIN_DIR=/usr/local/bin
SERVICE_DIR=/etc/init.d

USER=root

local_os_var="$(uname -spio 2>&1)"
if [ $? != 0 ]; then
	local_os_var="$(uname -v 2>&1)"
	if [ $? != 0 ]; then
		local_os_var="$(uname)"
	fi
fi

case $local_os_var in
	*"BSD"*)
	GROUP=wheel
	;;
	*)
	GROUP=root
	;;
esac


if [ "$(whoami)" != "root" ]; then
  echo "Must be run as root."
  exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
	mkdir "$CONF_DIR"
	if [ $? == 0 ]; then
		echo "Created directory [$CONF_DIR]."
	else
		echo "Cannot create directory [$CONF_DIR]."
		exit 1
	fi
else
	echo "Config directory [$CONF_DIR] exists."
fi

if [ -f "./sync.conf" ]; then
	cp "./sync.conf" "/etc/$PROGRAM/sync.conf.example"
fi

if [ -f "./host_backup.conf" ]; then
	cp "./host_backup.conf" "/etc/$PROGRAM/host_backup.conf.example"
fi

if [ -f "./exlude.list.example" ]; then
	cp "./exclude.list.example" "/etc/$PROGRAM"
fi

if [ -f "./snapshot.conf" ]; then
	cp "./snapshot.conf" "/etc/$PROGRAM/snapshot.conf.example"
fi

cp "./$PROGRAM_BINARY" "$BIN_DIR"
if [ $? != 0 ]; then
	echo "Cannot copy $PROGRAM_BINARY to [$BIN_DIR]."
else
	chmod 755 "$BIN_DIR/$PROGRAM_BINARY"
	echo "Copied $PROGRAM_BINARY to [$BIN_DIR]."
fi

if [ -f "./$PROGRAM_BATCH" ]; then
	cp "./$PROGRAM_BATCH" "$BIN_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy $PROGRAM_BATCH to [$BIN_DIR]."
	else
		chmod 755 "$BIN_DIR/$PROGRAM_BATCH"
		echo "Copied $PROGRAM_BATCH to [$BIN_DIR]."
	fi
fi

if [  -f "./ssh_filter.sh" ]; then
	cp "./ssh_filter.sh" "$BIN_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy ssh_filter.sh to [$BIN_DIR]."
	else
		chmod 755 "$BIN_DIR/ssh_filter.sh"
		chown root:root "$BIN_DIR/ssh_filter.sh"
		echo "Copied ssh_filter.sh to [$BIN_DIR]."
	fi
fi

if [ -f "./osync-srv" ]; then
	cp "./osync-srv" "$SERVICE_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy osync-srv to [$SERVICE_DIR]."
	else
		chmod 755 "$SERVICE_DIR/osync-srv"
		echo "Created osync-srv service in [$SERVICE_DIR]."
	fi
fi
