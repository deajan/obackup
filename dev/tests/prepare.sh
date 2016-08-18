#!/usr/bin/env bash

NON_RECURSIVE_DIR="/opt/testData"
RECURSIVE_DIR="/opt/testDataRecursive"

mkdir -p $SIMPLE_LIST
mkdir -p $RECURSIVE_LIST/Excluded
mkdir -p $RECURSIVE_LIST/a
mkdir -p $RECURSIVE_LIST/b
mkdir -p "$RECURSIVE_LIST/c d"
mkdir -p "$RECURSIVE_LIST/e

touch $SIMPLE_LIST/file_1
touch $RECURSIVE_LIST/file_2
touch $RECURSIVE_LIST/Excluded/file_3
touch $RECURSIVE_LIST/a/file_4
touch $RECURSIVE_LIST/b/file_5
touch "$RECURSIVE_LIST/c d/file_6"
touch $RECURSIVE_LIST/e/file_7

