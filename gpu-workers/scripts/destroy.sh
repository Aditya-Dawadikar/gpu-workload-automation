#!/usr/bin/env bash
# Tear down every AWS resource created by deploy.sh.
#   ./scripts/destroy.sh [-auto-approve]
source "$(dirname "$0")/common.sh"

log "Destroying cluster resources"
tf destroy "$@"
