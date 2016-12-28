#!/usr/bin/env bash

## obackup basic tests suite 2016122801

OBACKUP_DIR="$(pwd)"
OBACKUP_DIR=${OBACKUP_DIR%%/dev*}
DEV_DIR="$OBACKUP_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

CONF_DIR="$TESTS_DIR/conf"
LOCAL_CONF="local.conf"
PULL_CONF="pull.conf"
PUSH_CONF="push.conf"

OLD_CONF="old.conf"
MAX_EXEC_CONF="max-exec-time.conf"
TMP_OLD_CONF="tmp.old.conf"

OBACKUP_EXECUTABLE="obackup.sh"
OBACKUP_DEV_EXECUTABLE="dev/n_obackup.sh"
OBACKUP_UPGRADE="upgrade-v1.x-2.1x.sh"
TMP_FILE="$DEV_DIR/tmp"

SOURCE_DIR="${HOME}/obackup-testdata"
TARGET_DIR="${HOME}/obackup-storage"

TARGET_DIR_SQL_LOCAL="$TARGET_DIR/sql-local"
TARGET_DIR_FILE_LOCAL="$TARGET_DIR/files-local"
TARGET_DIR_CRYPT_LOCAL="$TARGET_DIR/crypt-local"

TARGET_DIR_SQL_PULL="$TARGET_DIR/sql-pull"
TARGET_DIR_FILE_PULL="$TARGET_DIR/files-pull"
TARGET_DIR_CRYPT_PULL="$TARGET_DIR/crypt-pull"

TARGET_DIR_SQL_PUSH="$TARGET_DIR/sql-push"
TARGET_DIR_FILE_PUSH="$TARGET_DIR/files-push"
TARGET_DIR_CRYPT_PUSH="$TARGET_DIR/crypt-push"


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
N_FILE_1="non recurse file"

EXCLUDED_FILE="exclu.ded"

DATABASE_1="mysql.sql.xz"
DATABASE_2="performance_schema.sql.xz"
DATABASE_EXCLUDED="information_schema.sql.xz"

CRYPT_EXTENSION=".obackup.gpg"
ROTATE_1_EXTENSION=".obackup.1"

PASSFILE="passfile"
CRYPT_TESTFILE="testfile"

# Later populated variables
OBACKUP_VERSION=2.x
OBACKUP_MIN_VERSION=x
OBACKUP_IS_STABLE=maybe

# Setup an array with all function modes
#declare -Ag osyncParameters

function GetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value

        value=$(grep "^$name=" "$file")
        if [ $? == 0 ]; then
                value="${value##*=}"
                echo "$value"
        else
            	assertEquals "$name does not exist in [$file]." "1" "0"
        fi
}

function SetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value="${3}"

        if grep "^$name=" "$file" > /dev/null; then
                # Using -i.tmp for BSD compat
                sed -i.tmp "s/^$name=.*/$name=$value/" "$file"
                rm -f "$file.tmp"
                assertEquals "Set $name to [$value]." "0" $?
        else
            	assertEquals "$name does not exist in [$file]." "1" "0"
        fi
}

function SetupSSH {
        echo -e  'y\n'| ssh-keygen -t rsa -b 2048 -N "" -f "${HOME}/.ssh/id_rsa_local"
        if ! grep "$(cat ${HOME}/.ssh/id_rsa_local.pub)" "${HOME}/.ssh/authorized_keys"; then
                cat "${HOME}/.ssh/id_rsa_local.pub" >> "${HOME}/.ssh/authorized_keys"
        fi
	chmod 600 "${HOME}/.ssh/authorized_keys"

        # Add localhost to known hosts so self connect works
        if [ -z "$(ssh-keygen -F localhost)" ]; then
                ssh-keyscan -H localhost >> "${HOME}/.ssh/known_hosts"
        fi

        # Update remote conf files with SSH port
        sed -i.tmp 's#ssh://.*@localhost:[0-9]*/#ssh://'$REMOTE_USER'@localhost:'$SSH_PORT'/#' "$CONF_DIR/$PULL_CONF"
        sed -i.tmp 's#ssh://.*@localhost:[0-9]*/#ssh://'$REMOTE_USER'@localhost:'$SSH_PORT'/#' "$CONF_DIR/$PUSH_CONF"
}

function RemoveSSH {
        local pubkey

        if [ -f "${HOME}/.ssh/id_rsa_local" ]; then

                pubkey=$(cat "${HOME}/.ssh/id_rsa_local.pub")
                sed -i.bak "#$pubkey#d" "${HOME}/.ssh/authorized_keys"
                rm -f "${HOME}/.ssh/{id_rsa_local.pub,id_rsa_local}"
        fi
}

function SetupGPG {
	if type gpg2 > /dev/null; then
		CRYPT_TOOL=gpg2
	elif type gpg > /dev/null; then
		CRYPT_TOOL=gpg
	else
		echo "No gpg support"
	fi

	if ! $CRYPT_TOOL --list-keys | grep "John Doe" > /dev/null; then

		cat >gpgcommand <<EOF
%echo Generating a GPG Key
Key-Type: RSA
Key-Length: 4096
Name-Real: John Doe
Name-Comment: obackup-test-key
Name-Email: john@example.com
Expire-Date: 0
Passphrase: PassPhrase123
# Do a commit here, so that we can later print "done" :-)
%commit
%echo done
EOF

		if type apt-get > /dev/null 2>&1; then
			sudo apt-get install rng-tools
		fi

		# Setup fast entropy
		if type rngd > /dev/null 2>&1; then
			rngd -r /dev/urandom
		else
			echo "No rngd support"
		fi

		$CRYPT_TOOL --batch --gen-key gpgcommand
		echo "Currently owned $CRYPT_TOOL keys"
		echo $($CRYPT_TOOL --list-keys)
		rm -f gpgcommand

	fi

	echo "PassPhrase123" > "$TESTS_DIR/$PASSFILE"
}

function oneTimeSetUp () {
	START_TIME=$SECONDS

	source "$DEV_DIR/ofunctions.sh"
	GetLocalOS

	echo "Detected OS: $LOCAL_OS"

        # Set some travis related changes
        if [ "$TRAVIS_RUN" == true ]; then
        echo "Running with travis settings"
                REMOTE_USER="travis"
		RHOST_PING="no"
                SetConfFileValue "$CONF_DIR/$PULL_CONF" "REMOTE_3RD_PARTY_HOSTS" ""
                SetConfFileValue "$CONF_DIR/$PUSH_CONF" "REMOTE_3RD_PARTY_HOSTS" ""
		# Config value didn't have S at the end in old files
                SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_3RD_PARTY_HOST" ""

                SetConfFileValue "$CONF_DIR/$PULL_CONF" "REMOTE_HOST_PING" "no"
                SetConfFileValue "$CONF_DIR/$PUSH_CONF" "REMOTE_HOST_PING" "no"
                SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_HOST_PING" "no"
        else
            	echo "Running with local settings"
                REMOTE_USER="root"
		RHOST_PING="yes"
                SetConfFileValue "$CONF_DIR/$PULL_CONF" "REMOTE_3RD_PARTY_HOSTS" "\"www.kernel.org www.google.com\""
                SetConfFileValue "$CONF_DIR/$PUSH_CONF" "REMOTE_3RD_PARTY_HOSTS" "\"www.kernel.org www.google.com\""
		# Config value didn't have S at the end in old files
                SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_3RD_PARTY_HOST" "\"www.kernel.org www.google.com\""

                SetConfFileValue "$CONF_DIR/$PULL_CONF" "REMOTE_HOST_PING" "yes"
                SetConfFileValue "$CONF_DIR/$PUSH_CONF" "REMOTE_HOST_PING" "yes"
                SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_HOST_PING" "yes"
        fi

        # Get default ssh port from env
        if [ "$SSH_PORT" == "" ]; then
                SSH_PORT=22
        fi

	SetupGPG
	if [ "$SKIP_REMOTE" != "yes" ]; then
		SetupSSH
	fi

	# Get OBACKUP version
        OBACKUP_VERSION=$(GetConfFileValue "$OBACKUP_DIR/$OBACKUP_DEV_EXECUTABLE" "PROGRAM_VERSION")
        OBACKUP_VERSION="${OBACKUP_VERSION##*=}"
        OBACKUP_MIN_VERSION="${OBACKUP_VERSION:2:1}"

        OBACKUP_IS_STABLE=$(GetConfFileValue "$OBACKUP_DIR/$OBACKUP_DEV_EXECUTABLE" "IS_STABLE")

        echo "Running with $OBACKUP_VERSION ($OBACKUP_MIN_VERSION) STABLE=$OBACKUP_IS_STABLE"
}

function oneTimeTearDown () {
	SetConfFileValue "$OBACKUP_DIR/$OBACKUP_EXECUTABLE" "IS_STABLE" "$OBACKUP_IS_STABLE"

	RemoveSSH

	#TODO: uncomment this when dev is done
	#rm -rf "$SOURCE_DIR"
	#rm -rf "$TARGET_DIR"
	rm -f "$TMP_FILE"

        ELAPSED_TIME=$(($SECONDS - $START_TIME))
        echo "It took $ELAPSED_TIME seconds to run these tests."
}


function setUp () {
	rm -rf "$SOURCE_DIR"
	rm -rf "$TARGET_DIR"

	mkdir -p "$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_EXCLUDED_DIR"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_1"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_2"
	mkdir -p "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3"

	touch "$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1/$S_FILE_1"
	touch "$SOURCE_DIR/$SIMPLE_DIR/$EXCLUDED_FILE"
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$N_FILE_1"
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_1/$R_FILE_1"
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_2/$R_FILE_2"
	dd if=/dev/urandom of="$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$R_FILE_3" bs=1M count=2
	touch "$SOURCE_DIR/$RECURSIVE_DIR/$R_DIR_3/$EXCLUDED_FILE"

	FilePresence=(
	"$SOURCE_DIR/$SIMPLE_DIR/$S_DIR_1/$S_FILE_1"
	"$SOURCE_DIR/$RECURSIVE_DIR/$N_FILE_1"
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

function test_Merge () {
	cd "$DEV_DIR"
	./merge.sh
	assertEquals "Merging code" "0" $?

	# Set obackup version to stable while testing to avoid warning message
        SetConfFileValue "$OBACKUP_DIR/$OBACKUP_EXECUTABLE" "IS_STABLE" "yes"
}

# Keep this function to check Travis environment GPG behavior. No need to run this test otherwise.
function disabled_test_GPG () {
	echo "Encrypting file"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION" --recipient "John Doe" --batch --yes --encrypt "$TESTS_DIR/$PASSFILE"
	assertEquals "Encrypt file" "0" $?

	echo "Decrypt using passphrase file"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --batch --yes --passphrase-file="$TESTS_DIR/$PASSFILE" --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passfile" "0" $?

	echo "Decrypt using passphrase"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --batch --yes --passphrase PassPhrase123 --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passphrase" "0" $?

	echo "Decrypt using passphrase file with cat"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --batch --yes --passphrase $(cat "$TESTS_DIR/$PASSFILE") --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passphrase" "0" $?

	echo "Decrypt using passphrase file --no-use-agent"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --no-use-agent --batch --yes --passphrase-file="$TESTS_DIR/$PASSFILE" --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passphrase" "0" $?

	echo "Decrypt using passphrase --no-use-agent"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --no-use-agent --batch --yes --passphrase PassPhrase123 --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passphrase" "0" $?

	echo "Decrypt using passphrase file with cat --no-use-agent"
	$CRYPT_TOOL --out "$TESTS_DIR/$CRYPT_TESTFILE" --no-use-agent --batch --yes --passphrase $(cat "$TESTS_DIR/$PASSFILE") --decrypt "$TESTS_DIR/$CRYPT_TESTFILE$CRYPT_EXTENSION"
	assertEquals "Decrypt file using passphrase" "0" $?
}

function test_LocalRun () {
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "ENCRYPTION" "no"

	# Basic return code tests. Need to go deep into file presence testing
	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$LOCAL_CONF"
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

	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-local/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-local/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 2 ]
	assertEquals "Diff should only output excluded files" "0" $?

	# Tests presence of rotated files

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$LOCAL_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_LOCAL/$file]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_LOCAL/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_FILE_LOCAL/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION]" "0" $?

}

function test_PullRun () {
	if [ "$SKIP_REMOTE" == "yes" ]; then
		return 0
	fi

	SetConfFileValue "$CONF_DIR/$PULL_CONF" "ENCRYPTION" "no"

	# Basic return code tests. Need to go deep into file presence testing
	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PULL_CONF"
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

	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-pull/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-pull/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 2 ]
	assertEquals "Diff should only output excluded files" "0" $?

	# Tests presence of rotated files

	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PULL_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PULL/$file$ROTATE_1_EXTENSION]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_PULL/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_FILE_PULL/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION]" "0" $?

}

function test_PushRun () {
	if [ "$SKIP_REMOTE" == "yes" ]; then
		return 0
	fi

	SetConfFileValue "$CONF_DIR/$PUSH_CONF" "ENCRYPTION" "no"

	# Basic return code tests. Need to go deep into file presence testing
	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PUSH_CONF"
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

	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-push/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-push/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 2 ]
	assertEquals "Diff should only output excluded files" "0" $?

	# Tests presence of rotated files
	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PUSH_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PUSH/$file$ROTATE_1_EXTENSION]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR)$ROTATE_1_EXTENSION]" "0" $?

}

function test_EncryptLocalRun () {
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "ENCRYPTION" "yes"

	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$LOCAL_CONF"

	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_CRYPT_LOCAL/$file$CRYPT_EXTENSION" ]
		assertEquals "File Presence [$TARGET_DIR_CRYPT_LOCAL/$file$CRYPT_EXTENSION]" "0" $?
	done

# TODO: Exclusion lists don't work with encrypted files yet
#	for file in "${FileExcluded[@]}"; do
#		[ -f "$TARGET_DIR_CRYPT_LOCAL/$file$CRYPT_EXTENSION" ]
#		assertEquals "File Excluded [$TARGET_DIR_CRYPT_LOCAL/$file$CRYPT_EXTENSION]" "1" $?
#	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION]" "0" $?
	done

#	for file in "${DatabaseExcluded[@]}"; do
#		[ -f "$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION" ]
#		assertEquals "Database Excluded [$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION]" "1" $?
#	done

#	for directory in "${DirectoriesExcluded[@]}"; do
#		[ -d "$TARGET_DIR_CRYPT_LOCAL/$directory" ]
#		assertEquals "Directory Excluded [$TARGET_DIR_CRYPT_LOCAL/$directory]" "1" $?
#	done

	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-local/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-local/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 5 ]
	assertEquals "Diff should only output excluded files" "0" $?

	# Tests presence of rotated files

	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$LOCAL_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_LOCAL/$file$CRYPT_EXTENSION$ROTATE_1_EXTENSION]" "0" $?
	done

	[ -d "$TARGET_DIR_CRYPT_LOCAL/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_CRYPT_LOCAL/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_SQL_LOCAL" --passphrase-file="$TESTS_DIR/$PASSFILE"
	assertEquals "Decrypt sql storage in [$TARGET_DIR_SQL_LOCAL]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_CRYPT_LOCAL" --passphrase-file="$TESTS_DIR/$PASSFILE"
	assertEquals "Decrypt file storage in [$TARGET_DIR_CRYPT_LOCAL]" "0" $?
}

function test_EncryptPullRun () {
	if [ "$SKIP_REMOTE" == "yes" ]; then
		return 0
	fi

	# Basic return code tests. Need to go deep into file presence testing
	SetConfFileValue "$CONF_DIR/$PULL_CONF" "ENCRYPTION" "yes"


	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PULL_CONF"
	assertEquals "Return code" "0" $?

	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_CRYPT_PULL/$file$CRYPT_EXTENSION" ]
		assertEquals "File Presence [$TARGET_DIR_CRYPT_PULL/$file$CRYPT_EXTENSION]" "0" $?
	done

#	for file in "${FileExcluded[@]}"; do
#		[ -f "$TARGET_DIR_CRYPT_PULL/$file$CRYPT_EXTENSION" ]
#		assertEquals "File Excluded [$TARGET_DIR_CRYPT_PULL/$file$CRYPT_EXTENSION]" "1" $?
#	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION]" "0" $?
	done

#	for file in "${DatabaseExcluded[@]}"; do
#		[ -f "$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION" ]
#		assertEquals "Database Excluded [$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION]" "1" $?
#	done

#	for directory in "${DirectoriesExcluded[@]}"; do
#		[ -d "$TARGET_DIR_FILE_PULL/$directory" ]
#		assertEquals "Directory Excluded [$TARGET_DIR_FILE_PULL/$directory]" "1" $?
#	done

	# Only excluded files should be listed here
	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-pull/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-pull/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 2 ]
	assertEquals "Diff should only output excluded files" "0" $?

	# Tests presence of rotated files

	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PULL_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PULL/$file$CRYPT_EXTENSION$ROTATE_1_EXTENSION]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_CRYPT/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_FILE_CRYPT/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_SQL_PULL" --passphrase-file="$TESTS_DIR/$PASSFILE"
	assertEquals "Decrypt sql storage in [$TARGET_DIR_SQL_PULL]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_CRYPT_PULL" --passphrase-file="$TESTS_DIR/$PASSFILE"
	assertEquals "Decrypt file storage in [$TARGET_DIR_CRYPT_PULL]" "0" $?
}

function test_EncryptPushRun () {
	if [ "$SKIP_REMOTE" == "yes" ]; then
		return 0
	fi

	# Basic return code tests. Need to go deep into file presence testing
	SetConfFileValue "$CONF_DIR/$PUSH_CONF" "ENCRYPTION" "yes"


	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PUSH_CONF"
	assertEquals "Return code" "0" $?

	# Same here, why do we check for crypt extension in file_push instead of file_crypt
	for file in "${FilePresence[@]}"; do
		[ -f "$TARGET_DIR_FILE_PUSH/$file$CRYPT_EXTENSION" ]
		assertEquals "File Presence [$TARGET_DIR_FILE_PUSH/$file$CRYPT_EXTENSION]" "0" $?
	done

#	for file in "${FileExcluded[@]}"; do
#		[ -f "$TARGET_DIR_FILE_PUSH/$file$CRYPT_EXTENSION" ]
#		assertEquals "File Excluded [$TARGET_DIR_FILE_PUSH/$file$CRYPT_EXTENSION]" "1" $?
#	done

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION" ]
		assertEquals "Database Presence [$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION]" "0" $?
	done

#	for file in "${DatabaseExcluded[@]}"; do
#		[ -f "$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION" ]
#		assertEquals "Database Excluded [$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION]" "1" $?
#	done

#	for directory in "${DirectoriesExcluded[@]}"; do
#		[ -d "$TARGET_DIR_FILE_PUSH/$directory" ]
#		assertEquals "Directory Excluded [$TARGET_DIR_FILE_PUSH/$directory]" "1" $?
#	done

	diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-push/$SOURCE_DIR" | grep -i Exclu
	[ $(diff -qr "$SOURCE_DIR" "$TARGET_DIR/files-push/$SOURCE_DIR" | grep -i Exclu | wc -l) -eq 5 ]
	assertEquals "Diff should only output excluded files" "0" $?
	# Tests presence of rotated files

	cd "$OBACKUP_DIR"
	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$PUSH_CONF"
	assertEquals "Return code" "0" $?

	for file in "${DatabasePresence[@]}"; do
		[ -f "$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
		assertEquals "Database rotated Presence [$TARGET_DIR_SQL_PUSH/$file$CRYPT_EXTENSION]" "0" $?
	done

	[ -d "$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION" ]
	assertEquals "File rotated Presence [$TARGET_DIR_FILE_PUSH/$(dirname $SOURCE_DIR)$CRYPT_EXTENSION$ROTATE_1_EXTENSION]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_SQL_PUSH" --passphrase-file="$TESTS_DIR/$PASSFILE" --verbose
	assertEquals "Decrypt sql storage in [$TARGET_DIR_SQL_PUSH]" "0" $?

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE --decrypt="$TARGET_DIR_FILE_PUSH" --passphrase-file="$TESTS_DIR/$PASSFILE"
	assertEquals "Decrypt file storage in [$TARGET_DIR_FILE_PUSH]" "0" $?
}

function test_timed_execution () {
	cd "$OBACKUP_DIR"

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1000

	SLEEP_TIME=2 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Soft max exec time db reached in obackup Return code" "2" $?

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1000

	SLEEP_TIME=2 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Hard max exec time db reached in obackup Return code" "1" $?

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1000

	SLEEP_TIME=2 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Soft max exec time file reached in obackup Return code" "2" $?

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1000

	SLEEP_TIME=2 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Hard max exec time file reached in obackup Return code" "1" $?

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1000

	SLEEP_TIME=1.5 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Soft max exec time total reached in obackup Return code" "2" $?

	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_DB_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_FILE_TASK" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "SOFT_MAX_EXEC_TIME_TOTAL" 1000
	SetConfFileValue "$CONF_DIR/$MAX_EXEC_CONF" "HARD_MAX_EXEC_TIME_TOTAL" 1

	SLEEP_TIME=2 REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$MAX_EXEC_CONF"
	assertEquals "Hard max exec time total reached in obackup Return code" "1" $?
}

function test_WaitForTaskCompletion () {
	local pids
	# Standard wait
	sleep 1 &
	pids="$!"
	sleep 2 &
	pids="$pids;$!"
	WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	# Standard wait with warning
	sleep 2 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	# Both pids are killed
	sleep 5 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 2 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	# One of two pids are killed
	sleep 2 &
	pids="$!"
	sleep 10 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 3 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 4" "1" $?

	# Count since script begin, the following should output two warnings and both pids should get killed
	sleep 20 &
	pids="$!"
	sleep 20 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 5 $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 5" "2" $?
}

function test_ParallelExec () {
	local cmd

	# Test if parallelExec works correctly in array mode

	cmd="sleep 2;sleep 2;sleep 2;sleep 2"
	ParallelExec 4 "$cmd"
	assertEquals "ParallelExec test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2"
	ParallelExec 2 "$cmd"
	assertEquals "ParallelExec test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd"
	assertEquals "ParallelExec test 3" "2" $?

	# Test if parallelExec works correctly in file mode

	echo "sleep 2" > "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 4 "$TMP_FILE" true
	assertEquals "ParallelExec test 4" "0" $?

	echo "sleep 2" > "$TMP_FILE"
	echo "du /nome" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 2 "$TMP_FILE" true
	assertEquals "ParallelExec test 5" "1" $?

	echo "sleep 4" > "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 3" >> "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 3 "$TMP_FILE" true
	assertEquals "ParallelExec test 6" "2" $?

	#function ParallelExec $numberOfProcesses $commandsArg $readFromFile $softTime $HardTime $sleepTime $keepLogging $counting $Spinner $noError $callerName
	# Test if parallelExec works correctly in array mode with full  time control

	cmd="sleep 5;sleep 5;sleep 5;sleep 5;sleep 5"
	ParallelExec 4 "$cmd" false 1 0 .05 3600 true true false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2;sleep 2;sleep 4"
	ParallelExec 2 "$cmd" false 0 0 .1 2 true false false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd" false 1 2 .05 7000 true true false ${FUNCNAME[0]}
	assertNotEquals "ParallelExec full test 3" "0" $?

}

function test_UpgradeConfPullRun () {

	# Basic return code tests. Need to go deep into file presence testing
	cd "$OBACKUP_DIR"


	# Make a security copy of the old config file
	cp "$CONF_DIR/$OLD_CONF" "$CONF_DIR/$TMP_OLD_CONF"

	./$OBACKUP_UPGRADE "$CONF_DIR/$TMP_OLD_CONF"
	assertEquals "Conf file upgrade" "0" $?

        # Update remote conf files with SSH port
        sed -i.tmp 's#ssh://.*@localhost:[0-9]*/#ssh://'$REMOTE_USER'@localhost:'$SSH_PORT'/#' "$CONF_DIR/$TMP_OLD_CONF"

	REMOTE_HOST_PING=$RHOST_PING ./$OBACKUP_EXECUTABLE "$CONF_DIR/$TMP_OLD_CONF"
	assertEquals "Upgraded conf file execution test" "0" $?

	rm -f "$CONF_DIR/$TMP_OLD_CONF"
	rm -f "$CONF_DIR/$TMP_OLD_CONF.save"
}

. "$TESTS_DIR/shunit2/shunit2"

