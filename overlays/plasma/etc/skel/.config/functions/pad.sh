#!/usr/bin/env sh
# pad — center text on the terminal with optional side decorations.

set -eu
export LC_ALL=C
unalias -a 2>/dev/null || true
unset -f tput printf 2>/dev/null || true

readonly PROGNAME="${0##*/}"
readonly DEFAULT_LEFT='------------({['
readonly DEFAULT_RIGHT=']})------------'

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTION]... TEXT [LEFT] [RIGHT]
Center TEXT on the terminal, with optional LEFT and RIGHT decorations.

Mandatory arguments to long options are mandatory for short options too.

  -h, --help            display this help and exit
EOF
}

unrecognized_option() {
    printf '%s: unrecognized option %s\n' "$PROGNAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
}

missing_operand() {
    printf '%s: missing operand\n' "$PROGNAME" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
}

extra_operand() {
    printf '%s: extra operand %s\n' "$PROGNAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
}

terminal_width() {
    width=80
    if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        width=$(tput cols) || width=80
    fi
}

print_padded() {
    center=$1
    left=$2
    right=$3
    terminal_width
    padding=$(((width - ${#center} - ${#left} - ${#right}) / 2))
    if [ "$padding" -lt 0 ]; then
        printf '%s %s %s\n' "$left" "$center" "$right"
    else
        printf '%s%*s%s%*s%s\n' "$left" "$padding" "" "$center" "$padding" "" "$right"
    fi
}

parse_args() {
    center=""
    left=$DEFAULT_LEFT
    right=$DEFAULT_RIGHT
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                unrecognized_option "$1"
                exit 2
                ;;
            *)
                break
                ;;
        esac
    done
    if [ "$#" -lt 1 ]; then
        missing_operand
        exit 2
    fi
    center=$1
    shift
    if [ "$#" -gt 0 ]; then
        left=$1
        shift
    fi
    if [ "$#" -gt 0 ]; then
        right=$1
        shift
    fi
    if [ "$#" -gt 0 ]; then
        extra_operand "$1"
        exit 2
    fi
}

main() {
    parse_args "$@"
    print_padded "$center" "$left" "$right"
}

main "$@"
