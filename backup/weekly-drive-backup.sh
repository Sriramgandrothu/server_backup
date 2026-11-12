#!/usr/bin/env bash
# Weekly encrypted backup of Postgres databases (in Docker), env files, cron jobs and nginx configs
# to Google Drive.  Needs: rclone (remote already set up), age, docker, flock.
#
#   <ROOT>/
#     <section>/<folder>/<database>/<database>-DATE.dump.age   replaced every run
#     <ENV_SECTION>/<path under APP_ROOT>/<file>.age           added or updated when changed, never deleted
#     <CRON_SECTION>/<file>.age                                added or updated when changed, never deleted
#     <NGINX_SECTION>/...                                      added or updated, never deleted (not encrypted)
#     encryption key/age-key.txt                               private key needed to decrypt
set -uo pipefail
umask 077

# ======================= EDIT THIS BLOCK =======================
REMOTE="gdrive"                      # rclone remote name
ROOT="Server Backup"                 # top folder in Drive
BASE=/opt/drive-backup               # where this script, rclone.conf, state and log live
APP_ROOT=/opt/apps                   # env files are searched under this folder
ENV_SECTION="env backup"
NGINX_SECTION="nginx backup"
CRON_SECTION="cron backup"
KEY_SECTION="encryption key"

# One line per Postgres container:  "Drive section|Drive folder|container name|database user"
# Use "auto" to read POSTGRES_USER from the container (falls back to "postgres" when that login
# no longer exists, for example after it was renamed).
DB_TARGETS=(
  "postgres snapshots|main-db|main-db|auto"
  "postgres snapshots|app-db|app-db-1|postgres"
)

# Folders under APP_ROOT whose env files are NOT backed up (BASE is always skipped).
ENV_EXCLUDE=()
# ===============================================================

# Optional per-server settings: a backup.conf next to this script overrides the block above,
# so the script itself can stay identical to the repository copy.
CONF="${BACKUP_CONF:-$(dirname "$(readlink -f "$0")")/backup.conf}"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

export RCLONE_CONFIG="$BASE/rclone.conf"
KEYFILE="$BASE/age-key.txt"          # private key: exists only until it is uploaded
RECIPIENT_FILE="$BASE/age-recipient.txt"
STATE="$BASE/state"
TMP="$BASE/tmp"
LOG="$BASE/drive-backup.log"
DATE=$(date +%F)
FAILS=0
START=$(date +%s)
N_SNAP=0; N_ENV_UP=0; N_ENV_SAME=0; N_NGX_UP=0; UP_BYTES=0; UP_FILES=0

mkdir -p "$BASE" "$STATE" "$TMP"
exec >>"$LOG" 2>&1
echo
echo "=== $(date -Is) backup start"

exec 9>"$BASE/lock"
flock -n 9 || { echo "another run is active, exit"; exit 1; }
trap 'rm -rf "$TMP"/*' EXIT

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
r() { rclone "$@" --retries 3 --low-level-retries 5; }
hs() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
sent() { UP_BYTES=$((UP_BYTES + $(stat -c%s "$1"))); UP_FILES=$((UP_FILES + 1)); }
drive_stats() {
  local j b n
  j=$(rclone size "$REMOTE:$ROOT" --json 2>/dev/null) || { echo "0 0"; return; }
  b=$(echo "$j" | grep -o '"bytes":[0-9]*' | cut -d: -f2); n=$(echo "$j" | grep -o '"count":[0-9]*' | cut -d: -f2)
  echo "${b:-0} ${n:-0}"
}
read -r BEFORE_B BEFORE_N <<<"$(drive_stats)"
echo "Drive backup folder before: $(hs "$BEFORE_B") in $BEFORE_N files"
echo

# --- encryption key: create once, upload the private key to Drive, keep only the public key here
if [ ! -s "$RECIPIENT_FILE" ]; then
  age-keygen -o "$KEYFILE" 2>/dev/null || { echo "age-keygen failed"; exit 1; }
  age-keygen -y "$KEYFILE" >"$RECIPIENT_FILE"
  if r copyto "$KEYFILE" "$REMOTE:$ROOT/$KEY_SECTION/age-key.txt"; then
    echo "age key created and uploaded to Drive"
    rm -f "$KEYFILE"
  else
    rm -f "$RECIPIENT_FILE"
    echo "key upload failed, abort"; exit 1
  fi
fi
RECIPIENT=$(cat "$RECIPIENT_FILE")
enc() { age -r "$RECIPIENT" -o "$2" "$1"; }
row() { printf '%-5s %-22s %-40s %10s\n' "$1" "$2" "$3" "$4"; }

# --- 1. database snapshots: upload the new dump first, delete older ones only when that worked
snapshot() { # <section> <folder> <container> <db user>
  local section="$1" folder="$2" c="$3" user="$4"
  local dbs db out new dest
  if [ "$user" = "auto" ]; then
    user=$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null)
    docker exec "$c" psql -U "${user:-postgres}" -d postgres -Atc 'select 1' >/dev/null 2>&1 || user=postgres
  fi
  [ -n "$user" ] || { fail "$c: no database user"; return; }
  dbs=$(docker exec "$c" psql -U "$user" -d postgres -At -c "select datname from pg_database where not datistemplate" 2>/dev/null) \
    || { fail "$c: cannot list databases"; return; }
  dbs="$dbs"$'\n'"globals"   # roles and grants
  while read -r db; do
    [ -z "$db" ] && continue
    if [ "$db" = "globals" ]; then
      out="$TMP/$folder-globals-$DATE.sql"
      docker exec "$c" pg_dumpall -U "$user" --globals-only >"$out" 2>/dev/null || { fail "$c globals dump"; continue; }
      new="globals-$DATE.sql.age"
    else
      out="$TMP/$folder-$db-$DATE.dump"
      docker exec "$c" pg_dump -U "$user" -Fc "$db" >"$out" 2>/dev/null || { fail "$c/$db dump"; continue; }
      new="$db-$DATE.dump.age"
    fi
    [ -s "$out" ] || { fail "$c/$db dump is empty"; continue; }
    enc "$out" "$out.age" && rm -f "$out" || { fail "$c/$db encrypt"; continue; }
    dest="$REMOTE:$ROOT/$section/$folder/$db"
    if r copyto "$out.age" "$dest/$new"; then
      r delete "$dest" --exclude "/$new" || fail "$c/$db cleanup of old snapshots"
      N_SNAP=$((N_SNAP + 1)); sent "$out.age"
      row ok "$section" "$folder/$db" "$(hs "$(stat -c%s "$out.age")")"
    else
      fail "$c/$db upload"
    fi
    rm -f "$out.age"
  done <<<"$dbs"
}

row "" "SECTION" "ITEM" "SIZE"
for t in "${DB_TARGETS[@]}"; do
  IFS='|' read -r section folder c user <<<"$t"
  docker inspect "$c" >/dev/null 2>&1 || { fail "container $c not found"; continue; }
  snapshot "$section" "$folder" "$c" "$user"
done

# --- 2. env files: upload when new or changed (content hash), never delete from Drive
touch "$STATE/env.sha"
while IFS= read -r f; do
  rel="${f#$APP_ROOT/}"
  dir=$(dirname "$rel"); name=$(basename "$rel"); name="${name#.}"
  sum=$(sha256sum "$f" | cut -d' ' -f1)
  if grep -qxF "$sum  $rel" "$STATE/env.sha"; then N_ENV_SAME=$((N_ENV_SAME + 1)); continue; fi
  enc "$f" "$TMP/env.age" || { fail "encrypt $rel"; continue; }
  if r copyto "$TMP/env.age" "$REMOTE:$ROOT/$ENV_SECTION/$dir/$name.age"; then
    awk -v r="$rel" 'substr($0, 67) != r' "$STATE/env.sha" >"$STATE/env.sha.new" || true
    echo "$sum  $rel" >>"$STATE/env.sha.new"; mv "$STATE/env.sha.new" "$STATE/env.sha"
    N_ENV_UP=$((N_ENV_UP + 1)); sent "$TMP/env.age"
    row ok "env (new/changed)" "$rel" "$(hs "$(stat -c%s "$TMP/env.age")")"
  else
    fail "upload env $rel"
  fi
  rm -f "$TMP/env.age"
done < <(
  skip=(-not -path "$BASE/*")
  for d in "${ENV_EXCLUDE[@]}"; do skip+=(-not -path "${d%/}/*"); done
  find "$APP_ROOT" -maxdepth 6 -type f \( -name ".env" -o -name ".env.*" \) ! -name "*.example" \
    -not -path "*/node_modules/*" -not -path "*/.next/*" -not -path "*/.git/*" "${skip[@]}" 2>/dev/null)

# --- 3. nginx: copy new and changed files (--update), never delete from Drive
nginx_copy() { # <rclone verb> <source> <destination>
  local out
  [ -e "$2" ] || return 0
  if out=$(r "$1" --update --copy-links "$2" "$REMOTE:$ROOT/$NGINX_SECTION/$3" -v 2>&1); then
    N_NGX_UP=$((N_NGX_UP + $(echo "$out" | grep -c "Copied (")))
  else
    fail "nginx $3"
  fi
}
nginx_copy copy /etc/nginx/sites-available sites-available
nginx_copy copy /etc/nginx/conf.d conf.d
nginx_copy copyto /etc/nginx/nginx.conf nginx.conf
row ok nginx "$N_NGX_UP new/changed file(s), the rest unchanged" ""

# --- 4. cron jobs: user crontab and /etc/cron.d, encrypted, uploaded when changed, never deleted
touch "$STATE/cron.sha"
N_CRON_UP=0; N_CRON_SAME=0
cron_upload() { # <state key> <source file> <Drive file name>
  local key="$1" src="$2" dname="$3" sum
  sum=$(sha256sum "$src" | cut -d' ' -f1)
  if grep -qxF "$sum  $key" "$STATE/cron.sha"; then N_CRON_SAME=$((N_CRON_SAME + 1)); return; fi
  enc "$src" "$TMP/cron.age" || { fail "encrypt cron $key"; return; }
  if r copyto "$TMP/cron.age" "$REMOTE:$ROOT/$CRON_SECTION/$dname.age"; then
    awk -v r="$key" 'substr($0, 67) != r' "$STATE/cron.sha" >"$STATE/cron.sha.new" || true
    echo "$sum  $key" >>"$STATE/cron.sha.new"; mv "$STATE/cron.sha.new" "$STATE/cron.sha"
    N_CRON_UP=$((N_CRON_UP + 1)); sent "$TMP/cron.age"
    row ok "cron (new/changed)" "$key" "$(hs "$(stat -c%s "$TMP/cron.age")")"
  else
    fail "upload cron $key"
  fi
  rm -f "$TMP/cron.age"
}
if crontab -l >"$TMP/user-crontab.txt" 2>/dev/null && [ -s "$TMP/user-crontab.txt" ]; then
  cron_upload "crontab:$(whoami)" "$TMP/user-crontab.txt" "crontab-$(whoami).txt"
fi
for f in /etc/crontab /etc/cron.d/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in .placeholder) continue;; esac
  cron_upload "$f" "$f" "etc$(echo "$f" | tr '/' '_').txt"
done

# --- summary
read -r AFTER_B AFTER_N <<<"$(drive_stats)"
DIFF=$((AFTER_B - BEFORE_B)); SIGN="+"; [ "$DIFF" -lt 0 ] && { SIGN="-"; DIFF=$((-DIFF)); }
line() { printf '%-26s %s\n' "$1" "$2"; }
echo
echo "---------------- SUMMARY $DATE ----------------"
line "Drive folder before"  "$(hs "$BEFORE_B") in $BEFORE_N files"
line "Drive folder after"   "$(hs "$AFTER_B") in $AFTER_N files"
line "Difference"           "$SIGN$(hs "$DIFF")"
line "Uploaded this run"    "$(hs "$UP_BYTES") in $UP_FILES files"
line "Database snapshots"   "$N_SNAP replaced"
line "Env files"            "$N_ENV_UP uploaded, $N_ENV_SAME unchanged"
line "Nginx files"          "$N_NGX_UP new/changed"
line "Cron jobs"            "$N_CRON_UP uploaded, $N_CRON_SAME unchanged"
ABOUT=$(rclone about "$REMOTE:" 2>/dev/null)
line "Drive storage used"   "$(echo "$ABOUT" | awk '/^Used/ {print $2, $3}') of $(echo "$ABOUT" | awk '/^Total/ {print $2, $3}'), free $(echo "$ABOUT" | awk '/^Free/ {print $2, $3}')"
line "Failures"             "$FAILS"
line "Duration"             "$(( $(date +%s) - START ))s"
echo "=== $(date -Is) backup end, failures: $FAILS"
[ "$FAILS" -eq 0 ]
