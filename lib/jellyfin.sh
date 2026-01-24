#!/usr/bin/env bash
# Jellyfin metadata preparation for organized music files
# Ensures audio files have proper tags for Jellyfin compatibility

# ---------- title cleaning ----------

# Patterns to remove from titles (YouTube cruft)
_jf_clean_title() {
  local title="$1"

  # Remove common cruft patterns (case-insensitive via bash)
  local patterns=(
    # Production credits
    '\(Prod\.? by [^)]+\)'
    '\[Prod\.? by [^]]+\]'

    # Official/quality markers
    '\(Official[^)]*\)'
    '\[Official[^]]*\]'
    '\(Unofficial[^)]*\)'
    '\[Unofficial[^]]*\]'
    '\(HD\)' '\[HD\]'
    '\(HQ\)' '\[HQ\]'
    '\(4K\)' '\[4K\]'
    '\(1080p\)' '\[1080p\]'
    '\(720p\)' '\[720p\]'
    '\(Audio\)' '\[Audio\]'
    '\(Audio Only\)' '\[Audio Only\]'

    # Video types
    '\(Music Video\)' '\[Music Video\]'
    '\(M/?V\)' '\[M/?V\]'
    '\(Visualizer\)' '\[Visualizer\]'
    '\(Lyric Video\)' '\[Lyric Video\]'
    '\(Lyrics?\)' '\[Lyrics?\]'

    # Platform markers
    '\(YouTube\)' '\[YouTube\]'
    '\(Spotify\)' '\[Spotify\]'
    '\(Apple Music\)' '\[Apple Music\]'
    '\(SoundCloud\)' '\[SoundCloud\]'
    '- YouTube$'
    '- Spotify$'
    '- Official$'

    # Release markers
    '\(Single\)' '\[Single\]'
    '\(EP\)' '\[EP\]'
    '\(Album\)' '\[Album\]'
    '\(Deluxe\)' '\[Deluxe\]'
    '\(Explicit\)' '\[Explicit\]'
    '\(Clean\)' '\[Clean\]'
    '\(Radio Edit\)' '\[Radio Edit\]'

    # Premiere markers
    '\(Premiere\)' '\[Premiere\]'
    '\(World Premiere\)' '\[World Premiere\]'
    '\| Video Premiere'

    # Director credits
    '\(Dir\.? by [^)]+\)'
    '\[Dir\.? by [^]]+\]'

    # Hashtags and years
    '\(#[^)]+\)'
    '\[#[^]]+\]'
    '\([0-9]{4}\)'
    '\[[0-9]{4}\]'

    # Misc
    '\(Out Now\)' '\[Out Now\]'
    '\(New Music\)' '\[New Music\]'
    '\(Free Download\)' '\[Free Download\]'
  )

  for pattern in "${patterns[@]}"; do
    # Use sed for regex replacement (bash parameter expansion doesn't support regex)
    title=$(printf '%s' "$title" | sed -E "s/$pattern//gi")
  done

  # Clean up whitespace
  title=$(printf '%s' "$title" | sed -E 's/\s+/ /g')
  title=$(printf '%s' "$title" | sed -E 's/^\s*[-–—]+\s*//')
  title=$(printf '%s' "$title" | sed -E 's/\s*[-–—]+\s*$//')
  title=$(printf '%s' "$title" | xargs)  # trim

  printf '%s' "$title"
}

# ---------- featured artist extraction ----------

_jf_extract_featured() {
  local title="$1"
  local featured=""

  # Extract featured artists from common patterns
  # feat. / ft. / featuring (case-insensitive)
  local feat_match

  # Try to extract feat. artists
  feat_match=$(printf '%s' "$title" | grep -oiE '(feat\.|ft\.|featuring)\s+[^(\[]+' | head -1)

  if [[ -n "$feat_match" ]]; then
    # Remove the feat./ft./featuring prefix
    featured=$(printf '%s' "$feat_match" | sed -E 's/^(feat\.|ft\.|featuring)\s+//i')
    # Split on & , and
    featured=$(printf '%s' "$featured" | sed -E 's/\s*&\s*/; /g; s/\s*,\s*/; /g; s/\s+and\s+/; /gi')
  fi

  printf '%s' "$featured"
}

_jf_remove_featured_from_title() {
  local title="$1"

  # Remove featured artist notation from title
  title=$(printf '%s' "$title" | sed -E 's/\s+(feat\.|ft\.|featuring)\s+[^(\[]+//gi')
  title=$(printf '%s' "$title" | sed -E 's/\s*\((feat\.|ft\.|featuring)\s+[^)]+\)//gi')
  title=$(printf '%s' "$title" | sed -E 's/\s*\[(feat\.|ft\.|featuring)\s+[^]]+\]//gi')

  printf '%s' "$title" | xargs
}

# ---------- artist formatting ----------

_jf_normalize_artist_separators() {
  local artist="$1"

  # Normalize separators to semicolon for Jellyfin
  # & -> ;
  # , -> ;
  # " and " -> ;
  # " x " -> ;
  artist=$(printf '%s' "$artist" | sed -E 's/\s*&\s*/; /g')
  artist=$(printf '%s' "$artist" | sed -E 's/\s*,\s*/; /g')
  artist=$(printf '%s' "$artist" | sed -E 's/\s+and\s+/; /gi')
  artist=$(printf '%s' "$artist" | sed -E 's/\s+x\s+/; /gi')

  # Clean up multiple semicolons
  artist=$(printf '%s' "$artist" | sed -E 's/;\s*;/;/g')
  artist=$(printf '%s' "$artist" | xargs)

  printf '%s' "$artist"
}

_jf_format_artists_for_jellyfin() {
  local primary="$1"
  local featured="$2"

  # If no featured, just return primary
  if [[ -z "$featured" ]]; then
    printf '%s' "$primary"
    return
  fi

  # Normalize primary artist separators
  local primary_norm
  primary_norm=$(_jf_normalize_artist_separators "$primary")

  # Combine primary + featured, deduplicate
  local all_artists="${primary_norm}; ${featured}"

  # Remove duplicates while preserving order
  local seen=() unique=() artist
  IFS='; ' read -ra artists <<< "$all_artists"
  for artist in "${artists[@]}"; do
    artist=$(printf '%s' "$artist" | xargs)  # trim
    [[ -z "$artist" ]] && continue

    local artist_lower="${artist,,}"
    local found=false
    for s in "${seen[@]}"; do
      [[ "${s,,}" == "$artist_lower" ]] && found=true && break
    done

    if [[ "$found" == "false" ]]; then
      seen+=("$artist")
      unique+=("$artist")
    fi
  done

  # Join with semicolon
  local result=""
  for artist in "${unique[@]}"; do
    [[ -n "$result" ]] && result+="; "
    result+="$artist"
  done

  printf '%s' "$result"
}

# ---------- album artist determination ----------

_jf_determine_album_artist() {
  local primary="$1"
  local album="$2"

  # Default to primary artist
  [[ -z "$primary" ]] && primary="Unknown Artist"

  # For singles, use primary artist
  if [[ -z "$album" || "$album" == "singles" || "$album" == "Singles" ]]; then
    printf '%s' "$primary"
    return
  fi

  # Check if album suggests compilation
  local album_lower="${album,,}"
  local compilation_keywords=("various" "compilation" "soundtrack" "ost" "greatest hits" "best of" "now that" "top hits")

  for keyword in "${compilation_keywords[@]}"; do
    if [[ "$album_lower" == *"$keyword"* ]]; then
      printf 'Various Artists'
      return
    fi
  done

  printf '%s' "$primary"
}

# ---------- tag writing ----------

_jf_write_tags() {
  local file="$1"
  local title="$2"
  local artist="$3"
  local album="$4"
  local artists="$5"       # Semicolon-separated all artists
  local album_artist="$6"

  local ext="${file##*.}"
  ext="${ext,,}"  # lowercase

  # Use ffmpeg to write metadata (works for most formats)
  # For OGG/Opus/FLAC, we need to handle ARTISTS specially

  local tmp_file="${file}.tmp.${ext}"

  case "$ext" in
    ogg|opus|flac)
      # Vorbis comment format - supports ARTISTS as multiple values
      # Build metadata arguments
      local meta_args=(
        -metadata "TITLE=${title}"
        -metadata "ARTIST=${artist}"
        -metadata "ALBUM=${album}"
        -metadata "ALBUMARTIST=${album_artist}"
      )

      # Add ARTISTS as separate metadata entries for each artist
      if [[ -n "$artists" ]]; then
        IFS='; ' read -ra artist_list <<< "$artists"
        for a in "${artist_list[@]}"; do
          a=$(printf '%s' "$a" | xargs)
          [[ -n "$a" ]] && meta_args+=(-metadata "ARTISTS=${a}")
        done
      fi

      ffmpeg -y -i "$file" -c copy "${meta_args[@]}" "$tmp_file" 2>/dev/null
      ;;
    mp3|m4a|aac)
      # ID3/MP4 format
      ffmpeg -y -i "$file" -c copy \
        -metadata "title=${title}" \
        -metadata "artist=${artist}" \
        -metadata "album=${album}" \
        -metadata "album_artist=${album_artist}" \
        "$tmp_file" 2>/dev/null
      ;;
    *)
      # Generic attempt
      ffmpeg -y -i "$file" -c copy \
        -metadata "title=${title}" \
        -metadata "artist=${artist}" \
        -metadata "album=${album}" \
        "$tmp_file" 2>/dev/null
      ;;
  esac

  # Replace original with tagged version
  if [[ -f "$tmp_file" ]]; then
    mv "$tmp_file" "$file"
    return 0
  else
    return 1
  fi
}

# ---------- main processing ----------

_jf_process_file() {
  local file="$1"
  local yt_id artist album title

  # Escape file path for SQL (single quotes)
  local file_esc="${file//\'/\'\'}"

  # Look up by file_path (files are named by title after mb:process)
  local db_data
  db_data=$(db "SELECT yt_id, name, artist, album FROM songs WHERE file_path='$file_esc';" 2>&1)

  if [[ -z "$db_data" || "$db_data" == *"Error"* ]]; then
    log warn "${ANSI[green]}[jf:]${ANSI[nc]} No DB entry for file: ${ANSI[cyan]}${file}${ANSI[nc]}"
    [[ "$db_data" == *"Error"* ]] && log err "${ANSI[green]}[jf:]${ANSI[nc]} SQL error: ${db_data}"
    return 1
  fi

  # Parse tab-separated values
  IFS=$'\t' read -r yt_id title artist album <<< "$db_data"

  [[ -z "$title" ]] && title=$(basename "$file" | sed 's/\.[^.]*$//')
  [[ -z "$artist" ]] && artist="Unknown Artist"
  [[ -z "$album" ]] && album="singles"

  log info "${ANSI[green]}[jf:]${ANSI[nc]} Processing ${ANSI[cyan]}${title}${ANSI[nc]} by ${ANSI[magenta]}${artist}${ANSI[nc]}"

  # Clean title
  local clean_title
  clean_title=$(_jf_clean_title "$title")

  # Extract featured artists before removing from title
  local featured
  featured=$(_jf_extract_featured "$clean_title")

  # Remove featured notation from title
  clean_title=$(_jf_remove_featured_from_title "$clean_title")

  # Format artists for Jellyfin (semicolon-separated list)
  local artists_field
  artists_field=$(_jf_format_artists_for_jellyfin "$artist" "$featured")

  # Determine album artist
  local album_artist
  album_artist=$(_jf_determine_album_artist "$artist" "$album")

  # Get primary artist (first from the list)
  local primary_artist
  primary_artist=$(printf '%s' "$artists_field" | cut -d';' -f1 | xargs)
  [[ -z "$primary_artist" ]] && primary_artist="$artist"

  log info "${ANSI[green]}[jf:]${ANSI[nc]}   Title: ${ANSI[cyan]}${clean_title}${ANSI[nc]}"
  log info "${ANSI[green]}[jf:]${ANSI[nc]}   Artist: ${ANSI[magenta]}${primary_artist}${ANSI[nc]}"
  log info "${ANSI[green]}[jf:]${ANSI[nc]}   Artists: ${ANSI[blue]}${artists_field}${ANSI[nc]}"
  log info "${ANSI[green]}[jf:]${ANSI[nc]}   Album: ${ANSI[yellow]}${album}${ANSI[nc]}"
  log info "${ANSI[green]}[jf:]${ANSI[nc]}   AlbumArtist: ${ANSI[red]}${album_artist}${ANSI[nc]}"

  # Write tags to file
  if _jf_write_tags "$file" "$clean_title" "$primary_artist" "$album" "$artists_field" "$album_artist"; then
    log info "${ANSI[green]}[jf:]${ANSI[nc]} ${ANSI[green]}Tagged${ANSI[nc]} ${ANSI[cyan]}${clean_title}${ANSI[nc]}"
    db:tag-song "$yt_id" "jellyfin_tagged"

    # Update database with cleaned title
    db:update-song-name "$yt_id" "$clean_title"
    return 0
  else
    log err "${ANSI[green]}[jf:]${ANSI[nc]} ${ANSI[red]}Failed to tag${ANSI[nc]} ${file}"
    db:tag-song "$yt_id" "jellyfin_error"
    return 1
  fi
}

_jf_get_untagged_files() {
  # Find files in MUSIC_DIR that are 'organized' but not 'jellyfin_tagged'
  local files=()
  local yt_id tags file_path

  # Get all organized songs from database
  while IFS=$'\t' read -r yt_id file_path; do
    [[ -z "$yt_id" || -z "$file_path" ]] && continue
    [[ -f "$file_path" ]] || continue

    # Check if already tagged for Jellyfin
    tags=$(db:get-song-tag "$yt_id" 2>/dev/null)
    if [[ "$tags" == *"organized"* && "$tags" != *"jellyfin_tagged"* ]]; then
      files+=("$file_path")
    fi
  done < <(db "SELECT yt_id, file_path FROM songs WHERE file_path IS NOT NULL AND file_path != '';")

  printf '%s\n' "${files[@]}"
}

jf:process() {
  log info "${ANSI[green]}[jf:]${ANSI[nc]} ${ANSI[green]}Starting Jellyfin metadata processing${ANSI[nc]}"

  # Get files needing Jellyfin tags
  local files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(_jf_get_untagged_files)

  local count=${#files[@]}
  if ((count == 0)); then
    log info "${ANSI[green]}[jf:]${ANSI[nc]} No files to process"
    return 0
  fi

  log info "${ANSI[green]}[jf:]${ANSI[nc]} Found ${ANSI[cyan]}${count}${ANSI[nc]} files to tag for Jellyfin"

  # Process files
  local processed=0
  for file in "${files[@]}"; do
    _jf_process_file "$file" && ((processed++))
  done

  log info "${ANSI[green]}[jf:]${ANSI[nc]} ${ANSI[green]}Processed${ANSI[nc]} ${ANSI[cyan]}${processed}/${count}${ANSI[nc]} files"
}

# Process a single file by path (for manual/async use)
jf:tag() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    log err "${ANSI[green]}[jf:tag:]${ANSI[nc]} File not found: ${file}"
    return 1
  fi

  _jf_process_file "$file"
}
