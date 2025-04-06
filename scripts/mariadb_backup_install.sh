#!/usr/bin/env bash
# MariaDB Backup Installer – v1.5  (separate OnCalendar lines)
set -euo pipefail

# ---------- 1) default config ----------
cat >/etc/db-backup.conf <<'CFG'
DB_USER="root"
DB_PASS=""
DB_NAME="veritabani_adi"      # or --all-databases

BACKUP_DIR="/var/backups/sql"
MAX_DIR_SIZE=$((20*1024*1024*1024))   # 20 GB
MAX_RETRY=3
COMPRESS_CMD="pigz -p4"

# space‑separated list of HH:MM
RUN_ATS="02:00 10:00 18:00"
CFG
chmod 600 /etc/db-backup.conf

# ---------- 2) backup script (unchanged) ----------
cat >/usr/local/bin/db_backup_rotate.sh <<'BKP'
#!/usr/bin/env bash
set -uo pipefail
source /etc/db-backup.conf
command -v pigz &>/dev/null || COMPRESS_CMD="gzip"

mkdir -p "$BACKUP_DIR"; cd "$BACKUP_DIR"
DATE_FMT=$(date +'%Y-%m-%d_%H-%M')
tmp="${DB_NAME}_${DATE_FMT}.sql.gz.part"

DUMP_OPTS="--single-transaction --quick --skip-lock-tables --routines --events"
MYSQL_CRED="-u\"$DB_USER\""; [[ -n "$DB_PASS" ]] && MYSQL_CRED+=" -p\"$DB_PASS\""

for i in $(seq 1 "$MAX_RETRY"); do
  if ionice -c2 -n7 mysqldump $DUMP_OPTS $MYSQL_CRED "$DB_NAME" | \
       eval "$COMPRESS_CMD" > "$tmp"; then break; fi
  echo "Dump failed (attempt $i)" >&2; sleep 15
done

new_size=$(stat -c%s "$tmp")
dir_size=$(du -sb . | awk '{print $1}')
while (( dir_size + new_size > MAX_DIR_SIZE )); do
  oldest=$(ls -1tr . | grep -v '\.part$' | head -n 1) || true
  [[ -z "$oldest" ]] && { echo "No files left to delete!" >&2; break; }
  del_size=$(stat -c%s "$oldest"); rm -f -- "$oldest"
  dir_size=$((dir_size - del_size)); echo "Removed $oldest to free space"
done
mv "$tmp" "${tmp%.part}"
BKP
chmod +x /usr/local/bin/db_backup_rotate.sh

# ---------- 3) service ----------
cat >/etc/systemd/system/db-backup.service <<'SERV'
[Unit]
Description=MariaDB dump + rotation
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

# ---------- 4) timer creator ----------
create_timer() {
  local times=( $RUN_ATS )
  {
    echo "[Unit]"
    echo "Description=MariaDB backups at $RUN_ATS"
    echo ""
    echo "[Timer]"
    for t in "${times[@]}"; do
      echo "OnCalendar=*-*-* ${t}:00"
    done
    echo "Persistent=true"
    echo "RandomizedDelaySec=3min"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > /etc/systemd/system/db-backup.timer
}

# ---------- 5) generate timer & helper ----------
source /etc/db-backup.conf
create_timer

cat >/usr/local/bin/db_backup_update <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
source /etc/db-backup.conf
$(declare -f create_timer)
create_timer
sudo systemctl daemon-reload
sudo systemctl restart db-backup.timer
echo "Timer updated to: $RUN_ATS"
UPD
chmod +x /usr/local/bin/db_backup_update

# ---------- 6) enable ----------
systemctl daemon-reload
systemctl enable --now db-backup.timer

echo -e "\n✅ Installation complete. Edit /etc/db-backup.conf then run db_backup_update for schedule changes."
