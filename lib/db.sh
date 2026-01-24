#!/usr/bin/env bash
# set -euo pipefail
# ---------- core helper ----------
db() {
  sqlite3 -tabs "$DB" "$@"
}

# Escape single quotes for SQL: ' -> ''
_sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}

# ---------- init ----------

db:init() {
  [[ -n "$DB" ]] || exit
  [[ -f "$DB" ]] || touch "$DB"

  log info "${ANSI[yellow]}db:init:${ANSI[nc]} Initializing database"

  sqlite3 "$DB" <<'SQL'
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS playlists (
  id INTEGER PRIMARY KEY,
  yt_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS songs (
  id INTEGER PRIMARY KEY,
  yt_id TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlist_songs (
  playlist_id INTEGER NOT NULL,
  song_id INTEGER NOT NULL,
  PRIMARY KEY (playlist_id, song_id),
  FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
  FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS song_tags (
  song_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  PRIMARY KEY (song_id, tag_id),
  FOREIGN KEY (song_id) REFERENCES songs(id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
);
SQL

  # Run migrations
  db:migrate-mb
}

# ---------- migrations ----------

db:migrate-mb() {
  local cols
  cols=$(sqlite3 "$DB" "PRAGMA table_info(songs);" | cut -d'|' -f2)
  [[ "$cols" == *"artist"* ]] || sqlite3 "$DB" "ALTER TABLE songs ADD COLUMN artist TEXT;"
  [[ "$cols" == *"album"* ]] || sqlite3 "$DB" "ALTER TABLE songs ADD COLUMN album TEXT;"
  [[ "$cols" == *"file_path"* ]] || sqlite3 "$DB" "ALTER TABLE songs ADD COLUMN file_path TEXT;"
}

# ---------- playlists ----------

db:add-playlist() {
  local name="$1" yt_id="$2"
  local name_esc yt_id_esc
  name_esc=$(_sql_escape "$name")
  yt_id_esc=$(_sql_escape "$yt_id")
  log info "${ANSI[yellow]}db:add-playlist:${ANSI[nc]} name=${ANSI[cyan]}${name@Q}${ANSI[nc]} | id=${ANSI[magenta]}${yt_id@Q}${ANSI[nc]}"

  sqlite3 "$DB" <<SQL
INSERT INTO playlists (name, yt_id)
VALUES ('$name_esc', '$yt_id_esc')
ON CONFLICT(yt_id) DO UPDATE SET name=excluded.name;
SQL
}

# ---------- songs ----------

db:add-song() {
  local name="$1" yt_id="$2" playlist="${3:-}"
  local name_esc yt_id_esc playlist_esc
  name_esc=$(_sql_escape "$name")
  yt_id_esc=$(_sql_escape "$yt_id")
  log info "${ANSI[yellow]}db:add-song:${ANSI[nc]} name=${ANSI[cyan]}${name@Q}${ANSI[nc]} | ytid=${ANSI[magenta]}${yt_id@Q}${ANSI[nc]}"

  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO songs (name, yt_id)
VALUES ('$name_esc', '$yt_id_esc');
SQL

  if [[ -n "$playlist" ]]; then
    playlist_esc=$(_sql_escape "$playlist")
    log info "${ANSI[yellow]}db:add-song:${ANSI[nc]} playlist=${ANSI[green]}${playlist@Q}"

    sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO playlist_songs (playlist_id, song_id)
SELECT p.id, s.id
FROM playlists p, songs s
WHERE p.yt_id='$playlist_esc'
  AND s.yt_id='$yt_id_esc';
SQL
  fi
}

# ---------- tags ----------

db:tag-song() {
  local song_id="$1" tag="$2"
  local song_id_esc tag_esc
  song_id_esc=$(_sql_escape "$song_id")
  tag_esc=$(_sql_escape "$tag")

  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO tags (name) VALUES ('$tag_esc');

INSERT OR IGNORE INTO song_tags (song_id, tag_id)
SELECT s.id, t.id
FROM songs s, tags t
WHERE s.yt_id='$song_id_esc'
  AND t.name='$tag_esc';
SQL
}

# ---------- queries ----------

db:get-song-ids() {
  local playlist="$1"
  local playlist_esc
  playlist_esc=$(_sql_escape "$playlist")

  db "
SELECT s.yt_id
FROM playlists p
JOIN playlist_songs ps ON ps.playlist_id=p.id
JOIN songs s ON s.id=ps.song_id
WHERE p.yt_id='$playlist_esc';
"
}

db:get-song-tag() {
  local song_id="$1"

  db "
SELECT t.name
FROM songs s
JOIN song_tags st ON st.song_id=s.id
JOIN tags t ON t.id=st.tag_id
WHERE s.yt_id='$song_id';
"
}

db:get-song-name() {
  local song_id="$1"
  db "SELECT name FROM songs WHERE yt_id='$song_id';"
}

db:get-song-id() {
  local name="$1"
  local name_esc
  name_esc=$(_sql_escape "$name")
  db "SELECT yt_id FROM songs WHERE name='$name_esc';"
}

db:update-song-name() {
  local id="$1" newname="$2"
  local newname_esc
  newname_esc=$(_sql_escape "$newname")
  log info "db:update-song-name: id=$id | name=$newname"

  sqlite3 "$DB" <<SQL
UPDATE songs SET name='$newname_esc' WHERE yt_id='$id';
SQL
}

db:update-song-metadata() {
  local yt_id="$1" artist="$2" album="$3" path="$4"
  local yt_id_esc artist_esc album_esc path_esc
  yt_id_esc=$(_sql_escape "$yt_id")
  artist_esc=$(_sql_escape "$artist")
  album_esc=$(_sql_escape "$album")
  path_esc=$(_sql_escape "$path")
  log info "db:update-song-metadata: id=$yt_id | artist=$artist | album=$album"

  sqlite3 "$DB" <<SQL
UPDATE songs SET artist='$artist_esc', album='$album_esc', file_path='$path_esc'
WHERE yt_id='$yt_id_esc';
SQL
}

db:get-pending() {
  db "
  SELECT s.yt_id
  FROM songs s
  JOIN song_tags st ON st.song_id = s.id
  JOIN tags t ON t.id = st.tag_id
  WHERE t.name = 'pending';
  "
}

db:mark-downloaded() {
  local yt_id="$1"
  local yt_id_esc
  yt_id_esc=$(_sql_escape "$yt_id")

  sqlite3 "$DB" <<SQL
  DELETE FROM song_tags
  WHERE song_id = (SELECT id FROM songs WHERE yt_id = '$yt_id_esc')
    AND tag_id = (SELECT id FROM tags WHERE name = 'pending');

  INSERT OR IGNORE INTO tags (name) VALUES ('downloaded');
  INSERT OR IGNORE INTO song_tags (song_id, tag_id)
  SELECT s.id, t.id FROM songs s, tags t
  WHERE s.yt_id = '$yt_id_esc' AND t.name = 'downloaded';
SQL
}

db:mark-failed() {
  local yt_id="$1"
  local yt_id_esc
  yt_id_esc=$(_sql_escape "$yt_id")

  sqlite3 "$DB" <<SQL
  DELETE FROM song_tags
  WHERE song_id = (SELECT id FROM songs WHERE yt_id = '$yt_id_esc')
    AND tag_id = (SELECT id FROM tags WHERE name = 'pending');

  INSERT OR IGNORE INTO tags (name) VALUES ('failed');
  INSERT OR IGNORE INTO song_tags (song_id, tag_id)
  SELECT s.id, t.id FROM songs s, tags t
  WHERE s.yt_id = '$yt_id_esc' AND t.name = 'failed';
SQL
}

# ---------- display ----------

db:show() {
  local table="${1:-}"

  if [[ -z "$table" ]]; then
    sqlite3 "$DB" <<'SQL'
.mode column
.headers on
SELECT 'playlists' AS table_name, COUNT(*) AS rows FROM playlists
UNION ALL
SELECT 'songs', COUNT(*) FROM songs
UNION ALL
SELECT 'playlist_songs', COUNT(*) FROM playlist_songs
UNION ALL
SELECT 'tags', COUNT(*) FROM tags
UNION ALL
SELECT 'song_tags', COUNT(*) FROM song_tags;
SQL
    return
  fi

  case "$table" in
  playlists)
    sqlite3 -column -header "$DB" "SELECT id, yt_id, name, created_at FROM playlists;"
    ;;
  songs)
    sqlite3 -column -header "$DB" "SELECT id, yt_id, name, artist, album, file_path FROM songs;"
    ;;
  tags)
    sqlite3 -column -header "$DB" "SELECT id, name FROM tags;"
    ;;
  playlist_songs | ps)
    sqlite3 -column -header "$DB" "
        SELECT p.name AS playlist, s.name AS song
        FROM playlist_songs ps
        JOIN playlists p ON p.id = ps.playlist_id
        JOIN songs s ON s.id = ps.song_id
        ORDER BY p.name, s.name;"
    ;;
  song_tags | st)
    sqlite3 -column -header "$DB" "
        SELECT s.name AS song, t.name AS tag
        FROM song_tags st
        JOIN songs s ON s.id = st.song_id
        JOIN tags t ON t.id = st.tag_id
        ORDER BY s.name, t.name;"
    ;;
  *)
    echo "Unknown table: $table" >&2
    echo "Available: playlists, songs, tags, playlist_songs (ps), song_tags (st)" >&2
    return 1
    ;;
  esac
}
