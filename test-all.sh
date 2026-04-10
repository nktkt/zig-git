#!/bin/bash
set -x
ZG=/Users/naoki/dev/lab/love/ver-41/zig-out/bin/zig-git

rm -rf /tmp/zg-merge
$ZG init /tmp/zg-merge
cd /tmp/zg-merge

$ZG config user.name Test
$ZG config user.email t@t.com
echo "line1" > file.txt
$ZG add file.txt
$ZG commit -m "base"

$ZG checkout -b feat
echo "feat change" > file.txt
$ZG add .
$ZG commit -m "feat"

$ZG checkout master
echo "master change" > file.txt
$ZG add .
$ZG commit -m "master"

echo "--- Test merge with conflict ---"
$ZG merge feat 2>&1; echo "merge exit: $?"

echo "--- file.txt content ---"
cat file.txt

echo "--- merge abort ---"
$ZG merge --abort 2>&1

echo "--- Test log --all --graph --oneline ---"
$ZG log --all --graph --oneline 2>&1

echo "--- Test diff --stat ---"
echo "more" >> file.txt
$ZG diff --stat 2>&1

echo "--- Test switch feat ---"
$ZG switch feat 2>&1

echo "--- Test switch -c new-branch ---"
$ZG switch -c new-branch 2>&1

echo "--- Test restore ---"
echo "dirty" > file.txt
echo "Before restore:"
cat file.txt
$ZG restore file.txt 2>&1
echo "After restore:"
cat file.txt

echo "=== ALL TESTS DONE ==="
