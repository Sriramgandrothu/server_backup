# server-tools

Small, readable shell tools for running a Linux server:

1. **Weekly encrypted backup to Google Drive.** Postgres databases (in Docker), env files, cron jobs and nginx configs go to one Drive folder. Everything sensitive is encrypted with [age](https://github.com/FiloSottile/age), and the upload uses [rclone](https://rclone.org/).
2. **Cron job runner with neat logs.** One wrapper script calls an app's cron endpoint with a secret token and writes a clear, readable block to a log file for each run.

No agents, no database, no web service. Bash, rclone, age and cron.

## What the backup does

```
Server Backup/                        (the top folder in your Drive)
├─ postgres snapshots/<folder>/<database>/<database>-DATE.dump.age   replaced every run
├─ env backup/<path under your apps folder>/env.age                  updated only when changed
├─ cron backup/crontab-<user>.txt.age, etc_cron.d_*.txt.age          updated only when changed
├─ nginx backup/sites-available/, conf.d/, nginx.conf                updated only when changed
└─ encryption key/age-key.txt                                        needed to decrypt
```

| Data | Rule | Encrypted |
| --- | --- | --- |
| Database dumps | Replaced every run. The new dump is uploaded first, and older dumps are deleted only after that worked. | Yes |
| Env files | Uploaded when new or changed (by content hash). Never deleted from Drive. | Yes |
| Cron jobs | Same as env files. | Yes |
| Nginx configs | Copied when new or changed. Never deleted from Drive. | No |
| Encryption key | Created on the first run and uploaded once. | No, it is the key |

## Repository layout

```
backup/
  weekly-drive-backup.sh    the backup script
  backup.conf.example       per-server settings (copy to backup.conf next to the script)
  decrypt-from-drive.sh     download one file from Drive and decrypt it
  crontab.example           example schedule
cron/
  run-cron-job.sh           call a cron endpoint and write a neat log block
  apps.conf.example         app list for the wrapper (copy to apps.conf)
  logrotate-cron-jobs       keep the logs small
docs/
  setup.md                  full setup, from Google Cloud to the first run
  decrypt-and-restore.md    how to decrypt and restore every kind of file
  cron-job-logs.md          the log format and how to add a job
  troubleshooting.md        errors you will probably meet and their fixes
```

## Quick start

1. Follow [docs/setup.md](docs/setup.md): create a Google login for rclone, install rclone and age, connect Drive.
2. Copy `backup/weekly-drive-backup.sh` to the server, put your settings in `backup.conf` next to it (from `backup.conf.example`), run it once by hand.
3. Add the cron line from `backup/crontab.example`.
4. **Download the encryption key from Drive and keep a copy in a password manager.** See [docs/decrypt-and-restore.md](docs/decrypt-and-restore.md).

## Security notes

- The server keeps only the **public** key. It can encrypt backups but cannot decrypt them, so a break-in on the server does not expose old backups.
- The private key sits in the same Drive as the data. Anyone who can open that Google account can read both, so keep a second copy of the key outside Drive and protect the account with 2-step verification.
- rclone uses the `drive.file` scope. It can see only the files it created, not the rest of your Drive.
- `rclone.conf` holds a login token. Keep it at mode `600` and never commit it. The `.gitignore` in this repository already blocks it, keys, env files and logs.

## Tested on

Ubuntu server with Docker-based Postgres containers, run through a full backup, an encrypted upload, a decrypt from Drive and a `pg_restore` of the downloaded dump. The cron log wrapper was tested against a local test server (success, failure and `quiet` paths).

## License

Add the license of your choice before publishing.
