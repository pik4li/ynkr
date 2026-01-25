#!/usr/bin/env bash
# set -euo pipefail
SQL_SAFETY_FEATURES=(
  "-cmd"
  "PRAGMA busy_timeout=5000"
)
# ---------- core helper ----------
db() {
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" -tabs "$DB" "$@"
}

# Escape single quotes for SQL: ' -> ''
_sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}

# ---------- init ----------

db:init() {
  [[ -n "$DB" ]] || exit
  [[ -f "$DB" ]] || touch "$DB"

  log info "${ANSI[yellow]}[db:init:]${ANSI[nc]} Initializing database"

  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<'SQL'
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
  cols=$(sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "PRAGMA table_info(songs);" | cut -d'|' -f2)
  [[ "$cols" == *"artist"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN artist TEXT;"
  [[ "$cols" == *"album"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN album TEXT;"
  [[ "$cols" == *"file_path"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN file_path TEXT;"
  # artists = all artists semicolon-separated (for Jellyfin ARTISTS tag)
  [[ "$cols" == *"artists"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN artists TEXT;"
  # AcoustID metadata fields
  [[ "$cols" == *"acoustid_id"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN acoustid_id TEXT;"
  [[ "$cols" == *"metadata_source"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN metadata_source TEXT;"
  [[ "$cols" == *"metadata_score"* ]] || sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "ALTER TABLE songs ADD COLUMN metadata_score REAL;"
}

# ---------- playlists ----------

db:add-playlist() {
  local name="$1" yt_id="$2"
  local name_esc yt_id_esc
  name_esc=$(_sql_escape "$name")
  yt_id_esc=$(_sql_escape "$yt_id")
  log info "${ANSI[yellow]}[db:add-playlist:]${ANSI[nc]} name=${ANSI[cyan]}${name@Q}${ANSI[nc]} | id=${ANSI[magenta]}${yt_id@Q}${ANSI[nc]}"

  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
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
  log info "${ANSI[yellow]}[db:add-song:]${ANSI[nc]} name=${ANSI[cyan]}${name@Q}${ANSI[nc]} | ytid=${ANSI[magenta]}${yt_id@Q}${ANSI[nc]}"

  # Insert new song, or update name if it was empty/null
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
INSERT INTO songs (name, yt_id)
VALUES ('$name_esc', '$yt_id_esc')
ON CONFLICT(yt_id) DO UPDATE SET
  name = CASE
    WHEN excluded.name != '' AND (songs.name IS NULL OR songs.name = '')
    THEN excluded.name
    ELSE songs.name
  END;
SQL

  if [[ -n "$playlist" ]]; then
    playlist_esc=$(_sql_escape "$playlist")
    log info "${ANSI[yellow]}[db:add-song:]${ANSI[nc]} playlist=${ANSI[green]}$(db:get-song-name "$playlist")"

    sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
INSERT OR IGNORE INTO playlist_songs (playlist_id, song_id)
SELECT p.id, s.id
FROM playlists p, songs s
WHERE p.yt_id='$playlist_esc'
  AND s.yt_id='$yt_id_esc';
SQL
  fi
}

# ---------- tags ----------

# State tags are mutually exclusive - setting one removes all others
# This represents the song's current processing state
_STATE_TAGS="pending,downloaded,organized,failed,unavailable,mb_error,mb_fallback,mb_file_fallback,move_error,jellyfin_tagged,jellyfin_error,processed,aid_processed,aid_fallback,aid_error,aid_move_error"

# Final/completed state tags - songs with these should not be re-processed
_COMPLETED_TAGS="processed,jellyfin_tagged,organized"

# AcoustID state tags
_AID_TAGS="aid_processed,aid_fallback,aid_error,aid_move_error"

db:is-song-processed() {
  # Check if song already has a completed state tag
  local yt_id="$1"
  local yt_id_esc
  yt_id_esc=$(_sql_escape "$yt_id")

  local count
  count=$(
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
SELECT COUNT(*)
FROM song_tags st
JOIN songs s ON s.id = st.song_id
JOIN tags t ON t.id = st.tag_id
WHERE s.yt_id = ?1
  AND t.name IN ('processed','jellyfin_tagged','organized');
SQL
  )

  ((count > 0))
}

db:tag-song() {
  local song_id="$1" tag="$2"
  local song_id_esc tag_esc
  song_id_esc=$(_sql_escape "$song_id")
  tag_esc=$(_sql_escape "$tag")

  # Remove all existing state tags first, then add the new one
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
-- Ensure tag exists
INSERT OR IGNORE INTO tags (name) VALUES ('$tag_esc');

-- Remove all state tags from this song
DELETE FROM song_tags
WHERE song_id = (SELECT id FROM songs WHERE yt_id = '$song_id_esc')
  AND tag_id IN (
    SELECT id FROM tags WHERE name IN ($(echo "$_STATE_TAGS" | sed "s/,/','/g" | sed "s/^/'/" | sed "s/$/'/"))
  );

-- Add the new tag
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
  log info "${ANSI[yellow]}[db:update-song-name:]${ANSI[nc]} id=${ANSI[cyan]}$id${ANSI[nc]} | name=${ANSI[magenta]}$newname"

  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
UPDATE songs SET name='$newname_esc' WHERE yt_id='$id';
SQL
}

db:update-song-metadata() {
  local yt_id="$1" artist="$2" album="$3" path="$4" artists="${5:-}"
  local yt_id_esc artist_esc album_esc path_esc artists_esc
  yt_id_esc=$(_sql_escape "$yt_id")
  artist_esc=$(_sql_escape "$artist")
  album_esc=$(_sql_escape "$album")
  path_esc=$(_sql_escape "$path")
  artists_esc=$(_sql_escape "$artists")
  log info "${ANSI[yellow]}[db:update-song-metadata:]${ANSI[nc]} id=${ANSI[red]}$yt_id${ANSI[nc]} | artist=${ANSI[cyan]}$artist${ANSI[nc]} | artists=${ANSI[magenta]}$artists${ANSI[nc]} | album=${ANSI[blue]}$album"

  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
UPDATE songs SET artist='$artist_esc', album='$album_esc', file_path='$path_esc', artists='$artists_esc'
WHERE yt_id='$yt_id_esc';
SQL
}

db:update-song-acoustid() {
  local yt_id="$1" acoustid_id="$2" metadata_source="$3" metadata_score="$4"
  local yt_id_esc acoustid_id_esc metadata_source_esc
  yt_id_esc=$(_sql_escape "$yt_id")
  acoustid_id_esc=$(_sql_escape "$acoustid_id")
  metadata_source_esc=$(_sql_escape "$metadata_source")

  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
UPDATE songs SET acoustid_id='$acoustid_id_esc', metadata_source='$metadata_source_esc', metadata_score=$metadata_score
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
  db:tag-song "$yt_id" "downloaded"
}

db:mark-failed() {
  local yt_id="$1"
  db:tag-song "$yt_id" "failed"
}

db:cleanup-unavailable() {
  # Mark songs with empty names as 'unavailable' and remove all other state tags
  # These are videos that were private/deleted when added
  log info "${ANSI[yellow]}[db:cleanup:]${ANSI[nc]} Marking unavailable songs (empty names)..."

  local count
  count=$(sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "SELECT COUNT(*) FROM songs WHERE name IS NULL OR name = '';")

  if ((count == 0)); then
    log info "${ANSI[yellow]}[db:cleanup:]${ANSI[nc]} No unavailable songs found"
    return 0
  fi

  # Tag each unavailable song (db:tag-song handles removing other state tags)
  local yt_id
  while IFS= read -r yt_id; do
    [[ -n "$yt_id" ]] && db:tag-song "$yt_id" "unavailable"
  done < <(sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" "SELECT yt_id FROM songs WHERE name IS NULL OR name = '';")

  log info "${ANSI[yellow]}[db:cleanup:]${ANSI[nc]} Marked ${ANSI[cyan]}${count}${ANSI[nc]} songs as unavailable"
}

# ---------- display ----------

db:show() {
  local table="${1:-}"

  if [[ -z "$table" ]]; then
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<'SQL'
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
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" -column -header "$DB" "SELECT id, yt_id, name, created_at FROM playlists;"
    ;;
  songs)
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" -column -header "$DB" "
      SELECT
        s.id,
        s.yt_id,
        s.name,
        s.artist,
        s.artists,
        s.album,
        COALESCE(GROUP_CONCAT(t.name, ', '), '') AS tags
      FROM songs s
      LEFT JOIN song_tags st ON st.song_id = s.id
      LEFT JOIN tags t ON t.id = st.tag_id
      GROUP BY s.id
      ORDER BY s.id;"
    ;;
  tags)
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" -column -header "$DB" "SELECT id, name FROM tags;"
    ;;
  playlist_songs | ps)
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" -column -header "$DB" "
        SELECT p.name AS playlist, s.name AS song
        FROM playlist_songs ps
        JOIN playlists p ON p.id = ps.playlist_id
        JOIN songs s ON s.id = ps.song_id
        ORDER BY p.name, s.name;"
    ;;
  song_tags | st)
    sqlite3 "${SQL_SAFETY_FEATURES[@]}" -column -header "$DB" "
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
