# Cron job logs

[`cron/run-cron-job.sh`](../cron/run-cron-job.sh) calls one cron endpoint of an app and writes a block like this to that app's log file:

```
======================================================================
UTC Time   : 2026-11-11 01:00:01 UTC
Local Time : 2026-11-11 06:30:01 IST
Job        : update-ages
Endpoint   : /api/cron/update-ages
HTTP Code  : 200
Duration   : 175 ms
Status     : SUCCESS ✅

Response:
{"ok":true,"updated":42}
======================================================================
```

A failure has the same shape with `Status     : FAILED ❌`, the HTTP code (`000` means the server did not answer at all) and whatever the app returned.

## Why one wrapper

Apps often end up with one near-identical script per app. This one script serves all of them. Per-app settings live in a small file, so a new app needs one line, not a new script.

What it does:

- Reads `CRON_SECRET` from the app's env file and sends it as `Authorization: Bearer ...`. The secret goes through a temporary `600` file, not the command line, so it never shows in `ps`.
- Logs UTC time and local time, job name, endpoint, HTTP code, duration in milliseconds, status and the response body.
- Treats any 2xx as success. Exits `0` on success and `1` on failure, so other tools can react.
- Optional `quiet` mode: writes a block **only when the call fails**. Use it for jobs that run every few minutes, so the log stays short and real problems stand out.

## Set it up

1. Copy the `cron/` folder to the server, for example to `/opt/server-tools/cron/`, and make the script runnable:

   ```bash
   chmod 755 /opt/server-tools/cron/run-cron-job.sh
   ```

2. Copy `apps.conf.example` to `apps.conf` and edit it. One line per app: name, base URL, env file, log file.

   ```
   myapp | http://127.0.0.1:3000 | /opt/apps/myapp/.env | /var/log/cron-jobs/myapp.log
   ```

   Use a local address as the base URL. The call then never leaves the server. The log folder is created on the first run.

3. Make sure the app's env file contains `CRON_SECRET=...` and the app checks that Bearer token on its cron endpoints.

4. Test one call by hand and read the log:

   ```bash
   /opt/server-tools/cron/run-cron-job.sh myapp update-ages /api/cron/update-ages
   echo "exit: $?"
   tail -15 /var/log/cron-jobs/myapp.log
   ```

5. Add it to the crontab (see [`backup/crontab.example`](../backup/crontab.example)):

   ```
   0 1 * * *   /opt/server-tools/cron/run-cron-job.sh myapp update-ages /api/cron/update-ages
   */5 * * * * /opt/server-tools/cron/run-cron-job.sh myapp health-check /api/cron/health quiet
   ```

## Settings

Environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CRON_APPS_CONF` | `apps.conf` next to the script | Path of the app list |
| `CRON_TIMEOUT` | `60` | Seconds before the call is cut off |
| `LOG_TZ` | `Asia/Kolkata` | Time zone for the "Local Time" line |
| `LOG_TZ_LABEL` | `IST` | Label printed after the local time |

Set them in the crontab line, for example `LOG_TZ=Europe/Berlin LOG_TZ_LABEL=CET /opt/server-tools/cron/run-cron-job.sh ...`.

## Keep the logs small

Install the logrotate rule: weekly rotation, 8 old logs kept, compressed.

```bash
sudo cp cron/logrotate-cron-jobs /etc/logrotate.d/cron-jobs
sudo logrotate --debug /etc/logrotate.d/cron-jobs
```

Change the path in the file if your logs are not in `/var/log/cron-jobs/`.

## Useful commands

```bash
tail -f /var/log/cron-jobs/myapp.log                      # follow live
grep -B6 "FAILED" /var/log/cron-jobs/myapp.log | tail -40  # recent failures with context
grep -c "SUCCESS" /var/log/cron-jobs/myapp.log             # count successes
```

## Backing up the cron jobs themselves

The weekly Drive backup also stores your crontab and `/etc/cron.d` files, encrypted, under `cron backup/`. See [decrypt-and-restore.md](decrypt-and-restore.md#restore-cron-jobs).
