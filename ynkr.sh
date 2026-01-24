#!/usr/bin/env bash
cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..

. lib/env

. lib/log.sh
. lib/ynkr.sh
. lib/db.sh
. lib/musicbrainz.sh

prepare() {
  ynkr:parse-playlist-file            # parses the playlist file and gets the variables right
  ynkr:get-playlist-ids YNKR_PLAYLIST # replaces the urls with the actual playlist ids

  local name

  db:init
  for name in "${!YNKR_PLAYLIST[@]}"; do
    local id=${YNKR_PLAYLIST[$name]}
    [[ -n "$name" && -n "$id" ]] || continue
    db:add-playlist "$name" "$id" # add playlist to the database

    local INFO
    INFO=$(ynkr:get-playlist-info "$id")

    local songs=() ids=() line
    while read -r line; do
      ids+=("$line")
    done <<<"$(ynkr:get-song-ids "$INFO")"

    while read -r line; do
      songs+=("$line")
    done <<<"$(ynkr:get-song-titles "$INFO")"

    local len=${#songs[@]}
    for ((j = 0; j < len; j++)); do
      local name=${songs[j]}
      db:add-song "${name}" "${ids[j]}" "$(printf "%s\n" "$INFO" | jq -r '.id')"
      db:tag-song "${ids[j]}" "pending"
    done
  done
}
download() {
  local songs=()
  songs=($(db:get-pending))

  for id in "${songs[@]}"; do
    local name
    name="$(db:get-song-name "$id")"
    log info "${ANSI[red]}download${ANSI[nc]} - ${name}:${id}"

    if ynkr:song "$id"; then
      log info "${ANSI[green]}Downloaded: $name - $id"
      db:mark-download "$id"
    else
      log warn "${ANSI[yellow]}Failed: $name - $id"
      db:mark-failed "$id"
    fi
  done
}

main() {
  while true; do
    prepare
    if $DEBUG; then
      db:show
      db:show playlists
      db:show songs
    fi

    download
    if $DEBUG; then
      db:show
      db:show playlists
      db:show songs
    fi

    log info "${ANSI[yellow]}YNKR - Done"
    log warn "${ANSI[yellow]}Sleeping for the next ${ANSI[red]}$SLEEP${ANSI[yellow]} seconds"

    sleep $SLEEP
  done
}

main

# Trap signals for graceful shutdown
trap 'log info "Shutting down..."; exit 0' SIGTERM SIGINT
