#!/usr/bin/env bash

set -euo pipefail

directory="$1"

if [[ ! -s "$directory/version" || ! -s "$directory/releases.json" ]]; then
    exit 0
fi

version="$(< "$directory/version")"

message="$(jq --raw-output --exit-status --arg version "$version" '
    def parts:
        capture("^go(?<major>[0-9]+)[.](?<minor>[0-9]+)([.](?<patch>[0-9]+))?$")
        | [.major, .minor, (.patch // "0")] | map(tonumber);

    ($version | parts) as $current
    | [.[] | select(.stable == true) | {version: .version, parts: (.version | parts)}]
    | group_by(.parts[0:2]) | map(max_by(.parts)) | sort_by(.parts) as $releases
    | [$releases[] | select(.parts[0:2] == $current[0:2])] as $matching
    | if ($matching | length) > 0 then
        $matching[-1] as $latest
        | if $current < $latest.parts then
            "Building with Go \($version | ltrimstr("go")); Go \($latest.version | ltrimstr("go")) is available."
          else empty end
      elif ($releases | length) >= 2 and $current[0:2] < $releases[0].parts[0:2] then
        "Building with Go \($version | ltrimstr("go")), which is no longer supported; the latest stable release is Go \($releases[-1].version | ltrimstr("go"))."
      else empty end
' "$directory/releases.json" 2>/dev/null)" || exit 0

printf '::warning::%s Update the "version" input for coalaura/build in your release.yml to a newer Builder release, or set it to "latest".\n' "$message"
