# Setup

This takes about 30 minutes. Most of it is a one-time Google login.

## Requirements

- A Linux server (Ubuntu or Debian assumed) and SSH access with `sudo`
- Postgres running in Docker containers. For Postgres outside Docker, replace the `docker exec ... pg_dump` lines in the script with a direct `pg_dump`.
- A Google account with free Drive space (the free 15 GB is plenty, backups are small)
- A computer with a web browser. The Google login needs one, and servers usually have none.
- A password manager, for a second copy of the encryption key

## 1. Create your own Google login for rclone

rclone's built-in Google app is shared by everyone and often fails with `Access blocked: invalid_client`. Make your own. It is free and you do it once.

1. Open <https://console.cloud.google.com>, create a project named `drive-backup` and select it.
2. Go to **APIs & Services > Library**, search **Google Drive API** and click **Enable**.
3. Go to **Google Auth Platform > Branding**. Enter an app name, your support email and developer email. Add a home page link and one authorized domain. The Publish button stays disabled until these are filled in.
4. Open **Audience**, choose **External**, click **Publish app** and confirm. The status must read **In production**.
5. Open **Clients > Create client**, choose **Desktop app**, name it `rclone`. Copy the **Client ID** and **Client secret**.

> **Do not leave the app in Testing.** In Testing mode Google expires the login every 7 days and the backup silently stops. The `drive.file` scope is not sensitive, so production needs no verification review.
>
> Keep the client secret private. Never paste it into chat, tickets or public repositories.

## 2. Install the tools

On the server:

```bash
sudo apt update
sudo apt install -y age util-linux
curl https://rclone.org/install.sh | sudo bash
rclone version && age --version
```

`age` encrypts the backups. `flock` (from `util-linux`) stops two runs from overlapping.

On your own computer, install rclone too: `winget install Rclone.Rclone` (Windows), `brew install rclone` (Mac), or the same `curl` line as above (Linux).

Create the folder that holds everything for the backup:

```bash
sudo mkdir -p /opt/drive-backup
sudo chown "$USER" /opt/drive-backup
chmod 700 /opt/drive-backup
```

## 3. Connect rclone to Drive

Do this **on your own computer**, where a browser is available.

```bash
rclone config
```

| Prompt | Answer |
| --- | --- |
| `e/n/d/r/c/s/q>` | `n` (new remote) |
| `name>` | `gdrive` |
| `Storage>` | `drive` |
| `client_id>` | the Client ID from step 1 |
| `client_secret>` | the Client secret from step 1 |
| `scope>` | the full address `https://www.googleapis.com/auth/drive.file` (the short form `drive.file` fails with "scope invalid") |
| `service_account_file>` | leave blank |
| Edit advanced config? | `n` |
| Use web browser to automatically authenticate? | `y` |
| Configure as a Shared Drive? | `n` |
| Keep this remote? | `y`, then `q` |

A browser tab opens. Sign in with the Google account that owns the Drive, continue through the "app not verified" notice if it shows, and allow access.

Copy the finished config to the server and test it:

```bash
rclone config file                       # shows where the file is on your computer
scp /path/to/rclone.conf USER@SERVER:/opt/drive-backup/rclone.conf

# on the server
chmod 600 /opt/drive-backup/rclone.conf
export RCLONE_CONFIG=/opt/drive-backup/rclone.conf
rclone mkdir gdrive:connection-test
rclone lsd gdrive:                       # should list connection-test
rclone rmdir gdrive:connection-test
```

Why copy instead of logging in on the server: pasting a token into a server config often ends in `empty token found`. Copying the finished file avoids that.

## 4. Add the backup script

Copy [`backup/weekly-drive-backup.sh`](../backup/weekly-drive-backup.sh) to `/opt/drive-backup/` and make it runnable:

```bash
scp backup/weekly-drive-backup.sh USER@SERVER:/opt/drive-backup/
ssh USER@SERVER chmod 700 /opt/drive-backup/weekly-drive-backup.sh
```

Put your settings in `backup.conf` next to the script (start from `backup/backup.conf.example`). It overrides the block at the top of the script (`EDIT THIS BLOCK`), so later you can replace the script with a newer copy from this repository without editing it again:

```bash
scp backup/backup.conf.example USER@SERVER:/opt/drive-backup/backup.conf
ssh USER@SERVER chmod 600 /opt/drive-backup/backup.conf
```

| Setting | Set it to |
| --- | --- |
| `REMOTE` | The remote name from step 3 (`gdrive`) |
| `ROOT` | The top folder name in Drive. It is created on the first run. |
| `BASE` | The server folder from step 2 |
| `APP_ROOT` | The folder that holds your apps. Every `.env` file under it is backed up. |
| `DB_TARGETS` | One line per Postgres container: `"section\|folder\|container\|user"`. Use `auto` to read `POSTGRES_USER` from the container; if that login no longer exists (for example it was renamed), it falls back to `postgres`. |
| `ENV_EXCLUDE` | Folders under `APP_ROOT` whose env files are skipped, such as old backups or logs. |

Find container names with `docker ps --format '{{.Names}}'`. Every database inside a container is backed up, plus its roles and grants.

## 5. Run it once by hand

```bash
/opt/drive-backup/weekly-drive-backup.sh
echo "exit code: $?"
tail -30 /opt/drive-backup/drive-backup.log
```

The first run also creates the encryption key and uploads it to Drive. Check three things:

1. The exit code is `0` and the log ends with `failures: 0`. Each `FAIL:` line names a problem.
2. The folder exists in Drive and contains `encryption key/age-key.txt`.
3. Run it a second time. Env files should show `0 uploaded`, and database dumps are replaced, not added.

The log ends with a summary:

```
---------------- SUMMARY 2026-11-06 ----------------
Drive folder before        0B in 0 files
Drive folder after         12MiB in 55 files
Difference                 +12MiB
Uploaded this run          12MiB in 55 files
Database snapshots         22 replaced
Env files                  17 uploaded, 0 unchanged
Nginx files                13 new/changed
Cron jobs                  4 uploaded, 0 unchanged
Drive storage used         1.2 GiB of 15 GiB, free 13.8 GiB
Failures                   0
Duration                   466s
```

(The numbers are examples. Yours will differ.)

## 6. Schedule it

cron uses the server's clock. Check the time zone first:

```bash
date
timedatectl | grep "Time zone"
```

Cron fields are minute, hour, day of month, month, day of week (`0` or `7` is Sunday, `6` is Saturday).

| You want | Server time zone | Cron line |
| --- | --- | --- |
| Sunday 03:00 | local time | `0 3 * * 0` |
| Sunday 03:00 India time (IST) | UTC | `30 21 * * 6` (03:00 IST is Saturday 21:30 UTC) |
| Every night 02:00 | any | `0 2 * * *` |

Add the line without touching the rest of your crontab:

```bash
crontab -l > /opt/drive-backup/crontab.backup 2>/dev/null
( crontab -l 2>/dev/null; echo '0 3 * * 0 /opt/drive-backup/weekly-drive-backup.sh' ) | crontab -
crontab -l
```

The script writes its own log, so cron needs no output redirect.

## 7. Save the encryption key

Download `encryption key/age-key.txt` from Drive once and keep it in a password manager. Without it the encrypted files are unreadable. See [decrypt-and-restore.md](decrypt-and-restore.md).

## Add a database later

Add one line to `DB_TARGETS` in `backup.conf`. A new database container is not backed up until you do. New env files, cron jobs and nginx sites need no change: the next run finds them.
