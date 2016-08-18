#!/usr/bin/env bash

## obackup test suite 2016081801
# Stupid and very basic tests v0.0000002-alpha-dev-pre-everything

DEV_DIR="/home/git/obackup/dev"

SOURCE_DIR="/opt/obackup"
TARGET_DIR="/home/storage/backup"

TARGET_DIR_SQL_LOCAL="/home/storage/backup/sql"
TARGET_DIR_FILE_LOCAL="/home/storage/backup/files"

TARGET_DIR_SQL_PULL="/home/storage/backup/sql-pull"
TARGET_DIR_FILE_PULL="/home/storage/backup/files-pull"

TARGET_DIR_SQL_PUSH="/home/storage/backup/sql-push"
TARGET_DIR_FILE_PUSH="/home/storage/backup/files-push"

SIMPLE_DIR="testData"
RECURSIVE_DIR="testDataRecursive"

S_DIR_1="dir rect ory"
R_EXCLUDED_DIR="Excluded"
R_DIR_1="a"
R_DIR_2="b"
R_DIR_3="c d"

S_FILE_1="some file"
R_FILE_1="file_1"
R_FILE_2="file 2"
R_FILE_3="file 3"

EXCLUDED_FILE="exclu.ded"

DATABASE_1="mysql.sql.xz"
DATABASE_2="performance_schema.sql.xz"
DATABASE_EXCLUDED="information_schema.sql.xz"

function oneTimeSetUp () {
	source "$DEV_DIR/ofunctions.sh"

	if grep "^IS_STABLE=YES" "$DEV_DIR/n_obackup.sh" > /dev/null; then
		IS_STABLE=yes
	else
		IS_STABLE=no
		sed -i 's/^IS_STABLE=no/IS_STABLE=yes/' "$DEV_DIR/n_obackup.sh"
	fi

	mkdir -p "$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_EXCLUDED_DIR"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_1"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_2"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3"

	touch "$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1/$S_FILE_1"
	touch "$SOURCE_DIR/$SIMPLE_DIR/$EXCLUDED_FILE"
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_1/$R_FILE_1"
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_2/$R_FILE_2"
	dd if=/dev/urandom of="$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$R_FILE_3" bs=1M count=2
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$EXCLUDED_FILE"

	FilePresence=(
	"$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1/$S_FILE_1"
	"$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_1/$R_FILE_1"
	"$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_2/$R_FILE_2"
	"$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$R_FILE_3"
	)

	DatabasePresence=(
	"$DATABASE_1"
	"$DATABASE_2"
	)

	FileExcluded=(
	"$SOURCE_DIR/$SIMPLE_DIR/$EXCLUDED_FILE"
	"$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$R_EXCLUDED_FILE"
	)

	DatabaseExcluded=(
	"$DATABASE_EXCLUDED"
	)

	DirectoriesExcluded=(
	"$RECURSIVE_DIR/$R_EXCLUDED_DIR"
	)

}

function oneTimeTearDown () {
	if [ "$IS_STABLE" == "no" ]; then
		sed -i 's/^IS_STABLE=yes/IS_STABLE=no/' "$DEV_DIR/n_obackup.sh"
	fi

	#rm -rf $SOURCE_DIR
	#rm -rf $TARGET_DIR
}


function test_FirstLocalRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/local.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_FILE_LOCAL/$file" ]
		assertEquals "File Presence [$TARGET_DIR_FILE_LOCAL/$file]" "0" $?
	done

	for file in "${FileExcluded[@]}"; do
		[ -f "$TARGET_DIR_FILE_LOCAL/$file" ]
		assertEquals "File Excluded [$TARGET_DIR_FILE_LOCAL/$file]" "1" $?
	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_LOCAL/$file]" "0" $?
	done

	for file in "${DatabaseExcluded[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file" ]
		assertEquals "Database Excluded [$TARGET_DIR_SQL_LOCAL/$file]" "1" $?
	done

	for directory in "${DirectoriesExcluded[@]}"; do
		[ -d "$TARGET_DIR_FILE_LOCAL/$directory" ]
		assertEquals "Directory Excluded [$TARGET_DIR_FILE_LOCAL/$directory]" "1" $?
	done
}

function test_SecondLocalRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/local.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file.obackup.1" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_LOCAL/$file]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_LOCAL/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "File rotated Presence" "0" $?
}
function test_FirstPullRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/pull.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_FILE_PULL/$file" ]
		assertEquals "File Presence [$TARGET_DIR_FILE_PULL/$file]" "0" $?
	done

	for file in "${FileExcluded[@]}"; do
		[ -f "$TARGET_DIR_FILE_PULL/$file" ]
		assertEquals "File Excluded [$TARGET_DIR_FILE_PULL/$file]" "1" $?
	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_PULL/$file]" "0" $?
	done

	for file in "${DatabaseExcluded[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file" ]
		assertEquals "Database Excluded [$TARGET_DIR_SQL_PULL/$file]" "1" $?
	done

	for directory in "${DirectoriesExcluded[@]}"; do
		[ -d "$TARGET_DIR_FILE_PULL/$directory" ]
		assertEquals "Directory Excluded [$TARGET_DIR_FILE_PULL/$directory]" "1" $?
	done
}

function test_SecondPullRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/pull.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file.obackup.1" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PULL/$file]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_PULL/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "File rotated Presence" "0" $?
}

function test_FirstPushRun () {
	# Basic return code tests. Need to go deep into file presence testing
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/push.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_FILE_PUSH/$file" ]
		assertEquals "File Presence [$TARGET_DIR_FILE_PUSH/$file]" "0" $?
	done

	for file in "${FileExcluded[@]}"; do
		[ -f "$TARGET_DIR_FILE_PUSH/$file" ]
		assertEquals "File Excluded [$TARGET_DIR_FILE_PUSH/$file]" "1" $?
	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_PUSH/$file]" "0" $?
	done

	for file in "${DatabaseExcluded[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file" ]
		assertEquals "Database Excluded [$TARGET_DIR_SQL_PUSH/$file]" "1" $?
	done

	for directory in "${DirectoriesExcluded[@]}"; do
		[ -d "$TARGET_DIR_FILE_PUSH/$directory" ]
		assertEquals "Directory Excluded [$TARGET_DIR_FILE_PUSH/$directory]" "1" $?
	done
}

function test_SecondPushRun () {
	# Only tests presence of rotated files
	cd "$DEV_DIR"
	./n_obackup.sh tests/conf/push.conf > /dev/null
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file.obackup.1" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PUSH/$file]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR).obackup.1" ]
	assertEquals "File rotated Presence" "0" $?
}

function test_WaitForTaskCompletion () {
	# Tests if wait for task completion works correctly

	sleep 3 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"
	WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	sleep 5 &
	pids="$!"
	sleep 8 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 6 0 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	sleep 7 &
	pids="$!"
	sleep 9 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 5 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	sleep 3 &
	pids="$!"
	sleep 10 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 7 ${FUNCNAME[0]} false true 0
	assertEquals "WaitForTaskCompletion test 4" "1" $?
}

. ./shunit2/shunit2