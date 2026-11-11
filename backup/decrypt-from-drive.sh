#!/usr/bin/env bash
# Download one encrypted backup file from Google Drive and decrypt it.
#
# Usage:  decrypt-from-drive.sh "<path of the .age file inside the backup folder>" <output file>
# Example:
#   decrypt-from-drive.sh "postgres snapshots/main-db/postgres/postgres-2026-11-06.dump.age" restored.dump
#
# Needs rclone (with the same remote the backup uses) and age.
# The private key is downloaded from Drive into a temporary folder and removed afterwards.
set -euo pipefail

REMOTE="${REMOTE:-gdrive}"
ROOT="${ROOT:-Server Backup}"
KEY_SECTION="${KEY_SECTION:-encryption key}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/opt/drive-backup/rclone.conf}"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 \"<path inside the backup folder>\" <output file>" >&2
  echo "list files first with:  rclone ls \"$REMOTE:$ROOT\"" >&2
  exit 2
fi
SRC="$1"; OUT="$2"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077

rclone copyto "$REMOTE:$ROOT/$KEY_SECTION/age-key.txt" "$WORK/key.txt"
rclone copyto "$REMOTE:$ROOT/$SRC" "$WORK/in.age"
age -d -i "$WORK/key.txt" -o "$OUT" "$WORK/in.age"
echo "decrypted to $OUT"
