# Tab completion with colors
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
command mkdir -p -- "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors)"
    zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}
fi

# Color for manpages in less
export PAGER=less
export LESS=-R
export LESS_TERMCAP_mb=$'\E[01;31m'
export LESS_TERMCAP_md=$'\E[01;31m'
export LESS_TERMCAP_me=$'\E[0m'
export LESS_TERMCAP_se=$'\E[0m'
export LESS_TERMCAP_so=$'\E[01;44;33m'
export LESS_TERMCAP_ue=$'\E[0m'
export LESS_TERMCAP_us=$'\E[01;32m'

# Fuzzy
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS='--layout=reverse --inline-info'

export FZF_CTRL_T_OPTS="
  --preview 'bat -n --color=always {}'
  --bind 'ctrl-/:change-preview-window(down|hidden|)'"

export FZF_ALT_C_OPTS="
  --preview 'tree -C {}'"

export FZF_CTRL_R_OPTS="
  --preview 'printf %s\\n {4..}'
  --preview-window down:3:wrap
  --bind 'ctrl-/:toggle-preview'"

# PATH: user tools first; skip missing dirs; drop duplicates
typeset -U path
path=(
    /usr/local/go/bin
    "${HOME}/.cargo/bin"
    "${HOME}/go/bin"
    "${HOME}/.local/bin"
    $path
)
path=( ${^path}(N-/) )
rehash

export EDITOR=vim
export VISUAL="$EDITOR"

zmodload zsh/datetime

_voidling_prompt_pad=5
typeset -g _voidling_cmd_start

# Blank line after command output
_voidling_prompt_blank() {
    printf '\n'
}

# Keep the two-line prompt off the bottom edge on tall terminals only.
# Short or resized terminals skip the spacer so \e[nA cannot wrap and glitch.
_voidling_prompt_spacer() {
    emulate -L zsh
    local pad=${_voidling_prompt_pad}
    (( LINES >= pad + 8 )) || return 0
    printf '\n%.0s' {1..$pad}
    printf '\033[%dA' $((pad + 1))
}

_voidling_fmt_cmd_duration() {
    emulate -L zsh
    local -F elapsed=$1
    local -i total_ms

    total_ms=$(( elapsed * 1000 + 0.5 ))
    (( total_ms < 0 )) && total_ms=0
    printf '%d.%03ds' $(( total_ms / 1000 )) $(( total_ms % 1000 ))
}

_voidling_prompt_timer_preexec() {
    _voidling_cmd_start=$EPOCHREALTIME
}

# Path on line 1; last-command wall time flush right. Empty Enter hides it.
_voidling_prompt_set() {
    emulate -L zsh
    local elapsed_str path_disp
    local -i pad vis cols
    local -F elapsed

    cols=${COLUMNS:-80}
    if [[ -n $_voidling_cmd_start ]]; then
        elapsed=$(( EPOCHREALTIME - _voidling_cmd_start ))
        elapsed_str=$(_voidling_fmt_cmd_duration $elapsed)
        unset _voidling_cmd_start
    fi

    if [[ -n $elapsed_str ]]; then
        path_disp=${(%):-%~}
        vis=$(( 1 + ${#path_disp} + ${#elapsed_str} ))
        pad=$(( cols - vis ))
        (( pad < 1 )) && pad=1
        PS1=$'\n %F{cyan}%~%f'"${(l:pad:: :)}%F{white}${elapsed_str}%f"$'\n %F{white}%?  '
    else
        PS1=$'\n %F{cyan}%~%f\n %F{white}%?  '
    fi
}

PS1="
 %F{cyan}%~%f
 %F{white}%?  "

RPROMPT=

set-title() {
    printf '\033]0;%s\007' "$*"
}

_voidling_title_preexec() {
    set-title "${1%%$'\n'}"
}

_voidling_title_precmd() {
    set-title "${PWD/#$HOME/~}"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _voidling_prompt_blank
add-zsh-hook precmd _voidling_prompt_spacer
add-zsh-hook precmd _voidling_prompt_set
add-zsh-hook precmd _voidling_title_precmd
add-zsh-hook preexec _voidling_title_preexec
add-zsh-hook preexec _voidling_prompt_timer_preexec

_fzf_compgen_path() {
    fd --type f --hidden --follow --exclude .git -- . "$1"
}

_fzf_compgen_dir() {
    fd --type d --hidden --follow --exclude .git -- . "$1"
}

_fzf_comprun() {
    local command=$1
    shift

    case "$command" in
        cd) fd --type d --hidden --follow --exclude ".git" | fzf --preview 'tree -C {}' "$@" --border --bind 'ctrl-h:preview-up,ctrl-l:preview-down' ;;
        *) fzf "$@" ;;
    esac
}

y() {
    emulate -L zsh
    setopt LOCAL_TRAPS
    local tmp cwd
    tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return 1
    trap 'rm -f -- "$tmp"' EXIT
    yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd <"$tmp" || true
    if [[ -n "$cwd" && "$cwd" != "$PWD" ]]; then
        builtin cd -- "$cwd"
    fi
}

# Print PATH entries; green if the directory exists, red if not.
showpath() {
    emulate -L zsh
    local p
    for p in "${(@s/:/)PATH}"; do
        if [[ -d "$p" ]]; then
            printf '\033[32m%s\033[0m\n' "$p"
        else
            printf '\033[31m%s\033[0m\n' "$p"
        fi
    done
}

# cd up N directories (default 1). exec zsh would drop the new pwd.
up() {
    emulate -L zsh
    setopt EXTENDED_GLOB
    local n=${1:-1} dest=$PWD i
    if (( $# > 1 )) || [[ -n $1 && $1 != <-> ]]; then
        printf 'Usage: up [N]\n' >&2
        return 2
    fi
    for (( i = 0; i < n; i++ )); do
        dest=${dest:h}
    done
    builtin cd -- "$dest"
}

# cd to DIR (HOME if omitted), then list it.
# DIR may be a path, -, +N/-N (same as cd), or a dirs -v index.
cl() {
    emulate -L zsh
    setopt EXTENDED_GLOB
    local dest
    if (( $# > 1 )); then
        printf 'Usage: cl [DIR]\n' >&2
        return 2
    fi
    if (( $# == 0 )); then
        builtin cd -- "$HOME" || return
    elif [[ $1 == - || $1 == [+-]<-> ]]; then
        builtin cd "$1" || return
    elif [[ $1 == (\~|)<-> ]]; then
        dest=${1#\~}
        if (( dest == 0 )); then
            dest=$PWD
        else
            dest=${dirstack[dest]}
        fi
        if [[ -z $dest ]]; then
            printf 'cl: %s: directory stack index out of range\n' "$1" >&2
            return 1
        fi
        builtin cd -- "$dest" || return
    else
        builtin cd -- "$1" || return
    fi
    ls --color=auto -A --group-directories-first
}

# Pick files with fd+fzf (bat preview) and open in $EDITOR.
fe() {
    emulate -L zsh
    local editor selected
    local -a files
    editor=${VISUAL:-${EDITOR:-vim}}
    if ! command -v fd >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1; then
        printf 'fe: fd and fzf are required\n' >&2
        return 1
    fi
    selected=$(
        command fd --type f --hidden --follow --exclude .git |
            command fzf --multi --preview 'bat -n --color=always -- {}'
    ) || return
    [[ -n $selected ]] || return 1
    files=( ${(f)selected} )
    command "$editor" -- "${files[@]}"
}

# Copy FILE to FILE.YYYYMMDD-HHMMSS (files or directories).
bak() {
    emulate -L zsh
    local src dest stamp
    if (( $# != 1 )); then
        printf 'Usage: bak FILE\n' >&2
        return 2
    fi
    src=$1
    if [[ ! -e $src ]]; then
        printf 'bak: %s: No such file or directory\n' "$src" >&2
        return 1
    fi
    stamp=$(command date +%Y%m%d-%H%M%S) || return 1
    dest=${src}.${stamp}
    if [[ -e $dest ]]; then
        printf 'bak: %s already exists\n' "$dest" >&2
        return 1
    fi
    command cp -a -- "$src" "$dest" || return 1
    printf '%s\n' "$dest"
}

_voidling_zshrc_help_usage() {
    printf '%s\n' \
        'Usage: ? [OPTION]...' \
        'Display a manual page for this zsh configuration.' \
        '' \
        'Mandatory arguments to long options are mandatory for short options too.' \
        '' \
        '  -h, --help            display this help and exit'
}

# ? is a glob; the alias is expanded before filename generation.
_voidling_zshrc_help() {
    emulate -L zsh
    local rc page arg
    for arg in "$@"; do
        case $arg in
            -h | --help)
                _voidling_zshrc_help_usage
                return 0
                ;;
            --)
                break
                ;;
            -*)
                printf '?: unrecognized option %s\n' "$arg" >&2
                printf "Try '? --help' for more information.\n" >&2
                return 2
                ;;
            *)
                printf '?: extra operand %s\n' "$arg" >&2
                printf "Try '? --help' for more information.\n" >&2
                return 2
                ;;
        esac
    done
    rc=${ZDOTDIR:-$HOME}/.zshrc
    rc=${rc:A}
    page=${rc:h}/zshrc.1
    if [[ ! -f $page ]]; then
        printf '?: %s: No such file or directory\n' "$page" >&2
        return 1
    fi
    if command -v man >/dev/null 2>&1; then
        command man -l -- "$page"
        return $?
    fi
    if command -v mandoc >/dev/null 2>&1; then
        command mandoc -a -- "$page"
        return $?
    fi
    printf '?: man is required to display %s\n' "$page" >&2
    return 1
}

alias '?'='_voidling_zshrc_help'

alias d='dirs -v'
alias dmesg='dmesg --color=always | less -R'
alias diff='diff --color=auto'
alias grep='grep --color=auto'
alias ip='ip --color=auto'
alias l.='ls -d .* --color=auto --group-directories-first'
alias ll='ls --color=auto -lAthr --group-directories-first'
alias ls='ls --color=auto -A --group-directories-first'

bindkey -e
bindkey "${terminfo[khome]:-$'\e[H'}" beginning-of-line
bindkey "${terminfo[kend]:-$'\e[F'}" end-of-line
bindkey "${terminfo[kdch1]:-$'\e[3~'}" delete-char
bindkey "${terminfo[kcbt]:-$'\e[Z'}" reverse-menu-complete

autoload -Uz edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line

# Ctrl-W / Alt-B / Alt-F stop at slashes instead of eating a whole path.
WORDCHARS=${WORDCHARS//\/}

setopt BEEP EXTENDED_GLOB NOMATCH INTERACTIVE_COMMENTS
setopt AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT
unsetopt AUTO_CD
DIRSTACKSIZE=16
REPORTTIME=5

# History
_voidling_hist_dir="${XDG_STATE_HOME:-$HOME/.local/state}/zsh"
command mkdir -p -- "${_voidling_hist_dir}"
HISTFILE="${_voidling_hist_dir}/history"
if [[ -f ${HOME}/.histfile && ! -e $HISTFILE ]]; then
    command mv -- "${HOME}/.histfile" "$HISTFILE"
fi
unset _voidling_hist_dir
HISTSIZE=10000
SAVEHIST=$HISTSIZE
setopt SHARE_HISTORY
setopt HIST_FCNTL_LOCK
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# Do not save unknown command names (typos that become "not found").
_voidling_hist_skip_unknown() {
    emulate -L zsh
    setopt EXTENDED_GLOB
    local -a words
    local cmd
    words=( ${(z)1} )
    cmd=${words[1]}
    while [[ -n $cmd && $cmd == [A-Za-z_][A-Za-z0-9_]#=* ]]; do
        shift words
        cmd=${words[1]}
    done
    while [[ $cmd == (command|builtin|noglob|nocorrect|exec|time) ]]; do
        shift words
        cmd=${words[1]}
        while [[ $cmd == -* ]]; do
            shift words
            cmd=${words[1]}
        done
    done
    [[ -z $cmd ]] && return 0
    whence -- "$cmd" >| /dev/null || return 1
}

add-zsh-hook zshaddhistory _voidling_hist_skip_unknown

# Tmux setting for remote servers
# if [ -z "$TMUX" ]; then
#     tmux attach -t devbox || tmux new -s devbox
# fi

_voidling_source() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] && source "$f"
    done
}

# Create ~/.zsh if needed, then clone any missing plugin into it.
# A failed clone must not abort startup; _voidling_source skips absent files.
_voidling_ensure_zsh_plugins() {
    emulate -L zsh
    local dir dest url
    dir="${HOME}/.zsh"

    if [[ ! -d $dir ]]; then
        printf 'Creating %s\n' "$dir" >&2
        command mkdir -p -- "$dir" || return 1
    fi

    for dest url in \
        "${dir}/fzf-dir-navigator" "https://github.com/KulkarniKaustubh/fzf-dir-navigator.git" \
        "${dir}/zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions.git" \
        "${dir}/zsh-history-substring-search" "https://github.com/zsh-users/zsh-history-substring-search.git" \
        "${dir}/zsh-rtfm" "https://github.com/hoolies/RTFM.git" \
        "${dir}/zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
    do
        [[ -d $dest ]] && continue
        if ! command -v git >/dev/null 2>&1; then
            printf 'zsh: git not found; cannot install %s\n' "${dest:t}" >&2
            return 1
        fi
        printf 'Installing %s\n' "${dest:t}" >&2
        if ! command git clone --depth 1 -- "$url" "$dest"; then
            printf 'zsh: failed to clone %s\n' "$url" >&2
        fi
    done
    return 0
}

_voidling_update_zsh_plugins() {
    emulate -L zsh
    local dest
    for dest in "${HOME}/.zsh"/*(N/); do
        [[ -d $dest/.git ]] || continue
        printf 'Updating %s\n' "${dest:t}" >&2
        if ! command git -C "$dest" fetch --depth 1 origin ||
            ! command git -C "$dest" merge --ff-only FETCH_HEAD; then
            printf 'zsh: failed to update %s\n' "${dest:t}" >&2
        fi
    done
}

# After plugins can add to fpath. Rebuild the dump at most once a day;
# skip the insecure-directory check as root (same reason as the fzf workaround).
_voidling_compinit() {
    emulate -L zsh
    setopt EXTENDED_GLOB
    autoload -Uz compinit
    local dump=${ZDOTDIR:-$HOME}/.zcompdump
    local -a flags
    (( EUID == 0 )) && flags=(-u)
    if [[ ! -s $dump || -n $dump(#qN.mh+24) ]]; then
        compinit "${flags[@]}" -d "$dump"
    else
        compinit "${flags[@]}" -C -d "$dump"
    fi
}

_voidling_ensure_zsh_plugins

# Do not wrap widgets at source time; we rebind after later zle -N (fzf, magic).
ZSH_AUTOSUGGEST_MANUAL_REBIND=1

_voidling_source \
    "${HOME}/.zsh/fzf-dir-navigator/fzf-dir-navigator.zsh" \
    "${HOME}/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "${HOME}/.zsh/zsh-history-substring-search/zsh-history-substring-search.zsh" \
    "${HOME}/.zsh/zsh-rtfm/rtfm.plugin.zsh"

_voidling_compinit

if command -v fzf >/dev/null 2>&1; then
    # fzf's "emulate zsh" tries to unset PRIVILEGED and errors in a root shell.
    source <(fzf --zsh | sed -e "s/'builtin' 'emulate' 'zsh' \&\& //")
fi

# fzf's Ctrl-R list has no dates; relist with EXTENDED_HISTORY timestamps
# and insert only the command (not the histno/date prefix).
if (( $+widgets[fzf-history-widget] )); then
    fzf-history-widget() {
        emulate -L zsh
        setopt EXTENDED_GLOB
        local selected
        selected=$(
            fc -t '%F %T' -rl 1 |
                awk '{
                    cmd = $0
                    sub(/^[[:space:]]*[0-9]+\*?[[:space:]]+[0-9-]+[[:space:]]+[0-9:]+[[:space:]]+/, "", cmd)
                    if (!seen[cmd]++) print
                }' |
                FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS-} ${FZF_CTRL_R_OPTS-}" fzf --scheme=history --no-sort --query="$LBUFFER"
        ) || return
        if [[ $selected == (#b)[[:space:]]#[0-9]##[[:space:]]##[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][[:space:]]##[0-9][0-9]:[0-9][0-9]:[0-9][0-9][[:space:]]##(*) ]]; then
            LBUFFER=$match[1]
        else
            LBUFFER=${selected##[[:space:]]#[0-9]##[[:space:]]##}
        fi
        zle reset-prompt
    }
    zle -N fzf-history-widget
fi

# fzf --zsh rebinds Tab to fzf-completion; take it back for RTFM.
if (( $+functions[fzf_rtfm_rebind_tab] )); then
    fzf_rtfm_rebind_tab
fi

if (( $+widgets[autosuggest-accept] )); then
    bindkey '^ ' autosuggest-accept
fi

if (( $+widgets[history-substring-search-up] )); then
    bindkey "${terminfo[kcuu1]:-$'\e[A'}" history-substring-search-up
    bindkey "${terminfo[kcud1]:-$'\e[B'}" history-substring-search-down
    bindkey '^P' history-substring-search-up
    bindkey '^N' history-substring-search-down
fi

# Quote URL metacharacters as you type/paste; keep multi-line paste off the
# command line until Enter. Highlighting must wrap these, so load it after.
autoload -Uz url-quote-magic bracketed-paste-magic
zle -N self-insert url-quote-magic
zle -N bracketed-paste bracketed-paste-magic

if (( $+functions[_zsh_autosuggest_bind_widgets] )); then
    _zsh_autosuggest_bind_widgets
fi

# Syntax highlighting must be last so it wraps widgets from fzf / RTFM.
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)
_voidling_source "${HOME}/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
