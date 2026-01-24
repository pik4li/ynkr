#!/usr/bin/env bash
cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..
YNKR_DB_FILE="/app/db/ynkr.db"

declare DOWNLOADS
DOWNLOADS="$PWD/downloads"

DEBUG=true

. lib/log.sh
. lib/ynkr.sh
. lib/db.sh

declare -A YNKR_PLAYLISTS
ynkr:parse-playlist-file             # parses the playlist file and gets the variables right
ynkr:get-playlist-ids YNKR_PLAYLISTS # replaces the urls with the actual playlist ids

prepare() {
  local name

  db:init
  for name in "${!YNKR_PLAYLISTS[@]}"; do
    local id=${YNKR_PLAYLISTS[$name]}
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
      db:add-song "${name}" "${ids[j]}" "$(printf "%s\n" "$INFO" | jq -r '.title')"
      db:tag-song "${ids[j]}" "pending"
    done

    for ((j = 0; j < len; j++)); do
      local id=${ids[j]}
      ynkr:song "$id" "${songs[j]}"
    done
  done
}
prepare

if $DEBUG; then
  db:show
  db:show playlists
  db:show songs
fi

# sanitize-metadata & # sub process for managing sanitization.. Will get addet in the future.
