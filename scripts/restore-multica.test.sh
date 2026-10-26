#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/restore-multica.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/target with spaces" "$TMP/content" "$TMP/config" "$TMP/uploads"
export CALLS="$TMP/calls"
export FAIL_AT=
export FIXTURE_BACKUP="$TMP/backup"
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  info|pull) exit 0 ;;
  compose)
    [[ "$2" != version ]] || exit 0
    [[ "$*" == *"-p fixture-project"* ]] || exit 81
    case "$*" in
      *"pg_restore"*)
        [[ "$FAIL_AT" != database ]] || exit 82
        cat >/dev/null
        ;;
      *"port backend"*) echo '127.0.0.1:18080' ;;
      *"port frontend"*) echo '127.0.0.1:13000' ;;
      *"ps --all --quiet backend"*) echo fixture-backend ;;
      *"select count"*) echo 42 ;;
    esac
    ;;
  inspect)
    if [[ "$FAIL_AT" == volume ]]; then echo wrong-volume; else echo fixture-uploads; fi
    ;;
  run)
    case "$*" in
      *"tar -xzf"*) cat >/dev/null ;;
      *"wc -l"*) echo 7 ;;
    esac
    ;;
  *) exit 83 ;;
esac
MOCK
cat > "$TMP/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'gpg %s\n' "$*" >> "$CALLS"
[[ "$FAIL_AT" != decrypt ]] || exit 84
[[ "$*" != *--import* ]] || exit 0
while (($#)); do
  if [[ "$1" == --output ]]; then output=$2; shift 2; else input=$1; shift; fi
done
cp -- "$input" "$output"
MOCK
cat > "$TMP/bin/zstd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" != *--test* ]] || exit 0
while (($#)); do
  if [[ "$1" == -o ]]; then output=$2; shift 2; else input=$1; shift; fi
done
cp -- "$input" "$output"
MOCK
cat > "$TMP/bin/scp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo scp >> "$CALLS"
cp -- "$FIXTURE_BACKUP" "${@: -1}"
MOCK
cat > "$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
[[ "$FAIL_AT" != health ]] || exit 85
echo healthy
MOCK
cat > "$TMP/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
printf 'fixture env\n' > "$TMP/config/.env"
printf 'fixture compose\n' > "$TMP/config/docker-compose.selfhost.yml"
printf 'fixture upload\n' > "$TMP/uploads/file"
tar -czf "$TMP/content/config.tar.gz" -C "$TMP/config" .env docker-compose.selfhost.yml
tar -czf "$TMP/content/uploads.tar.gz" -C "$TMP/uploads" file
printf 'fixture database\n' > "$TMP/content/database.dump"
printf 'fixture globals\n' > "$TMP/content/globals.sql"
printf 'fixture manifest\n' > "$TMP/content/manifest.txt"
(
  cd "$TMP/content"
  sha256sum database.dump globals.sql uploads.tar.gz config.tar.gz manifest.txt > CONTENTS.sha256
)
pack() {
  tar -cf "$TMP/backup" -C "$TMP/content" \
    database.dump globals.sql uploads.tar.gz config.tar.gz manifest.txt CONTENTS.sha256
}
pack
touch "$TMP/key"
args=(--target-dir "$TMP/target with spaces" --backup "$TMP/backup" --key "$TMP/key"
  --project fixture-project --uploads-volume fixture-uploads --archive-image fixture-image)
reject() {
  local expected=$1
  shift
  : > "$CALLS"
  if bash "$SCRIPT" "$@" > "$TMP/result" 2>&1; then
    echo "Unexpected success: $*" >&2
    exit 1
  fi
  grep -F -- "$expected" "$TMP/result" >/dev/null || {
    cat "$TMP/result" >&2
    exit 1
  }
}
bash "$SCRIPT" --help > "$TMP/result"
grep -F -- '--target-dir' "$TMP/result" >/dev/null
reject '--target-dir is required'
reject 'requires a value' --backup
reject 'requires a value' --key --yes
reject 'unknown argument' --unknown
reject 'valid Compose project' "${args[@]}" --project ../bad
reject 'valid volume name' "${args[@]}" --uploads-volume bad:/mount
reject 'filesystem root' "${args[@]}" --target-dir /
reject 'confirmation requires' "${args[@]}" </dev/null
! grep -F ' down' "$CALLS" >/dev/null

echo 'bad checksum' > "$TMP/backup.sha256"
reject 'encrypted backup checksum does not match' "${args[@]}" --yes
! grep -F 'gpg ' "$CALLS" >/dev/null
rm "$TMP/backup.sha256"
printf 'corrupted database\n' > "$TMP/content/database.dump"
pack
reject 'FAILED' "${args[@]}" --yes
! grep -F ' down' "$CALLS" >/dev/null
printf 'fixture database\n' > "$TMP/content/database.dump"
pack

export FAIL_AT=decrypt
reject 'Restore failed' "${args[@]}" --yes
! grep -F ' down' "$CALLS" >/dev/null
export FAIL_AT=database
reject 'Restore failed' "${args[@]}" --yes
! grep -F 'find /restore' "$CALLS" >/dev/null
export FAIL_AT=volume
reject 'uploads volume does not match' "${args[@]}" --yes
! grep -F 'find /restore' "$CALLS" >/dev/null
export FAIL_AT=health
reject 'backend health check failed' "${args[@]}" --yes
export FAIL_AT=

: > "$CALLS"
sha256sum "$TMP/backup" > "$TMP/backup.sha256"
bash "$SCRIPT" "${args[@]}" --yes > "$TMP/result" 2>&1
grep -F 'completed successfully' "$TMP/result" >/dev/null
grep -F 'Public tables:  42' "$TMP/result" >/dev/null
grep -F 'Upload files:   7' "$TMP/result" >/dev/null
grep -F 'pull postgres backend frontend' "$CALLS" >/dev/null
grep -F 'pull fixture-image' "$CALLS" >/dev/null
grep -F -- '-v fixture-uploads:/restore' "$CALLS" >/dev/null
cmp "$TMP/config/.env" "$TMP/target with spaces/.env"
[[ "$(stat -c %a "$TMP/target with spaces/.env")" == 600 ]]
! grep -E 'logs -f|Verification code|multica-postgres-1|multica_backend_uploads' "$CALLS" >/dev/null

: > "$CALLS"
bash "$SCRIPT" "${args[@]}" --yes --skip-pull > "$TMP/result" 2>&1
! grep -F 'pull ' "$CALLS" >/dev/null
grep -F ' down' "$CALLS" >/dev/null
reject 'existing download checksum' "${args[@]}" --remote-backup fixture:archive --yes
! grep -Fx scp "$CALLS" >/dev/null
bash "$SCRIPT" "${args[@]}" --backup "$TMP/download" \
  --remote-backup fixture:archive --yes --skip-pull > "$TMP/result" 2>&1
grep -Fx scp "$CALLS" >/dev/null
cmp "$TMP/backup" "$TMP/download"
printf 'Restore fixture tests passed.\n'
