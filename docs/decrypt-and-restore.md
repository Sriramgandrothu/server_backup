# Decrypt and restore

Everything sensitive in Drive is encrypted with [age](https://github.com/FiloSottile/age). Files ending in `.age` can be opened only with the private key `age-key.txt`.

## What is encrypted

| In Drive | Encrypted | File names |
| --- | --- | --- |
| `postgres snapshots/` | Yes | `<database>-DATE.dump.age`, `globals-DATE.sql.age` (roles and grants) |
| `env backup/` | Yes | `env.age`, `env.old.age`: the leading dot is dropped, the `.age` is added |
| `cron backup/` | Yes | `crontab-<user>.txt.age`, `etc_cron.d_<name>.txt.age` |
| `nginx backup/` | **No**, plain text | the original file names |
| `encryption key/age-key.txt` | **No**, it is the key | `age-key.txt` |

## Get the key

The key is in Drive at `encryption key/age-key.txt`. Download it once and store a copy in your password manager. Do not email it or paste it in chat.

> **Why a second copy matters.** The key sits in the same Drive as the data. If that Google account is locked or lost, you lose the data and the key together.

## Decrypt one file

### Fastest: the helper script

On a machine with rclone (using the same remote as the backup) and age:

```bash
backup/decrypt-from-drive.sh \
  "postgres snapshots/main-db/postgres/postgres-2026-11-06.dump.age" restored.dump
```

It downloads the key and the file into a temporary folder, decrypts, writes `restored.dump`, and deletes the key copy.

List what is in Drive first:

```bash
export RCLONE_CONFIG=/opt/drive-backup/rclone.conf
rclone ls "gdrive:Server Backup"
```

### By hand on the server

```bash
export RCLONE_CONFIG=/opt/drive-backup/rclone.conf
cd "$(mktemp -d)"
rclone copyto "gdrive:Server Backup/encryption key/age-key.txt" key.txt
rclone copyto "gdrive:Server Backup/postgres snapshots/main-db/postgres/postgres-2026-11-06.dump.age" in.age
age -d -i key.txt -o restored.dump in.age
```

### On your own computer, without rclone

Download the `.age` file and `age-key.txt` from the Drive website, then:

```bash
# install age once:  winget install FiloSottile.age   |   brew install age   |   sudo apt install age
age -d -i age-key.txt -o restored.dump postgres-2026-11-06.dump.age
```

The output is a normal file: a Postgres dump (`.dump`), a SQL file (`.sql`), an env file or a crontab.

## Restore a database

Always restore into a **test database first** and look at it before touching the live one.

```bash
docker exec main-db createdb -U postgres restore_test
docker exec -i main-db pg_restore -U postgres -d restore_test --no-owner < restored.dump
docker exec main-db psql -U postgres -d restore_test -c '\dt'
docker exec main-db dropdb -U postgres restore_test      # clean up
```

If `\dt` lists your tables, the backup is good.

Replace the live database (**this overwrites live data**: stop the apps that use it and take a fresh dump first):

```bash
docker exec -i main-db pg_restore -U postgres -d postgres --clean --if-exists --no-owner < restored.dump
```

Use the database user from your `DB_TARGETS` line. If it was `auto`, read it with `docker exec <container> printenv POSTGRES_USER`.

Roles and grants (only needed on a fresh server):

```bash
docker exec -i main-db psql -U postgres < globals.sql
```

Messages saying a role already exists are normal.

## Restore an env file

The Drive path mirrors the server path: `env backup/myapp/env.age` goes back to `<APP_ROOT>/myapp/.env`.

```bash
age -d -i key.txt -o /opt/apps/myapp/.env env.age
chmod 600 /opt/apps/myapp/.env
```

Restart the app afterwards.

## Restore cron jobs

```bash
age -d -i key.txt -o crontab-restored.txt crontab-ubuntu.txt.age
crontab crontab-restored.txt          # replaces the current user's crontab
crontab -l                            # check it
```

Files from `/etc/cron.d` go back to the same place with `sudo cp` and mode `644`.

## Restore nginx

Nginx files are not encrypted. Copy them back, enable the sites and test the config before reloading:

```bash
sudo cp my-site /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/my-site /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

## A brand new server

1. The `rclone.conf` login is **not** in the backup. Download the backup folder from the Drive website while signed in to the backup account.
2. Get the key from `encryption key/` or from your password manager.
3. Install age and Docker. Decrypt and restore as above: start the database containers first, then the apps, then nginx and cron.
4. Run through [setup.md](setup.md) again to reconnect rclone and resume the weekly backup.

## Test it now

A backup you never restored is only a guess. Once after setup, and then every few months: decrypt one dump and restore it into a test database as shown above.
