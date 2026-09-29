#!/usr/bin/env bash

set -euo pipefail

error() {
    echo "::error::$1"
    exit 1
}

validate_bool() {
    local name="$1"
    local value="$2"

    case "$value" in
        true|false)
            ;;
        *)
            error "$name must be true or false"
            ;;
    esac
}

append_lines() {
    local value="$1"
    local -n destination="$2"

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            destination+=("$line")
        fi
    done <<< "$value"
}

add_host_mapping() {
    local hostname="$1"
    local line=""
    local address=""
    local aliases=""
    local alias=""
    local mapping=""

    if [[ ! -f /etc/hosts ]]; then
        return
    fi

    while IFS= read -r line; do
        line="${line%%#*}"

        read -r address aliases <<< "$line" || true

        if [[ -z "$address" || -z "$aliases" ]]; then
            continue
        fi

        for alias in $aliases; do
            if [[ "$alias" != "$hostname" ]]; then
                continue
            fi

            mapping="$hostname=$address"

            if [[ -n "${forwarded_host_mappings[$mapping]:-}" ]]; then
                return
            fi

            docker_arguments+=(--add-host "$mapping")
            forwarded_host_mappings["$mapping"]=1

            if [[ "$address" == 127.* || "$address" == "::1" ]]; then
                use_host_network=true
            fi

            return
        done
    done < /etc/hosts
}

add_host_mappings_from_value() {
    local value="$1"
    local candidates=""
    local candidate=""
    local authority=""
    local hostname=""

    candidates="${value//,/ }"
    candidates="${candidates//|/ }"

    for candidate in $candidates; do
        if [[ ! "$candidate" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
            continue
        fi

        authority="${candidate#*://}"
        authority="${authority%%/*}"
        authority="${authority##*@}"

        if [[ "$authority" == \[*\]* ]]; then
            hostname="${authority%%]*}"
            hostname="${hostname#[}"
        else
            hostname="${authority%%:*}"
        fi

        if [[ -n "$hostname" ]]; then
            add_host_mapping "$hostname"
        fi
    done
}

forward_environment_variable() {
    local name="$1"

    if [[ ! -v "$name" ]]; then
        return
    fi

    docker_arguments+=(--env "$name")
    add_host_mappings_from_value "${!name}"
}

validate_bool "cgo" "$INPUT_CGO"
validate_bool "minify" "$INPUT_MINIFY"
validate_bool "generate" "$INPUT_GENERATE"
validate_bool "gui" "$INPUT_GUI"
validate_bool "debug" "$INPUT_DEBUG"
validate_bool "external-go-cache" "$USE_EXTERNAL_GO_CACHE"

case "$INPUT_OS" in
    linux|windows|darwin)
        ;;
    *)
        error "os must be linux, windows, or darwin"
        ;;
esac

if [[ -z "$INPUT_ARCH" ]]; then
    error "arch cannot be empty"
fi

case "$INPUT_LINK" in
    static|dynamic)
        ;;
    *)
        error "link must be static or dynamic"
        ;;
esac

case "$INPUT_OPTIMIZATION" in
    optimize|compatible)
        ;;
    *)
        error "optimization must be optimize or compatible"
        ;;
esac

if [[ "$INPUT_LINK" == "dynamic" && "$INPUT_CGO" != "true" ]]; then
    error "dynamic linking requires cgo: true"
fi

base_image="$BUILDER_IMAGE"
image="$base_image"

arguments=(
    build
    go
    "$INPUT_OS"
    --arch
    "$INPUT_ARCH"
)

if [[ "$INPUT_CGO" == "true" ]]; then
    arguments+=(--cgo)
else
    arguments+=(--pure)
fi

case "$INPUT_LINK" in
    static)
        arguments+=(--static)
        ;;
    dynamic)
        arguments+=(--dynamic)
        ;;
esac

case "$INPUT_OPTIMIZATION" in
    optimize)
        arguments+=(--optimize)
        ;;
    compatible)
        arguments+=(--compatible)
        ;;
esac

if [[ "$INPUT_MINIFY" == "true" ]]; then
    arguments+=(--minify)
else
    arguments+=(--no-minify)
fi

if [[ "$INPUT_GENERATE" == "true" ]]; then
    arguments+=(--generate)
else
    arguments+=(--no-generate)
fi

if [[ "$INPUT_GUI" == "true" ]]; then
    arguments+=(--gui)
fi

if [[ -n "$INPUT_PACKAGE" ]]; then
    arguments+=(--package "$INPUT_PACKAGE")
fi

output=""

if [[ -n "$INPUT_OUTPUT" ]]; then
    output="$INPUT_OUTPUT"

    if [[ "$output" != /* ]]; then
        output="$GITHUB_WORKSPACE/$output"
    fi

    mkdir -p "$(dirname "$output")"

    arguments+=(--output "$output")
fi

if [[ "$INPUT_DEBUG" == "true" ]]; then
    arguments+=(--debug)
fi

append_lines "$INPUT_GO_FLAGS" arguments

if [[ -n "$INPUT_TARGET" ]]; then
    arguments+=("$INPUT_TARGET")
fi

if [[ -n "$INPUT_ARGUMENTS" ]]; then
    arguments+=(--)
    append_lines "$INPUT_ARGUMENTS" arguments
fi

cache_root="$RUNNER_TEMP/coalaura-build"
home="$cache_root/home"
go_cache="$cache_root/go-build"
go_mod_cache="$cache_root/go-mod"

mkdir -p \
    "$home" \
    "$go_cache" \
    "$go_mod_cache"

if [[ -n "${INPUT_PRE//[[:space:]]/}" ]]; then
    pre_hash="$(
        printf '%s\n%s' "$base_image" "$INPUT_PRE" |
            sha256sum |
            cut -c1-16
    )"

    pre_context="$cache_root/pre-$pre_hash"
    image="coalaura-builder-pre:$pre_hash"

    mkdir -p "$pre_context"

    printf '%s\n' "$INPUT_PRE" > "$pre_context/pre.sh"

    cat > "$pre_context/Dockerfile" <<'EOF'
ARG BASE_IMAGE

FROM ${BASE_IMAGE}

COPY pre.sh /tmp/coalaura-pre.sh

RUN bash -e /tmp/coalaura-pre.sh \
 && rm /tmp/coalaura-pre.sh
EOF

    docker build \
        --build-arg "BASE_IMAGE=$base_image" \
        --tag "$image" \
        "$pre_context"
fi

docker_arguments=(
    --rm
    --user "$(id -u):$(id -g)"
    --env HOME=/tmp/coalaura-home
    --env GOCACHE=/tmp/coalaura-go-build
    --env GOMODCACHE=/tmp/coalaura-go-mod
    --volume "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE"
    --volume "$home:/tmp/coalaura-home"
    --volume "$go_cache:/tmp/coalaura-go-build"
    --volume "$go_mod_cache:/tmp/coalaura-go-mod"
    --workdir "$GITHUB_WORKSPACE"
)

declare -A forwarded_host_mappings=()

use_host_network=false

forwarded_environment=(
    # External Go build cache.
    BUILD_CACHE_URL

    # Go module fetching / verification.
    GOPROXY
    GONOPROXY
    GONOSUMDB
    GOPRIVATE
    GOSUMDB
    GOINSECURE
    GOVCS

    # Builder explicitly supports inheriting this.
    GOEXPERIMENT

    # Generic network proxies.
    HTTP_PROXY
    HTTPS_PROXY
    NO_PROXY
    ALL_PROXY
    FTP_PROXY

    http_proxy
    https_proxy
    no_proxy
    all_proxy
    ftp_proxy
)

for name in "${forwarded_environment[@]}"; do
    forward_environment_variable "$name"
done

if [[ "$USE_EXTERNAL_GO_CACHE" == "true" ]]; then
    cache_program="${GOCACHEPROG%%[[:space:]]*}"
    cache_program_arguments="${GOCACHEPROG#"$cache_program"}"

    if [[ "$cache_program" == /* ]]; then
        cache_program_path="$cache_program"
    else
        cache_program_path="$(command -v "$cache_program" || true)"
    fi

    if [[ -z "$cache_program_path" || ! -x "$cache_program_path" ]]; then
        error "GOCACHEPROG executable is not available on the runner: $cache_program"
    fi

    cache_program_container=/tmp/coalaura-gocacheprog

    docker_arguments+=(
        --volume "$cache_program_path:$cache_program_container:ro"
        --env "GOCACHEPROG=$cache_program_container$cache_program_arguments"
    )
fi

if [[ "$use_host_network" == "true" ]]; then
    docker_arguments+=(--network host)
fi

docker run \
    "${docker_arguments[@]}" \
    "$image" \
    "${arguments[@]}"

echo "image=$image" >> "$GITHUB_OUTPUT"

if [[ -n "$output" && "$INPUT_DEBUG" != "true" ]]; then
    echo "path=$output" >> "$GITHUB_OUTPUT"
    echo "filename=$(basename "$output")" >> "$GITHUB_OUTPUT"
fi
