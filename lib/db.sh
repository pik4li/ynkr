#!/usr/bin/env bash
# set -euo pipefail

# ---------- sqlite safety ----------
SQL_SAFETY_FEATURES=(
  -cmd "PRAGMA busy_timeout=5000"
)

# ---------- core helpers ----------

db_exec() {
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" "$DB" <<SQL
$1
SQL
}

db_query() {
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" -batch "$DB" "$1"
}

db_scalar() {
  sqlite3 "${SQL_SAFETY_FEATURES[@]}" -batch -noheader "$DB" "$1"
}

# Escape single quotes for SQL: ' -> ''
_sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}

# ---------- init ----------

db:init() {
  [[ -n "$DB" ]] || exit 1
  [[ -f "$DB" ]] || touch "$DB"

  log info "[db:init] Initializing database"

  db_exec '
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
'

  db:migrate-mb
}

# ---------- migrations ----------

db:migrate-mb() {
  local cols
  cols=$(db_query "PRAGMA table_info(songs);" | cut -d'|' -f2)

  [[ "$cols" == *artist* ]] || db_exec "ALTER TABLE songs ADD COLUMN artist TEXT;"
  [[ "$cols" == *album* ]] || db_exec "ALTER TABLE songs ADD COLUMN album TEXT;"
  [[ "$cols" == *file_path* ]] || db_exec "ALTER TABLE songs ADD COLUMN file_path TEXT;"
  [[ "$cols" == *artists* ]] || db_exec "ALTER TABLE songs ADD COLUMN artists TEXT;"
  [[ "$cols" == *acoustid_id* ]] || db_exec "ALTER TABLE songs ADD COLUMN acoustid_id TEXT;"
  [[ "$cols" == *metadata_source* ]] || db_exec "ALTER TABLE songs ADD COLUMN metadata_source TEXT;"
  [[ "$cols" == *metadata_score* ]] || db_exec "ALTER TABLE songs ADD COLUMN metadata_score REAL;"
}

# ---------- playlists ----------

db:add-playlist() {
  local name_esc yt_id_esc
  name_esc=$(_sql_escape "$1")
  yt_id_esc=$(_sql_escape "$2")

  db_exec "
INSERT INTO playlists (name, yt_id)
VALUES ('$name_esc', '$yt_id_esc')
ON CONFLICT(yt_id) DO UPDATE SET name=excluded.name;
"
}

# ---------- songs ----------

db:add-song() {
  local name_esc yt_id_esc playlist_esc
  name_esc=$(_sql_escape "$1")
  yt_id_esc=$(_sql_escape "$2")

  db_exec "
INSERT INTO songs (name, yt_id)
VALUES ('$name_esc', '$yt_id_esc')
ON CONFLICT(yt_id) DO UPDATE SET
  name = CASE
    WHEN excluded.name != '' AND (songs.name IS NULL OR songs.name = '')
    THEN excluded.name
    ELSE songs.name
  END;
"

  [[ -n "$3" ]] || return 0
  playlist_esc=$(_sql_escape "$3")

  db_exec "
INSERT OR IGNORE INTO playlist_songs (playlist_id, song_id)
SELECT p.id, s.id
FROM playlists p, songs s
WHERE p.yt_id='$playlist_esc'
  AND s.yt_id='$yt_id_esc';
"
}

# ---------- tags ----------

_STATE_TAGS="'pending','downloaded','organized','failed','unavailable','mb_error','mb_fallback','mb_file_fallback','move_error','jellyfin_tagged','jellyfin_error','processed','aid_processed','aid_fallback','aid_error','aid_move_error'"

db:is-song-processed() {
  local yt_id_esc
  yt_id_esc=$(_sql_escape "$1")

  local count
  count=$(db_scalar "
SELECT COUNT(*)
FROM song_tags st
JOIN songs s ON s.id = st.song_id
JOIN tags t ON t.id = st.tag_id
WHERE s.yt_id = '$yt_id_esc'
  AND t.name IN ('processed','jellyfin_tagged','organized');
")

  ((count > 0))
}

db:tag-song() {
  local song_id_esc tag_esc
  song_id_esc=$(_sql_escape "$1")
  tag_esc=$(_sql_escape "$2")

  db_exec "
INSERT OR IGNORE INTO tags (name) VALUES ('$tag_esc');

DELETE FROM song_tags
WHERE song_id = (SELECT id FROM songs WHERE yt_id='$song_id_esc')
  AND tag_id IN (SELECT id FROM tags WHERE name IN ($_STATE_TAGS));

INSERT OR IGNORE INTO song_tags (song_id, tag_id)
SELECT s.id, t.id FROM songs s, tags t
WHERE s.yt_id='$song_id_esc' AND t.name='$tag_esc';
"
}

# ---------- queries ----------

db:get-song-ids() {
  local playlist_esc
  playlist_esc=$(_sql_escape "$1")

  db_query "
SELECT s.yt_id
FROM playlists p
JOIN playlist_songs ps ON ps.playlist_id=p.id
JOIN songs s ON s.id=ps.song_id
WHERE p.yt_id='$playlist_esc';
"
}

db:get-pending() {
  db_query "
SELECT s.yt_id
FROM songs s
JOIN song_tags st ON st.song_id=s.id
JOIN tags t ON t.id=st.tag_id
WHERE t.name='pending';
"
}
