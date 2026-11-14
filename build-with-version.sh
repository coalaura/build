#!/usr/bin/env bash

set -euo pipefail

builder "$@"

# Match Builder's project-directory selection so automatic toolchain upgrades apply.
project="$PWD"
target="$BUILDER_CHECK_TARGET"

if [[ -d "$target" ]]; then
    if [[ -f "$target/go.mod" || ! -f "$project/go.mod" ]]; then
        project="$target"
    fi
elif [[ -f "$target" && ! -f "$project/go.mod" ]]; then
    project="$(dirname "$target")"
fi

executable=go

if [[ "$BUILDER_CHECK_PACE" == "true" ]]; then
    executable=pace
fi

# The build has already populated the toolchain cache; never wait on a download here.
(
    cd "$project"
    timeout 2 "$executable" env GOVERSION
) > /tmp/version-check/version 2>/dev/null || true
