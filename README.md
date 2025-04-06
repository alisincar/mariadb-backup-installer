# MariaDB Backup Installer

> **Zero‑dependency, size‑aware, multi‑daily MariaDB backups with one command.**

---

## ✨ Features

* **One‑liner install** – copies a single shell script, creates `systemd` service & timer.
* **Multi‑daily schedule** – define any number of times (e.g. `02:00 10:00 18:00`).
* **Live‑safe dumps** – `--single-transaction --quick --skip-lock-tables` to avoid global locks.
* **Disk‑quota rotation** – keeps the backup directory under a configurable size cap; deletes oldest files until there’s room for the incoming dump.
* **Retry & auto‑heal** – internal retry loop *plus* `Restart=on‑failure` in `systemd`.
* **Socket‑auth aware** – leave `DB_PASS` empty if your root user authenticates via unix‑socket.
* **Low I/O footprint** – `ionice` & `nice` throttle the dump; optional multi‑core `pigz` compression.
* **Single‑file config** – change everything in `/etc/db-backup.conf`; apply new schedule with `db_backup_update`.

---

## ⚡️ Quick Install

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/alisincar/mariadb-backup-installer/main/scripts/mariadb_backup_install.sh)"
```

> Replace `alisincar` with your GitHub username or fork URL.

The installer will:

1. Write default config to `/etc/db-backup.conf` (root‑only, `chmod 600`).
2. Install the backup script to `/usr/local/bin/db_backup_rotate.sh`.
3. Create `systemd` service & timer.
4. Enable & start the timer.

---

## 🛠 Requirements

| Component | Version |
|-----------|---------|
| Ubuntu / Debian | 18.04 + |
| MariaDB / MySQL client | 10.3 + |
| `pigz` *(optional)* | any |

---

## 🔧 Configuration (`/etc/db-backup.conf`)

| Variable | Purpose | Example |
|----------|---------|---------|
| `DB_USER` | MariaDB user with `SELECT, LOCK TABLES` rights | `root` |
| `DB_PASS` | Password (empty → no `-p` flag) | `""` |
| `DB_NAME` | DB name or `--all-databases` | `appdb` |
| `BACKUP_DIR` | Storage path | `/var/backups/sql` |
| `MAX_DIR_SIZE` | Max bytes for the directory | `$((20*1024*1024*1024))` |
| `MAX_RETRY` | Internal dump attempts | `3` |
| `COMPRESS_CMD` | Compression pipeline | `pigz -p4` |
| `RUN_ATS` | Space‑separated HH:MM list | `"02:00 10:00 18:00"` |

After editing, run:

```bash
sudo db_backup_update
```

This regenerates the timer and restarts it without touching running services.

---

## 🚀 How It Works

1. `systemd` timer fires → launches `db_backup_rotate.sh`.
2. Script creates a **temporary** `.part` dump via `mysqldump | gzip`.
3. Calculates required space; deletes oldest finished dumps until *new + current* ≤ `MAX_DIR_SIZE`.
4. Moves `.part` to final `.sql.gz` name → atomic swap.
5. Non‑zero exit → `systemd` retries after 30 s.


---

## 🗜 Restoring a Backup

```bash
gunzip < 2025-04-07_10-00_appdb.sql.gz | mysql -u root appdb
```

Or for `--all-databases` dumps simply omit the DB name.

---

## 🧹 Uninstall

```bash
sudo systemctl disable --now db-backup.timer db-backup.service
sudo rm /etc/systemd/system/db-backup.{timer,service}
sudo rm /usr/local/bin/db_backup_{rotate,update}.sh
sudo rm -f /etc/db-backup.conf
```

---

## 🛣 Roadmap

* 🔜 S3 / Backblaze B2 off‑site sync (via `rclone`).
* 🔜 Email / Slack failure notifications (`OnFailure=` handler).
* 🔜 Percona XtraBackup incremental mode.
* Ideas welcome – open an [Issue](https://github.com/alisincar/mariadb-backup-installer/issues)!

---

## 🤝 Contributing

1. Fork the repo & create your branch: `git checkout -b feature/foo`.
2. Commit your changes: `git commit -am 'Add foo'`.
3. Push to the branch: `git push origin feature/foo`.
4. Open a Pull Request.

Please run `shellcheck` and `shfmt` before submitting.

---

## 📜 License

Released under the **MIT License** – see [`LICENSE`](LICENSE) for details.
