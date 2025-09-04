#!/usr/bin/env bash

check-dirs() {
  local dirs=(
    "archives"
    "db"
    "downloads"
    "music"
  )

  for d in "${dirs[@]}"; do
    if [[ ! -e "${d}" ]]; then
      mkdir -p "${d}"
    fi
  done
}

# check and create directories
check-dirs
[[ ! -f ./db/music_imports.db ]] && touch ./db/music_imports.db # create database file

echo "Setup is done, created ${dirs[*]} and ./db/music_imports.db"
echo "You can now run ynkr with 'docker compose up -d'"
