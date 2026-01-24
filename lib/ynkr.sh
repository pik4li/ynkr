#!/usr/bin/env bash
. /app/lib/db.sh

ynkr:parse-playlist-file() {
  local file="/app/playlists"
  local count=0
  [[ -n "$file" && -f "$file" ]] || {
    log error "$file - was not found!"
    exit 1
  }

  # IFS="="
  while read -r url; do
    ((count++))
    url=${url% }
    url=${url# }
    name=$(ynkr:get-playlist-info "$url" | jq -r '.title')
    [[ -n "$name" ]] || name="unknown"

    YNKR_PLAYLISTS[$name]+=":$url:"
    log info "${ANSI[magenta]}ynkr:parse-playlist-file:${ANSI[nc]} name=${ANSI[cyan]}$name${ANSI[nc]}; url=${ANSI[green]}${ANSI[nc]}"
  done <"$file"
}

# parses the id from the playlist url
ynkr:get-playlist-ids() {
  local -n PLAYLIST=$1 # Assosiative array (YNKR_PLAYLISTS)
  local idx

  for idx in "${!PLAYLIST[@]}"; do
    local id
    local target="${PLAYLIST[$idx]}"

    if [[ "$target" =~ (\?list=.*\&) ]]; then
      id=${BASH_REMATCH[0]%&}
      id=${id#\?list=}
    fi

    # overwrite the url with the id in the array
    PLAYLIST[$idx]=$id
  done
}

ynkr:get-playlist-info() {
  local PID=$1 # playlist id
  local yt_args=() ytcmd
  yt_args=(
    "--flat-playlist"
    "--dump-single-json"
    "--no-warnings"
    "$PID"
  )
  ytcmd="yt-dlp"

  $ytcmd "${yt_args[@]}"
}

ynkr:get-song-titles() {
  local info=$1
  printf "%s" "$info" | jq -r '.entries[].title'
}

ynkr:get-song-ids() {
  local info=$1
  printf "%s" "$info" | jq -r '.entries[].id'
}

ynkr:song() {
  # download song and get sanitized names and artists..
  local yid=$1
  local name=$2

  [[ -n "$yid" ]] || return 1
  local url="https://youtube.com/watch?v=$yid"

  log info "${ANSI[red]}:YT-DLP:${ANSI[nc]}${ANSI[bold]} Downloading: ${ANSI[cyan]}$name${ANSI[nc]} - ${ANSI[magenta]}$yid${ANSI[nc]}"

  local cmd="yt-dlp"
  local args=()
  args=(
    "--extract-audio"
    "--paths=$DOWNLOADS/"
    "--output=$yid"
    "--download-archive=$YT_ARCHIVE.yt"
    "--embed-thumbnail"
    "--embed-metadata"
    "--audio-quality=0"
    "--concurrent-fragments=3"
    "--retries=5"
    "--progress" "--newline"
    "--color"
    "$url"
  )

  $cmd "${args[@]}"
}

ynkr:meta() {
  while true; do
    local files=()
    mapfile files < <(ls "$DOWNLOADS/")
    ((${#files} > 0)) || continue
    log info "Found files to process: ${files[*]}"

    for ((s = 5; s > 0; s--)); do
      sleep 1
      log info "$s.." 1>&2
    done
    log info "0.." 1>&2
  done
}
