#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

TARGET_DIR=
BACKUP=
PRIVATE_KEY=
REMOTE_BACKUP=
COMPOSE_PROJECT=
UPLOADS_VOLUME=
ARCHIVE_IMAGE=
ASSUME_YES=0
SKIP_PULL=0
WORK=
DOWNLOAD_TEMP=
RESTORE_COMPLETE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Restore an encrypted Multica backup into an explicitly selected deployment.

Required options:
  --target-dir PATH       Existing deployment directory (not the scripts directory)
  --backup PATH           Local encrypted backup, or destination for a download
  --key PATH              GPG private key
  --project NAME          Target Docker Compose project
  --uploads-volume NAME  Target uploads volume
  --archive-image IMAGE  Image containing tar, find, and a POSIX shell

Options:
  --remote-backup SOURCE Download backup via scp before restoring
  --yes                  Skip the destructive-operation confirmation
  --skip-pull            Use locally available container images
  -h, --help             Show this help
EOF
}

log() {
  printf '[multica-restore] %s\n' "$*"
}

die() {
  printf '[multica-restore] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local rc=$?
  if [[ -n "$WORK" && -d "$WORK" ]]; then
    rm -rf -- "$WORK"
  fi
  if [[ -n "$DOWNLOAD_TEMP" && -f "$DOWNLOAD_TEMP" ]]; then
    rm -f -- "$DOWNLOAD_TEMP"
  fi
  if ((rc != 0 && RESTORE_COMPLETE == 0)); then
    printf '[multica-restore] Restore failed. Inspect Docker logs before retrying.\n' >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --target-dir|--backup|--key|--project|--uploads-volume|--archive-image|--remote-backup)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die "$1 requires a value"
      case "$1" in
        --target-dir) TARGET_DIR=$2 ;;
        --backup) BACKUP=$2 ;;
        --key) PRIVATE_KEY=$2 ;;
        --project) COMPOSE_PROJECT=$2 ;;
        --uploads-volume) UPLOADS_VOLUME=$2 ;;
        --archive-image) ARCHIVE_IMAGE=$2 ;;
        --remote-backup) REMOTE_BACKUP=$2 ;;
      esac
      shift 2
      ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-pull) SKIP_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$TARGET_DIR" ]] || die "--target-dir is required"
[[ -n "$BACKUP" ]] || die "--backup is required"
[[ -n "$PRIVATE_KEY" ]] || die "--key is required"
[[ "$COMPOSE_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "--project must be a valid Compose project name"
[[ "$UPLOADS_VOLUME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "--uploads-volume must be a valid volume name"
[[ -n "$ARCHIVE_IMAGE" && "$ARCHIVE_IMAGE" != -* ]] || die "--archive-image is required"
[[ -d "$TARGET_DIR" ]] || die "target directory does not exist: $TARGET_DIR"
TARGET_DIR=$(cd -- "$TARGET_DIR" && pwd -P)
[[ "$TARGET_DIR" != / ]] || die "the filesystem root cannot be a restore target"

for command in docker gpg zstd tar sha256sum curl awk grep find seq sed mktemp; do
  command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done
if [[ -n "$REMOTE_BACKUP" ]]; then
  command -v scp >/dev/null 2>&1 || die "required command not found: scp"
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable or not accessible"

if [[ -n "$REMOTE_BACKUP" ]]; then
  [[ ! -e "$BACKUP.sha256" ]] || die "remove or update the existing download checksum before downloading"
  log "Downloading the backup from $REMOTE_BACKUP"
  DOWNLOAD_TEMP=$(mktemp "$(dirname -- "$BACKUP")/.multica-backup.download.XXXXXXXX")
  scp -- "$REMOTE_BACKUP" "$DOWNLOAD_TEMP"
  [[ -s "$DOWNLOAD_TEMP" ]] || die "downloaded backup is empty"
  mv -f -- "$DOWNLOAD_TEMP" "$BACKUP"
  DOWNLOAD_TEMP=
  chmod 600 "$BACKUP"
fi

[[ -r "$BACKUP" ]] || die "backup is not readable: $BACKUP"
[[ -r "$PRIVATE_KEY" ]] || die "private key is not readable: $PRIVATE_KEY"
BACKUP=$(cd -- "$(dirname -- "$BACKUP")" && printf '%s/%s\n' "$PWD" "$(basename -- "$BACKUP")")
PRIVATE_KEY=$(cd -- "$(dirname -- "$PRIVATE_KEY")" && printf '%s/%s\n' "$PWD" "$(basename -- "$PRIVATE_KEY")")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/multica-restore.XXXXXXXX")
chmod 700 "$WORK"
GNUPGHOME="$WORK/gnupg"
ARCHIVE_ZST="$WORK/backup.tar.zst"
ARCHIVE_TAR="$WORK/backup.tar"
RESTORE_DIR="$WORK/restore"
mkdir -m 700 "$GNUPGHOME" "$RESTORE_DIR"

if [[ -r "$BACKUP.sha256" ]]; then
  log "Verifying encrypted backup checksum"
  expected_backup_hash=$(awk 'NR == 1 { print $1 }' "$BACKUP.sha256")
  actual_backup_hash=$(sha256sum "$BACKUP" | awk '{ print $1 }')
  [[ "$actual_backup_hash" == "$expected_backup_hash" ]] || die "encrypted backup checksum does not match"
else
  log "No encrypted-backup .sha256 file found; continuing with authenticated decryption and content checks"
fi

log "Importing the private key into a temporary keyring"
gpg --homedir "$GNUPGHOME" --batch --import "$PRIVATE_KEY" >/dev/null
log "Decrypting and decompressing the backup"
gpg --homedir "$GNUPGHOME" --quiet --decrypt --output "$ARCHIVE_ZST" "$BACKUP"
zstd --quiet --test "$ARCHIVE_ZST"
zstd --quiet --decompress -o "$ARCHIVE_TAR" "$ARCHIVE_ZST"

if tar -tf "$ARCHIVE_TAR" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
  die "backup archive contains an unsafe path"
fi
tar -xf "$ARCHIVE_TAR" -C "$RESTORE_DIR"
required_files=(database.dump globals.sql uploads.tar.gz config.tar.gz manifest.txt CONTENTS.sha256)
for file in "${required_files[@]}"; do
  [[ -f "$RESTORE_DIR/$file" ]] || die "backup is missing required file: $file"
done

log "Verifying all files inside the backup"
(
  cd "$RESTORE_DIR"
  # Older backups recorded absolute source paths for top-level checksum targets.
  sed -E 's#  .*/#  #' CONTENTS.sha256 > CONTENTS.local.sha256
  sha256sum -c CONTENTS.local.sha256
)
for archive in config.tar.gz uploads.tar.gz; do
  if tar -tzf "$RESTORE_DIR/$archive" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
    die "$archive contains an unsafe path"
  fi
done
config_files=$(tar -tzf "$RESTORE_DIR/config.tar.gz")
for file in .env docker-compose.selfhost.yml; do
  grep -Fxq "$file" <<<"$config_files" || die "config archive is missing $file"
done

printf '\nBackup manifest:\n'
sed 's/^/  /' "$RESTORE_DIR/manifest.txt"
printf '\nWARNING: Replaces database, uploads, and configuration in:\n  %s\n' "$TARGET_DIR"
printf 'Compose project: %s\nUploads volume: %s\n\n' "$COMPOSE_PROJECT" "$UPLOADS_VOLUME"
if ((ASSUME_YES == 0)); then
  [[ -t 0 ]] || die "confirmation requires an interactive terminal; rerun with --yes"
  read -r -p "Type RESTORE to continue: " confirmation
  [[ "$confirmation" == RESTORE ]] || die "restore cancelled"
fi

COMPOSE=(docker compose --project-directory "$TARGET_DIR" -p "$COMPOSE_PROJECT"
  --env-file "$TARGET_DIR/.env" -f "$TARGET_DIR/docker-compose.selfhost.yml")
if [[ -r "$TARGET_DIR/docker-compose.selfhost.yml" && -r "$TARGET_DIR/.env" ]]; then
  log "Stopping the existing Multica deployment"
  "${COMPOSE[@]}" down
fi
log "Restoring configuration into $TARGET_DIR"
tar -xzf "$RESTORE_DIR/config.tar.gz" -C "$TARGET_DIR"
chmod 600 "$TARGET_DIR/.env"
cd "$TARGET_DIR"
"${COMPOSE[@]}" config --quiet
if ((SKIP_PULL == 0)); then
  log "Pulling container images"
  "${COMPOSE[@]}" pull postgres backend frontend
  docker pull "$ARCHIVE_IMAGE"
fi

log "Starting PostgreSQL"
"${COMPOSE[@]}" up -d postgres
for _ in $(seq 1 90); do
  if "${COMPOSE[@]}" exec -T postgres sh -lc \
    'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
"${COMPOSE[@]}" exec -T postgres sh -lc 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null

log "Recreating and restoring the Multica database"
"${COMPOSE[@]}" exec -T postgres sh -lc \
  'exec psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='\''$POSTGRES_DB'\'' AND pid <> pg_backend_pid()" -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\"" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""'
"${COMPOSE[@]}" exec -T postgres sh -lc \
  'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl --exit-on-error' \
  < "$RESTORE_DIR/database.dump"

log "Recreating and restoring the uploads volume"
"${COMPOSE[@]}" create backend frontend
backend_id=$("${COMPOSE[@]}" ps --all --quiet backend)
[[ -n "$backend_id" && "$backend_id" != *$'\n'* ]] || die "expected exactly one backend container"
mounted_volume=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data/uploads"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' "$backend_id")
[[ "$mounted_volume" == "$UPLOADS_VOLUME" ]] || die "backend uploads volume does not match --uploads-volume"
docker run --rm --network none -v "$UPLOADS_VOLUME:/restore" "$ARCHIVE_IMAGE" \
  sh -lc 'find /restore -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
docker run --rm -i --network none -v "$UPLOADS_VOLUME:/restore" "$ARCHIVE_IMAGE" \
  tar -xzf - -C /restore < "$RESTORE_DIR/uploads.tar.gz"

log "Starting Multica"
"${COMPOSE[@]}" up -d
backend_address=$("${COMPOSE[@]}" port backend 8080)
frontend_address=$("${COMPOSE[@]}" port frontend 3000)
backend_address=${backend_address/0.0.0.0/127.0.0.1}
frontend_address=${frontend_address/0.0.0.0/127.0.0.1}
health=
for _ in $(seq 1 90); do
  if health=$(curl -fsS --max-time 3 "http://$backend_address/health" 2>/dev/null); then
    break
  fi
  sleep 2
done
[[ -n "$health" ]] || {
  "${COMPOSE[@]}" logs --tail 150 backend frontend >&2
  die "backend health check failed"
}
frontend_ready=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 "http://$frontend_address/" >/dev/null 2>&1; then
    frontend_ready=1
    break
  fi
  sleep 2
done
((frontend_ready == 1)) || {
  "${COMPOSE[@]}" logs --tail 150 frontend >&2
  die "frontend check failed"
}
table_count=$("${COMPOSE[@]}" exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select count(*) from pg_catalog.pg_tables where schemaname = '\''public'\''"')
upload_count=$(docker run --rm --network none -v "$UPLOADS_VOLUME:/data:ro" "$ARCHIVE_IMAGE" \
  sh -lc 'find /data -type f | wc -l')
printf '\nMultica restore completed successfully.\n'
printf '  Target:         %s\n' "$TARGET_DIR"
printf '  Backend health: %s\n' "$health"
printf '  Frontend:       http://%s/\n' "$frontend_address"
printf '  Public tables:  %s\n' "$table_count"
printf '  Upload files:   %s\n' "$upload_count"
"${COMPOSE[@]}" ps
RESTORE_COMPLETE=1
