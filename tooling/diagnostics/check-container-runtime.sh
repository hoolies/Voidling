#!/usr/bin/env bash
# Print how podman / docker resolve on this host (alias and wrapper confusion).
set -euo pipefail

unalias -a 2>/dev/null || true
unset -f printf command ls file sha256sum ldd podman docker 2>/dev/null || true

readonly PROGNAME="${0##*/}"
export LC_ALL=C

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]...
Show how podman and docker resolve in PATH, with versions and binary details.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
EOF
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || usage_error "extra operand $1"
                ;;
            -*)
                usage_error "unrecognized option $1"
                ;;
            *)
                usage_error "extra operand $1"
                ;;
        esac
    done
}

hr() {
    printf '\n%s\n' "------------------------------------------------------------"
}

run_cmd() {
    printf '\n$ %s\n' "$*"
    "$@" || true
}

describe_binary() {
    local path="$1"
    run_cmd ls -la -- "$path"
    if command -v file >/dev/null 2>&1; then
        run_cmd file -- "$path"
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        run_cmd sha256sum -- "$path"
    fi
    if command -v ldd >/dev/null 2>&1; then
        run_cmd ldd -- "$path"
    fi
}

report_runtime() {
    local name="$1" path
    hr
    printf '%s resolution:\n' "$name"
    if command -v "$name" >/dev/null 2>&1; then
        path="$(command -v "$name")"
        printf 'command -v %s -> %s\n' "$name" "$path"
        describe_binary "$path"
        run_cmd "$name" --version
    else
        printf '%s: not found in PATH\n' "$name"
    fi
    if [[ -x "/usr/bin/$name" && "$(command -v "$name" 2>/dev/null || true)" != "/usr/bin/$name" ]]; then
        hr
        printf '/usr/bin/%s differs from the PATH resolution:\n' "$name"
        describe_binary "/usr/bin/$name"
        run_cmd "/usr/bin/$name" --version
    fi
}

main() {
    parse_args "$@"
    printf '%s\n' "Voidling diagnostics: container runtimes"
    hr
    printf 'PATH:\n%s\n' "$PATH"
    report_runtime podman
    report_runtime docker
    hr
    printf '%s\n' "Done."
}

main "$@"
