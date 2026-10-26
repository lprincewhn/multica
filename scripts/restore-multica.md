# Encrypted backup restore

`restore-multica.sh` imports the standalone local restore script into version
control. It restores the archive format containing `database.dump`,
`globals.sql`, `uploads.tar.gz`, `config.tar.gz`, `manifest.txt`, and
`CONTENTS.sha256`. Configuration must contain `.env` and
`docker-compose.selfhost.yml`, with `postgres`, `backend`, and `frontend`
services and the backend uploads mount at `/app/data/uploads`.

**Destructive:** this replaces the selected deployment's database, upload files,
and configuration. Save an independent backup of the target first. Use only
trusted backups and review the archived Compose configuration before execution:
it controls which containers and host mounts Docker starts. Do not run this on
a live deployment merely to verify that the script works.

Run from any directory; the script's location does not select the target.
Supply deployment values from the current Multica project description, not
from repository defaults. No host addresses, deployment paths, credentials,
private keys, or backup archives should be committed.

```bash
bash scripts/restore-multica.sh \
  --target-dir "$RESTORE_TARGET" \
  --backup "$ENCRYPTED_BACKUP" \
  --key "$PRIVATE_KEY_FILE" \
  --project "$COMPOSE_PROJECT" \
  --uploads-volume "$UPLOADS_VOLUME" \
  --archive-image "$ARCHIVE_IMAGE"
```

All shown options are required. Paths are resolved from the caller's working
directory. The target directory and local backup/key files must already exist.
Unlike the local original, no implicit remote download or script-directory
target is used. The old `--skip-download` behavior is now the default; omit
`--remote-backup` to use a local archive.
The image needs a POSIX shell, `find`, `tar`, and gzip support. Use compatible,
preferably immutable application/database images in the archived configuration.
Docker access, Bash, Docker Compose v2, GnuPG, zstd, tar/gzip, curl, coreutils,
awk, grep, find, and sed are required.

Optional `--remote-backup "$SCP_SOURCE"` downloads into `--backup` using `scp`.
The destination parent must exist. A pre-existing destination `.sha256` sidecar
is rejected rather than silently reusing a stale checksum; download and verify
the matching checksum separately when possible, then use the local-backup mode.
Without a sidecar, the script explicitly reports that only GPG authenticated
decryption and internal content checks are used.

The private key is imported into a restricted temporary keyring, removed with
the temporary plaintext archive on exit. GPG may prompt for its passphrase.
Confirm by typing `RESTORE`, or use `--yes` only after reviewing the target.
`--skip-pull` requires all images to be available locally.

The Compose project is always explicit; PostgreSQL is addressed through that
project rather than a fixed container name. Before clearing uploads, the
backend's actual volume must match `--uploads-volume`. Configuration is restored
as archived; this script does not rewrite domains, ports, volume names, or proxy
settings. Check those separately for the target environment.

As in the original script, database restoration uses `--no-owner --no-acl`;
`globals.sql` is verified but not applied. Custom roles/grants require a separate
reviewed procedure. Failures after shutdown are reported and do not automatically
roll back partially restored data. Inspect the selected project's state before
retrying. Health checks cover the directly published backend/frontend ports,
not the public reverse proxy. Successful completion exits instead of following
login-verification-code logs indefinitely.

## Isolated tests

```bash
bash -n scripts/restore-multica.sh scripts/restore-multica.test.sh
bash scripts/restore-multica.test.sh
```

Tests use generated archives and fake Docker, GPG, zstd, scp, and curl commands;
they never access deployment secrets, contact the network, or restore live data.
They do not constitute a real restore exercise.
