#!/usr/bin/env bash
# DEPRECATED — superseded by publish.sh + .github/workflows/publish.yml.
#
# Previously: manually pushed dist/ artefacts to gh-pages for the install
# script at https://eonist.github.io/run-bot/.
#
# Now: publish.yml handles the full release. If gh-pages still needs updating,
# add a deploy-pages step to publish.yml instead of running this script.
#
# Do not run this manually.
echo "error: deploy.sh is deprecated and must not be run. See publish.yml instead." >&2
exit 1
