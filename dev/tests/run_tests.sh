#!/usr/bin/env bash

# Stupid and very basic tests v0.0000001-alpha-dev-pre-everything

DEV_DIR="/home/git/obackup/dev"

SOURCE_DIR="/opt/obackup"
TARGET_DIR="/home/storage/backup"

TARGET_DIR_SQL_LOCAL="/home/storage/backup/sql"
TARGET_DIR_FILE_LOCAL="/home/storage/backup/files"

TARGET_DIR_SQL_PULL="/home/storage/backup/sql-pull"
TARGET_DIR_FILE_PULL="/home/storage/backup/files-pull"

TARGET_DIR_SQL_PUSH="/home/storage/backup/sql-push"
TARGET_DIR_FILE_PUSH="/home/storage/backup/files-push"


SIMPLE_DIR="/testData"
RECURSIVE_DIR="/testDataRecursive"



function oneTimeSetUp () {
	source "$DEV_DIR/ofunctions.sh"

	sed -i 's/^IS_STABLE=no/IS_STABLE=yes/' "$DEV_DIR/n_obackup.sh"

	mkdir -p $SOURCE_DIR$SIMPLE_DIR
	mkdir -p $SOURCE_DIR$RECURSIVE_DIR/Excluded
	mkdir -p $SOURCE_DIR$RECURSIVE_DIR/a
	mkdir -p $SOURCE_DIR$RECURSIVE_DIR/b
	mkdir -p "$SOURCE_DIR$RECURSIVE_DIR/c d"
	mkdir -p $SOURCE_DIR$RECURSIVE_DIR/e

	touch $SOURCE_DIR$SIMPLE_DIR/file_1
	touch $SOURCE_DIR$RECURSIVE_DIR/file_2
	touch $SOURCE_DIR$RECURSIVE_DIR/Excluded/file_3
	touch $SOURCE_DIR$RECURSIVE_DIR/a/file_4
	touch $SOURCE_DIR$RECURSIVE_DIR/b/file_5
	touch "$SOURCE_DIR$RECURSIVE_DIR/c d/file_6"
	touch $SOURCE_DIR$RECURSIVE_DIR/e/file_7

	# Big file
	dd if=/dev/urandom of=$SOURCE_DIR$RECURSIVE_DIR/e/file_8 bs=1M count=2
}

function oneTimeTearDown () {
	sed -i 's/^IS_STABLE=yes/IS_STABLE=no/' "$DEV_DIR/n_obackup.sh"

	rm -rf $TARGET_DIR
}

function test_FirstLocalRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/local.conf > /dev/null
	assertEquals "Return code" "0" $?
}

function test_SecondLocalRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/local.conf > /dev/null
	assertEquals "Return code" "0" $?

	[ -f "$TARGET_DIR_SQL_LOCAL/mysql.sql.xz.obackup.1" ]
	assertEquals "SQL rotated file" "0" $?

	[ -d "$TARGET_DIR_FILE_LOCAL/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "Files rotated file" "0" $?
}

function test_FirstPullRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/pull.conf > /dev/null
	assertEquals "Return code" "0" $?
}

function test_SecondPullRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/pull.conf > /dev/null
	assertEquals "Return code" "0" $?

	[ -f "$TARGET_DIR_SQL_PULL/mysql.sql.xz.obackup.1" ]
	assertEquals "SQL rotated file" "0" $?

	[ -d "$TARGET_DIR_FILE_PULL/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "Files rotated file" "0" $?
}

function test_FirstPushRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/push.conf > /dev/null
	assertEquals "Return code" "0" $?
}

function test_SecondPushRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/push.conf > /dev/null
	assertEquals "Return code" "0" $?

	[ -f "$TARGET_DIR_SQL_PUSH/mysql.sql.xz.obackup.1" ]
	assertEquals "SQL rotated file" "0" $?

	[ -d "$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "Files rotated file" "0" $?
}

function test_WaitForTaskCompletion () {
	# Tests if wait for task completion works correctly

	sleep 20 &
	pids="$!"
	sleep 25 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	sleep 20 &
	pids="$!"
	sleep 25 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 10 0 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	sleep 20 &
	pids="$!"
	sleep 25 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 10 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	sleep 20 &
	pids="$!"
	sleep 25 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 22 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 4" "1" $?
}

. ./shunit2/shunit2
