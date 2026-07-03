#!/usr/bin/env bash
# publish.sh has been removed.
#
# To trigger a release, use:
#   gh workflow run publish.yml --ref main --field channel=release --field dry_run=false
#
# To trigger a beta:
#   gh workflow run publish.yml --ref main --field channel=beta --field dry_run=false
#
# To dry run:
#   gh workflow run publish.yml --ref main --field channel=release --field dry_run=true
#
# See docs/RELEASING.md for full instructions.
echo "publish.sh has been removed. See comments above or docs/RELEASING.md."
exit 1
