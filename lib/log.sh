#!/usr/bin/env bash
command-exists() {
  command -v "$@" >/dev/null 2>&1
}

declare -A ANSI # for echo and stuff (ansi sequences)
ANSI=(
  ["bold"]=$'\e[1m'
  ["bolt"]=$'\e[1m'
  ["italic"]=$'\e[3m'
  ["blink"]=$'\e[5m'
  ["underline"]=$'\e[4m'
  ["undercurl"]=$'\e[4m'
  ["strike"]=$'\e[9m'
  ["invert"]=$'\e[7m'
  ["nc"]=$'\e[0m'
  ["reset"]=$'\e[0m'
  ["black"]=$'\e[30m'
  ["red"]=$'\e[31m'
  ["green"]=$'\e[32m'
  ["yellow"]=$'\e[33m'
  ["blue"]=$'\e[34m'
  ["magenta"]=$'\e[35m'
  ["cyan"]=$'\e[36m'
  ["white"]=$'\e[37m'
)

log() {
  local urgency=$1
  shift
  local msg=("$@")

  local color=""
  case "$urgency" in
  info)
    color="${ANSI[cyan]}INFO${ANSI[nc]}"
    ;;
  error)
    color="${ANSI[red]}ERROR${ANSI[nc]}"
    ;;
  warn | warning)
    color="${ANSI[yellow]}WARN${ANSI[nc]}"
    ;;
  *)
    color="${ANSI[bold]}${urgency^^}${ANSI[nc]}"
    ;;
  esac

  echo "${color} ${msg[*]}${ANSI[nc]}"
}

check-deps() {
  local deps=() needs=()

  deps=(
    "yt-dlp"
    "python"
    "sqlite3"
    # "mutagen"
  )

  for cmd in "${deps[@]}"; do
    if ! command-exists $cmd; then
      needs+=("$cmd")
    fi
  done

  ((${#needs[@]} <= 0)) || {
    log error "Packages needed: ${needs[*]}"
    exit 1
  }
  log info "All checks passed!"
}
check-deps
