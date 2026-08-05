#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/backup-lib/00-core.sh"
source "$SCRIPT_DIR/backup-lib/10-metadata.sh"
source "$SCRIPT_DIR/backup-lib/20-git.sh"
source "$SCRIPT_DIR/backup-lib/30-run.sh"

main "$@"
