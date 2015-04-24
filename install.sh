#!/usr/bin/env bash

SCRIPT_BUILD=2404201501

## Obackup install script
## Tested on RHEL / CentOS 6 & 7
## Please adapt this to fit your distro needs

mkdir /etc/obackup
cp ./host_backup.conf /etc/obackup/host_backup.conf.example
cp ./exclude.list.example /etc/obackup
cp ./obackup.sh /usr/local/bin
cp ./obackup-batch.sh /usr/local/bin

