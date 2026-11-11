# Troubleshooting

## Google login and rclone

| You see | Cause and fix |
| --- | --- |
| `Access blocked: invalid_client` in the browser | rclone used its shared app. Enter your own Client ID and secret during `rclone config`. |
| `scope ... drive.file invalid` | Type the full address `https://www.googleapis.com/auth/drive.file`. |
| The **Publish app** button is disabled | Fill in the Branding page first: a home page link and an authorized domain. |
| `address already in use` on port 53682 | An old rclone is still running. Close it (`taskkill /IM rclone.exe /F` on Windows, `pkill rclone` on Mac or Linux) and retry. |
| `empty token found` | The config has no login. Redo `rclone config` on your computer and copy `rclone.conf` to the server again. If you answered `y` to "Edit advanced config", rerun and answer `n`. |
| `invalid_grant`, or the backup stops after about 7 days | The Google app is still in Testing, or access was removed. Publish the app, then run `rclone config` again. |
| Drive folder not visible in the browser | Look under **My Drive** of the account you signed in with. With the `drive.file` scope, rclone only sees folders it created. |

## The backup script

| You see in the log | Cause and fix |
| --- | --- |
| `another run is active, exit` | A run is still going. Wait. The lock frees itself when the process ends. |
| `FAIL: container ... not found` | Wrong name in `DB_TARGETS`. Check `docker ps`. |
| `FAIL: ... cannot list databases` | Wrong database user. Check `docker exec <container> printenv POSTGRES_USER`. |
| `FAIL: ... dump is empty` | The database did not answer. Check that the container is healthy and run the script by hand. |
| `age-keygen failed` | `age` is not installed. Install it and run again. |
| `FAIL: upload ...` | A network or Drive error. The script retries 3 times. Check free space with `rclone about gdrive:` and run again. |
| Nothing in the log on the scheduled day | Check `crontab -l`, the server time zone (`date`) and that the server was on. |
| A removed env file or nginx site is still in Drive | By design. The script never deletes those. Remove it in the Drive website if you want it gone. |

Read the summary at the end of the log after each run: `Failures` must be `0`.

```bash
tail -25 /opt/drive-backup/drive-backup.log
```

## The cron log wrapper

| You see | Cause and fix |
| --- | --- |
| `HTTP Code  : 000` | The app did not answer: wrong port in `apps.conf`, app down, or the call timed out. |
| `HTTP Code  : 401` or `403` | `CRON_SECRET` is missing in the env file, or it differs from what the app expects. |
| `app '...' not found in apps.conf` | The first argument must match the first column of a line in `apps.conf`. |
| `cannot read .../apps.conf` | Copy `apps.conf.example` to `apps.conf`, or set `CRON_APPS_CONF`. |
| The job never appears in the log | It is in `quiet` mode and succeeded (that is by design), or cron did not run it. Check `grep CRON /var/log/syslog`. |
| `Permission denied` | Make the script runnable: `chmod 755 run-cron-job.sh`. Cron runs as your user, so that user must be able to write the log folder. |
