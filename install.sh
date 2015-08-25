#!/usr/bin/env bash

SCRIPT_BUILD=2015082501

## Obackup install script
## Tested on RHEL / CentOS 6 & 7
## Please adapt this to fit your distro needs

if [ "$(whoami)" != "root" ]
then
  echo "Must be run as root."
  exit 1
fi

mkdir /etc/obackup
cp ./host_backup.conf /etc/obackup/host_backup.conf.example
cp ./exclude.list.example /etc/obackup
cp ./obackup.sh /usr/local/bin
cp ./obackup-batch.sh /usr/local/bin
cp ./ssh_filter.sh /usr/local/bin
chmod 755 /usr/local/bin/obackup.sh
chmod 755 /usr/local/bin/obackup-batch.sh
chmod 755 /usr/local/bin/ssh_filter.sh
chown root:root /usr/local/bin/ssh_filter.sh

