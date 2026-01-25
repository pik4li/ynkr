#!/usr/bin/env bash
# MusicBrainz integration for enriching downloaded music files

# ---------- configuration ----------
declare -r AID_KEY="k4hQD6v7FA0"
declare -r AID_URL="https://api.acoustid.org/v2/lookup?client=${AID_KEY}&meta=recordings"
declare -r AID_CACHE="/app/db/.cache"
declare -r LOG_AID="${ANSI[red]}[ACOUSTIC-ID]${ANSI[nc]}"

[[ -d "$AID_CACHE" ]] || mkdir -p "$AID_CACHE"

aid:make-fingerprint() {
  local file=$1
  [[ -e "$file" ]] || {
    log error "$LOG_AID File to create hash for does not exist! :${ANSI[magenta]}$file"
    return
  }

  local f="$(basename $file)"
  local original=${f%.*}
  local dest=${AID_CACHE}/${original}.fp

  if [[ -e "$dest" ]]; then
    log error "$LOG_AID Cachefile already exists! :${ANSI[magenta]}${dest}"
    return
  fi

  fpcalc -json "$file" >"$dest"
  [[ -e "$dest" ]] || return 1
}

aid:ask-aid() {
  local file=$1

  [[ -e "$file" ]] || {
    log error "$LOG_AID Failed to ask aid about file that doesn't exist! :${ANSI[magenta]}$file"
    return 1
  }

  local dur fp
  dur=$(jq -r '.duration' <<<"$file")
  fp=$(jq -r '.fingerprint' <<<"$file")
  local final="${AID_URL}&fingerprint=$fp&duration=$dur"

  local info
  info=$(curl -s "$final")

  [[ -n "$info" ]] || {
    log error "$LOG_AID No output: ${final@Q}"
    return 1
  }

  printf "%s" "$info"

  # local bare=.85
  #
  # local score title pre artists
  # pre=""
  # score=$(jq -r ".results[0].score" <<<"$info")
  # title=$(jq -r ".results[0].recordings[0].title" <<<"$info")
  # artists=($(jq -r ".results[0].recordings[0].artists[].name"))
  #
  # ((score > bare)) || {
  #   log error "$LOG_AID Score too low! :${ANSI[magenta]}score=${score}/min=${bare}"
  # }
}
