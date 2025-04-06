#!/usr/bin/env bash
# ------------------------------------------------------------
#  MariaDB Backup Package – multi‑daily, low‑impact, size‑aware
#  Run once as root: it installs everything. Afterwards edit
#  /etc/db-backup.conf and run db_backup_update to apply changes.
# ------------------------------------------------------------
set -euo pipefail

# -------------------- 1) Default configuration --------------------
cat >/etc/db-backup.conf <<'CFG'
# ========= MariaDB Backup Configuration =========
# Database credentials (leave DB_PASS empty if unix‑socket auth works)
DB_USER="root"
DB_PASS=""                  # empty means "no -p option"
DB_NAME="table_name"        # or --all-databases

# Storage parameters
BACKUP_DIR="/var/backups/sql"
MAX_DIR_SIZE=$((20*1024*1024*1024))   # 20 GB cap for the directory
MAX_RETRY=3                            # dump retries inside the script

# Compression – pigz is multi‑core gzip; falls back to gzip if not found
COMPRESS_CMD="pigz -p4"

# Schedule – space‑separated list of HH:MM entries (24 h)
RUN_ATS="02:00 10:00 18:00"           # three dumps per day
CFG
chmod 600 /etc/db-backup.conf

# -------------------- 2) Backup script ----------------------------
cat >/usr/local/bin/db_backup_rotate.sh <<'BKP'
#!/usr/bin/env bash
set -uo pipefail
source /etc/db-backup.conf

# fall back to gzip if pigz not present
if ! command -v pigz &>/dev/null; then COMPRESS_CMD="gzip"; fi

mkdir -p "$BACKUP_DIR"
cd "$BACKUP_DIR"
DATE_FMT=$(date +'%Y-%m-%d_%H-%M')
tmp="${DB_NAME}_${DATE_FMT}.sql.gz.part"

# Dump options for minimal locking
DUMP_OPTS="--single-transaction --quick --skip-lock-tables --routines --events"
MYSQL_CRED="-u\"$DB_USER\""
[[ -n "$DB_PASS" ]] && MYSQL_CRED+=" -p\"$DB_PASS\""

for i in $(seq 1 "$MAX_RETRY"); do
  if ionice -c2 -n7 mysqldump $DUMP_OPTS $MYSQL_CRED "$DB_NAME" | \
       eval "$COMPRESS_CMD" > "$tmp"; then
    break
  fi
  echo "Dump failed (attempt $i)" >&2
  sleep 15
done

new_size=$(stat -c%s "$tmp")
dir_size=$(du -sb "$BACKUP_DIR" | awk '{print $1}')

while (( dir_size + new_size > MAX_DIR_SIZE )); do
  oldest=$(ls -1tr "$BACKUP_DIR" | grep -v '\.part$' | head -n 1)
  [[ -z "$oldest" ]] && { echo "No files left to delete!" >&2; break; }
  del_size=$(stat -c%s "$oldest")
  rm -f -- "$oldest"
  dir_size=$((dir_size - del_size))
  echo "Removed $oldest to free space"
done

mv "$tmp" "${tmp%.part}"
BKP
chmod +x /usr/local/bin/db_backup_rotate.sh

# -------------------- 3) systemd service --------------------------
cat >/etc/systemd/system/db-backup.service <<'SERV'
[Unit]
Description=MariaDB dump + rotation (config: /etc/db-backup.conf)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/db-backup.conf
ExecStart=/usr/local/bin/db_backup_rotate.sh
Nice=15
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Restart=on-failure
RestartSec=30
SERV

# -------------------- 4) Timer creator function ------------------
create_timer() {
  local times=( $RUN_ATS )
  local cal=""
  for t in "${times[@]}"; do
    [[ -n "$cal" ]] && cal+=";"
    cal+="*-*-* ${t}"
  done

  cat >/etc/systemd/system/db-backup.timer <<TMR
[Unit]
Description=MariaDB backups at ${RUN_ATS}

[Timer]
OnCalendar=${cal}
Persistent=true
RandomizedDelaySec=3min

[Install]
WantedBy=timers.target
TMR
}

# -------------------- 5) Initial timer creation ------------------
source /etc/db-backup.conf
create_timer

# -------------------- 6) Helper to reload schedule ---------------
cat >/usr/local/bin/db_backup_update <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
source /etc/db-backup.conf

sudo bash -c "$(declare -f create_timer); create_timer"
sudo systemctl daemon-reload
sudo systemctl restart db-backup.timer
echo "Timer updated to new schedule: $RUN_ATS"
UPD
chmod +x /usr/local/bin/db_backup_update

# -------------------- 7) Enable & start --------------------------
systemctl daemon-reload
systemctl enable --now db-backup.timer

echo -e "\n✅ Installation complete. Edit /etc/db-backup.conf then run db_backup_update for schedule changes."
