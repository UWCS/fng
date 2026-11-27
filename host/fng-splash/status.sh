status() {
    [[ -n "${FNG_SPLASH_STATUS:-}" ]] || return 0
    local tmp
    tmp=$(mktemp "${FNG_SPLASH_STATUS}.XXXXXX") || return 0
    if printf '[splash]\nstate=%s\nmessage=%s\ndetail=%s\nprogress=%s\n' "$1" "$2" "${3:-}" "${4:--1}" > "$tmp"; then
        mv -f -- "$tmp" "$FNG_SPLASH_STATUS" || rm -f -- "$tmp"
    else
        rm -f -- "$tmp"
    fi
    return 0
}
