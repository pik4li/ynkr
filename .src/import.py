#!/usr/bin/env python3
"""
organize_music.py

Organizes audio files from a source directory into a structured destination directory based on embedded metadata.

- Reads metadata (title, artist, album, year) using mutagen.
- Skips files with missing/untrustworthy metadata.
- Copies files as <Artist> - <Title>.<ext> into <dest>/<Artist>/.
- Avoids overwriting by appending (1), (2), etc. if needed.
- Supports --dry-run mode.
- Logs actions: [COPIED], [SKIPPED], [EXISTS], [MISSING].
- Returns proper exit codes for shell integration.

Usage:
  python organize_music.py <source_dir> <dest_dir> [--dry-run]

Environment variables (set via .env or Docker):
- OLLAMA_URL: URL of the Ollama server (default: http://localhost:11434)
- OLLAMA_MODEL: Model name to use (default: phi)
- USE_OLLAMA: Set to 'true' to enable Ollama fallback, 'false' to disable (default: true)
- USE_OPENAI: Set to 'true' to enable OpenAI fallback, 'false' to disable (default: false)
"""
import os
import sys
import shutil
import argparse
from mutagen._file import File as MutagenFile
from mutagen.easyid3 import EasyID3
from mutagen.id3._util import ID3NoHeaderError
from typing import Optional
import re
import requests
import json
from dotenv import load_dotenv
import time
from openai import OpenAI
import textwrap
from mutagen.mp4 import MP4
import unicodedata
import sqlite3
from datetime import datetime
from difflib import SequenceMatcher


# Load environment variables from .env if present
load_dotenv()

# Ollama config from environment
OLLAMA_URL = os.getenv('OLLAMA_URL', 'http://localhost:11434')
OLLAMA_MODEL = os.getenv('OLLAMA_MODEL', 'phi4-mini')
USE_OLLAMA = os.getenv('USE_OLLAMA', 'true').lower() == 'true'

# OpenAI config from environment
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
OPENAI_MODEL = os.getenv('OPENAI_MODEL', 'gpt-4.1-mini')
USE_OPENAI = os.getenv('USE_OPENAI', 'false').lower() == 'true'

client = OpenAI(api_key=OPENAI_API_KEY)

# Supported audio extensions
AUDIO_EXTS = {'.mp3', '.m4a', '.opus', '.ogg', '.flac', '.wav', '.aac'}

# Add this helper function near the top, after AUDIO_EXTS
AUDIO_EXT_PREFERENCE = ['.flac', '.wav', '.aac', '.m4a', '.opus', '.ogg', '.mp3']
def best_audio_ext(exts):
    """Return the best extension from a list, based on AUDIO_EXT_PREFERENCE order."""
    for pref in AUDIO_EXT_PREFERENCE:
        if pref in exts:
            return pref
    return exts[0] if exts else None

# ANSI color codes for log output
RED = '\033[0;31m'
CYAN = '\033[0;36m'
YELLOW = '\033[0;33m'
LIGHT_GREEN = '\033[0;92m'
BOLD = '\033[1m'
MAGENTA = '\033[0;35m'
BLUE = '\033[0;34m'
NC = '\033[0m'  # No Color

HELP_TEXT = f"""
{BOLD}{CYAN}organize_music.py - AI-powered music file organizer{NC}

{BOLD}Usage:{NC}
  python import.py <source_dir> <dest_dir> [options]

{BOLD}Options:{NC}
  --dry-run     {CYAN}Print what would be done (copy, mkdir, etc.), but do not query the AI or copy files.{NC}
  --dry-ai      {CYAN}Query the AI for each file and print what the title/metadata would be and where it would be copied, but do not actually copy files.{NC}
  --debug       {CYAN}Process files one by one, print detailed info (input, AI prompt, AI response), and slow down for inspection.{NC}
  --bulk-import {CYAN}Bulk import all files to database to prevent future AI queries (no processing){NC}
  --cleanup-bulk {CYAN}Remove bulk import entries from database to allow processing{NC}
  -h, --help    {CYAN}Show this help message and exit.{NC}

{BOLD}Environment variables (set via .env or Docker):{NC}
  OLLAMA_URL      URL of the Ollama server (default: http://localhost:11434)
  OLLAMA_MODEL    Model name to use (default: phi4-mini)
  USE_OLLAMA      Set to 'true' to enable Ollama fallback, 'false' to disable (default: true)

  OPENAI_API_KEY  Your OpenAI API key
  OPENAI_MODEL    OpenAI model to use (default: gpt-4.1-mini)
  USE_OPENAI      Set to 'true' to enable OpenAI fallback, 'false' to disable (default: false)
"""

def log(msg: str, level: str = "INFO"):
    color = NC
    if level == "INFO":
        color = CYAN
    elif level == "SUCCESS" or level == "COPIED":
        color = LIGHT_GREEN
    elif level == "WARNING":
        color = YELLOW
    elif level == "ERROR":
        color = RED
    elif level == "LLM":
        color = BOLD + CYAN
    elif level == "UNSORTED":
        color = BOLD + YELLOW
    elif level == "DRY":
        color = BOLD + YELLOW
    print(f"{color}{BOLD}[{level}]{NC} {msg}{NC}")

def parse_args():
    parser = argparse.ArgumentParser(description="Organize music files by metadata.", add_help=False)
    parser.add_argument('source', nargs='?', help='Source directory with audio files')
    parser.add_argument('dest', nargs='?', help='Destination root directory for organized music')
    parser.add_argument('--dry-run', action='store_true', help='Preview actions without copying files or querying the AI')
    parser.add_argument('--dry-ai', action='store_true', help='Query the AI and print what would be done, but do not copy files')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode (process one file at a time, print extra info, slow down)')
    parser.add_argument('--bulk-import', action='store_true', help='Bulk import all files to database to prevent future AI queries (no processing)')
    parser.add_argument('--cleanup-bulk', action='store_true', help='Remove bulk import entries from database to allow processing')
    parser.add_argument('-h', '--help', action='store_true', help='Show this help message and exit')
    return parser.parse_args()

def is_audio_file(filename: str) -> bool:
    return os.path.splitext(filename)[1].lower() in AUDIO_EXTS

def get_metadata(filepath: str) -> dict:
    try:
        audio = MutagenFile(filepath, easy=True)
        if not audio:
            return {}
        tags = {}
        for tag in ['title', 'artist', 'album', 'date', 'year']:
            value = audio.get(tag)
            if value:
                tags[tag] = value[0]
        return tags
    except Exception as e:
        return {}

def query_ollama_for_metadata(filename, existing_artist=None, existing_title=None, debug=False):
    if not USE_OLLAMA:
        return None, None, None

    prompt = f"""You are a music filename and metadata cleaner. Your job is to process and clean up music filenames and their associated metadata. You are specialized for title names and artists. 
    You will receive the actual input data from me, which consists of a filename and, optionally, metadata fields for artist and title. 
    Your task is to analyze this input and determine if the metadata and filename are already correct and match the required format, or if they need to be fixed. 
    You must always follow the instructions and output format exactly as described below, and never make up or guess information that is not present in the input. 
    It is extremely important that you do not produce false positives: only respond with 'use_as_is: true' if the filename and metadata are already correct and match the required format. 
    If you are unsure, always respond with 'use_as_is: false' and provide the cleaned artist, artists, and title based strictly on the input data.

    Your job is to:
    - Only use information that is present in the filename or metadata fields above. Never invent or guess artist or title names.
    - The final filename must be in the format 'title.ext' (where 'ext' is the file extension). There should be no artist, no 'feat.', no 'ft.', no 'official video', no 'music video', or any other extra tags in the filename.
    - Remove any featuring/feat/ft/with/and/official video/music video/lyric video/visualizer/extra tags from both artist and title fields, and from the filename.
    - Do not hallucinate or invent any data. If the information is not present, leave it blank or do not include it.
    - If the artist and title are already correct and the filename is already in the format 'title.ext', respond with:
      {{"use_as_is": true}}
    - Otherwise, respond with:
      {{"use_as_is": false, "artist": "Main Artist", "artists": "Main Artist; Other Artist", "title": "Clean Title"}}
    - 'artist' is the main artist (string).
    - 'artists' is a list of all artists (main + featured + producers).
    - Always respond strictly in valid JSON, and only with the JSON object as described above. Do not include any extra explanation or text.
    - If you see any 'prod. by ..' you know, that .. should be the artist/producer.
      {{"use_as_is": false, "artist": "Main Artist", "artists": "Main Artist; Other Artist; Another Artist", "title": "Clean Title"}}

    Example 1:
    Filename: ACRAZE - Do It To It (Ft. Cherish).opus
    Metadata Artist: SubSoul
    Metadata Title: ACRAZE - Do It To It Ft Cherish
    Response:
    {{
      "use_as_is": false,
      "artist": "SubSoul",
      "artists": "SubSoul; ACRAZE; Cherish",
      "title": "Do It To It"
    }}

    Example 2:
    Filename: Do It To It.opus
    Metadata Artist: ACRAZE
    Metadata Title: Do It To It
    Response:
    {{
      "use_as_is": true
    }}

    Rules:
    - Always extract the main artist before the first dash ' - ' as the main artist (for the 'artist' tag).
    - If the title contains 'ft.', 'feat.', or 'featuring', extract the featured artists too.
    - If the filename contains 'prod. by X' or '(prod. by X & Y)', also treat those as artists.
    - Combine all artists (main + featured + producers) into the 'artists' field, as a list of strings, like ['Artist1', 'Artist2', 'Artist3'].
    - The 'artist' field should be only the main artist (string).
    - Remove any 'ft.', 'feat.', 'featuring', 'prod. by' info from the title completely.
    - Also remove tags like 'official video', 'lyrics', 'audio', etc.
    - Never include artist names or extra metadata in the title.
    - Do not hallucinate or guess missing info. Use only what's visible.
    - If you only input one artist, still check for other artists in the filename/title.

    Output JSON format only:
    - If the file is already clean and metadata has only the title: {"use_as_is": true}
    - Otherwise: {"use_as_is": false, "artist": "Main Artist", "artists": ["Main Artist", "Other Artist"], "title": "Clean Title"}

    Here is the input data you must process with the rules i've providet you with above:
    START OF METADATA
    Filename: {filename}
    {f"Metadata Artist: {existing_artist}" if existing_artist else ""}
    {f"Metadata Title: {existing_title}" if existing_title else ""}
    END OF METADATA
    """

    if debug:
        log(f"[DEBUG] LLM prompt: {prompt}", level="LLM")
    try:
        response = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": OLLAMA_MODEL,
                "prompt": prompt,
                "stream": False
            },
            timeout=180
        )
        result = response.json()
        if debug:
            log(f"[DEBUG] LLM raw response: {result}", level="LLM")
        if not result.response:
            return None, None, None
        data = json.loads(result.response)
        use_as_is = data.get('use_as_is', False)
        return use_as_is, data.get('artist'), data.get('title')
    except Exception as e:
        log(f"[ERROR] Ollama parsing failed: {e}", level="ERROR")
        return None, None, None

def query_openai_for_metadata(filename, existing_artist=None, existing_title=None, debug=False):
    if not (USE_OPENAI and OPENAI_API_KEY):
        return None, None, None
    
    prompt = f"""You are a music filename and metadata cleaner. Your job is to process and clean up music filenames and their associated metadata. You are specialized for title names and artists. 
    You will receive the actual input data from me, which consists of a filename and, optionally, metadata fields for artist and title. 
    Your task is to analyze this input and determine if the metadata and filename are already correct and match the required format, or if they need to be fixed. 
    You must always follow the instructions and output format exactly as described below, and never make up or guess information that is not present in the input. 
    It is extremely important that you do not produce false positives: only respond with 'use_as_is: true' if the filename and metadata are already correct and match the required format. 
    If you are unsure, always respond with 'use_as_is: false' and provide the cleaned artist, artists, and title based strictly on the input data.

    Your job is to:
    - Only use information that is present in the filename or metadata fields above. Never invent or guess artist or title names.
    - The final filename must be in the format 'title.ext' (where 'ext' is the file extension). There should be no artist, no 'feat.', no 'ft.', no 'official video', no 'music video', or any other extra tags in the filename.
    - Remove any featuring/feat/ft/with/and/official video/music video/lyric video/visualizer/extra tags from both artist and title fields, and from the filename.
    - Do not hallucinate or invent any data. If the information is not present, leave it blank or do not include it.
    - If the artist and title are already correct and the filename is already in the format 'title.ext', respond with:
      {{"use_as_is": true}}
    - Otherwise, respond with:
      {{"use_as_is": false, "artist": "Main Artist", "artists": "Main Artist; Other Artist", "title": "Clean Title"}}
    - 'artist' is the main artist (string).
    - 'artists' is a list of all artists (main + featured + producers).
    - Always respond strictly in valid JSON, and only with the JSON object as described above. Do not include any extra explanation or text.
    - If you see any 'prod. by ..' you know, that .. should be the artist/producer.
      {{"use_as_is": false, "artist": "Main Artist", "artists": "Main Artist; Other Artist; Another Artist", "title": "Clean Title"}}

    Example 1:
    Filename: ACRAZE - Do It To It (Ft. Cherish).opus
    Metadata Artist: SubSoul
    Metadata Title: ACRAZE - Do It To It Ft Cherish
    Response:
    {{
      "use_as_is": false,
      "artist": "SubSoul",
      "artists": "SubSoul; ACRAZE; Cherish",
      "title": "Do It To It"
    }}

    Example 2:
    Filename: Do It To It.opus
    Metadata Artist: ACRAZE
    Metadata Title: Do It To It
    Response:
    {{
      "use_as_is": true
    }}

    Example 3:
    Filename: ART - BELGISCHES VIERTEL (prod. by FRIO & EDDY).opus
    Metadata Artist: 23HOURS
    Metadata Title: ART - BELGISCHES VIERTEL (prod. by FRIO & EDDY)ai
    Response:
    {{
      "use_as_is": false,
      "artist": "23HOURS",
      "artists": "23HOURS; FRIO; EDDY",
      "title": "Belgisches Viertel"
    }}

    Remember: Only use the data provided below. Never guess or invent. Always follow the output format exactly.

    Here is the input data you must process with the rules i've providet you with above:
    START OF METADATA
    Filename: {filename}
    {f"Metadata Artist: {existing_artist}" if existing_artist else ""}
    {f"Metadata Title: {existing_title}" if existing_title else ""}
    END OF METADATA
    """
    
    try:
        response = client.chat.completions.create(model=OPENAI_MODEL,
        messages=[
            {"role": "system", "content": "You are a music filename and metadata cleaner."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.2,
        timeout=180)
        content = response.choices[0].message.content
        if debug:
            log(f"[DEBUG] OpenAI raw response: {content}", level="LLM")
        if not content:
            return None, None, None
        data = json.loads(content)
        use_as_is = data.get('use_as_is', False)
        return use_as_is, data.get('artist'), data.get('title')
    except Exception as e:
        log(f"[ERROR] OpenAI parsing failed: {e}", level="ERROR")
        return None, None, None

# Normalization helpers
def normalize_string(s):
    if not s:
        return ""
    s = s.lower()
    s = unicodedata.normalize('NFKD', s)
    s = re.sub(r'[\s\-_]+', ' ', s)  # collapse spaces, dashes, underscores
    s = re.sub(r'[^a-z0-9 ]', '', s)   # remove punctuation
    s = s.strip()
    return s

def normalize_filename_for_db(filename):
    """Normalize filename for database storage and lookup to handle special characters."""
    if not filename:
        return ""
    # Normalize unicode characters
    normalized = unicodedata.normalize('NFC', filename)
    # Remove or replace problematic characters for database storage
    # Keep the original but also store a normalized version
    return normalized

def normalize_artist_list(artist_str):
    artists = [a.strip() for a in artist_str.split(';') if a.strip()]
    artists = sorted(set(normalize_string(a) for a in artists))
    return '; '.join(artists)

def sanitize_filename(s):
    # Remove or replace characters that are illegal in filenames
    return re.sub(r'[\\/:*?"<>|]', '', s).strip()

# SQLite DB helpers
DB_PATH = os.getenv('IMPORT_DB_PATH', os.path.join(os.getcwd(), 'music_imports.db'))
DB_TABLE = 'imports'

# Fuzzy ratio from environment
try:
    FUZZY_RATIO = float(os.getenv('FUZZY_RATIO', '0.95'))
except Exception:
    FUZZY_RATIO = 0.95

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(f'''
        CREATE TABLE IF NOT EXISTS {DB_TABLE} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            original_name TEXT,
            ai_artist TEXT,
            ai_title TEXT,
            storage_path TEXT,
            date_added TEXT
        )
    ''')
    conn.commit()
    conn.close()

def insert_db(original_name, ai_artist, ai_title, storage_path):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(f'''
        INSERT INTO {DB_TABLE} (original_name, ai_artist, ai_title, storage_path, date_added)
        VALUES (?, ?, ?, ?, ?)
    ''', (original_name, ai_artist, ai_title, storage_path, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def insert_db_skipped(original_name, reason="skipped"):
    """Insert a file into DB that was skipped to prevent future AI queries"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(f'''
        INSERT INTO {DB_TABLE} (original_name, ai_artist, ai_title, storage_path, date_added)
        VALUES (?, ?, ?, ?, ?)
    ''', (original_name, f"[{reason}]", f"[{reason}]", f"[{reason}]", datetime.now().isoformat()))
    conn.commit()
    conn.close()

def bulk_import_files_to_db(source_dir):
    """Bulk import all files from source directory to DB to prevent future AI queries"""
    log(f"[DB] Bulk importing all files from {source_dir} to prevent future AI queries...", level="INFO")
    count = 0
    for root, _, files in os.walk(source_dir):
        for fname in files:
            # Check if already in DB
            if check_db_by_filename_variations(fname):
                continue
            
            if is_audio_file(fname):
                insert_db_skipped(fname, "bulk_import_audio")
            else:
                insert_db_skipped(fname, "bulk_import_non_audio")
            count += 1
    
    log(f"[DB] Bulk imported {count} files to database", level="SUCCESS")
    return count

def cleanup_bulk_imports():
    """Remove bulk import entries from database to allow processing of specific files"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(f'DELETE FROM {DB_TABLE} WHERE ai_artist LIKE "[bulk_import_%]"')
    deleted_count = c.rowcount
    conn.commit()
    conn.close()
    log(f"[DB] Cleaned up {deleted_count} bulk import entries from database", level="SUCCESS")
    return deleted_count

def check_db_exact(original_name):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    # Try exact match first
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE original_name = ?', (original_name,))
    result = c.fetchone()
    if result:
        conn.close()
        return result
    
    # If no exact match, try with normalized filename
    normalized_name = normalize_filename_for_db(original_name)
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE original_name = ?', (normalized_name,))
    result = c.fetchone()
    conn.close()
    return result

def check_db_by_filename_variations(filename):
    """Check database for filename variations (case-insensitive, normalized, etc.)"""
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    
    # Try exact match
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE original_name = ?', (filename,))
    result = c.fetchone()
    if result:
        conn.close()
        return result
    
    # Try case-insensitive match
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE LOWER(original_name) = LOWER(?)', (filename,))
    result = c.fetchone()
    if result:
        conn.close()
        return result
    
    # Try normalized match
    normalized = normalize_filename_for_db(filename)
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE original_name = ?', (normalized,))
    result = c.fetchone()
    if result:
        conn.close()
        return result
    
    # Try normalized case-insensitive match
    c.execute(f'SELECT * FROM {DB_TABLE} WHERE LOWER(original_name) = LOWER(?)', (normalized,))
    result = c.fetchone()
    conn.close()
    return result

def check_db_fuzzy(ai_artist, ai_title, threshold=0.95):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(f'SELECT ai_artist, ai_title, storage_path FROM {DB_TABLE}')
    for row in c.fetchall():
        db_artist, db_title, db_path = row
        if is_similar(ai_artist, db_artist, threshold) and is_similar(ai_title, db_title, threshold):
            conn.close()
            return db_artist, db_title, db_path
    conn.close()
    return None

def is_similar(a, b, threshold=0.95):
    if not a or not b:
        return False
    return SequenceMatcher(None, a.lower(), b.lower()).ratio() >= threshold

# Boxed debug helper

def print_debug_box(sections):
    """
    sections: list of dicts with keys:
      - 'header': str (section header, e.g. '[DEBUG] [LLM INPUT]')
      - 'lines': list of str (lines to print, each will be prefixed with │)
      - 'color': ANSI color code (optional)
    """
    width = 56
    print(f"\n┌{'─'*width}─")
    for i, section in enumerate(sections):
        color = section.get('color', NC)
        header = section.get('header', None)
        if header:
            print(f"{color}{BOLD}{' ' if not header.startswith('[') else ''}{header}{NC}")
        for line in section.get('lines', []):
            for l in line.splitlines():
                if l.strip():
                    # Color artist and title specially
                    colored_line = l
                    if 'Artist:' in l and ':' in l:
                        parts = l.split(':', 1)
                        colored_line = f"{parts[0]}: {CYAN}{parts[1].strip()}{color}"
                    elif 'Title:' in l and ':' in l:
                        parts = l.split(':', 1)
                        colored_line = f"{parts[0]}: {LIGHT_GREEN}{parts[1].strip()}{color}"
                    print(f"│ {color}{colored_line}{NC}")
        # Print horizontal separator if not last section
        if i < len(sections) - 1:
            print(f"├{'─'*width}─")
    print(f"└{'─'*width}─\n")

def main():
    args = parse_args()
    if args.help or not args.source:
        print(HELP_TEXT)
        sys.exit(0)
    
    source = os.path.abspath(args.source)
    
    # Handle bulk import mode
    if args.bulk_import:
        if not os.path.isdir(source):
            log(f"Source directory does not exist: {source}", level="ERROR")
            sys.exit(2)
        bulk_import_files_to_db(source)
        sys.exit(0)
    
    # Handle cleanup mode
    if args.cleanup_bulk:
        cleanup_bulk_imports()
        sys.exit(0)
    
    # Normal mode requires both source and dest
    if not args.dest:
        print(HELP_TEXT)
        sys.exit(0)
    
    dest = os.path.abspath(args.dest)
    dry_run = args.dry_run
    dry_ai = getattr(args, 'dry_ai', False)
    debug = getattr(args, 'debug', False)

    if not os.path.isdir(source):
        log(f"Source directory does not exist: {source}", level="ERROR")
        sys.exit(2)
    if not os.path.isdir(dest):
        if dry_run or dry_ai:
            log(f"Would create destination directory: {dest}", level="DRY")
        else:
            os.makedirs(dest, exist_ok=True)

    exit_code = 0
    for root, _, files in os.walk(source):
        for fname in files:
            debug_sections = []
            # DB deduplication: check for exact match on original filename BEFORE any AI query
            db_exact = check_db_by_filename_variations(fname)
            if db_exact:
                if debug:
                    debug_sections.append({
                        'header': f'{CYAN}[DEBUG] [DB-EXACT] Skipping file (already imported):{NC}',
                        'lines': [
                            f'Filename: {fname}',
                            f'Imported as: {db_exact[3]}',
                            f'',
                            f'[WARNING] [DB] {fname} already imported as: {db_exact[3]} (skipping)'
                        ],
                        'color': YELLOW
                    })
                    print_debug_box(debug_sections)
                else:
                    log(f"[DB] {fname} already imported as: {db_exact[3]} (skipping)", level="WARNING")
                continue
            if not is_audio_file(fname):
                # Add non-audio files to DB to prevent future processing
                insert_db_skipped(fname, "not_audio")
                continue
            fpath = os.path.join(root, fname)
            meta = get_metadata(fpath)
            artist = meta.get('artist')
            title = meta.get('title')

            # NEW: Fuzzy deduplication using metadata BEFORE any AI query
            if artist and title:
                fuzzy_match = check_db_fuzzy(artist, title, threshold=FUZZY_RATIO)
                if fuzzy_match:
                    db_artist, db_title, db_path = fuzzy_match
                    insert_db(fname, db_artist, db_title, db_path)
                    if debug:
                        debug_sections.append({
                            'header': f'{YELLOW}[DEBUG] [DB-FUZZY] Fuzzy duplicate detected:{NC}',
                            'lines': [
                                f'Input:',
                                f'  Filename: {fname}',
                                f'  Artist:   {artist}',
                                f'  Title:    {title}',
                                f'',
                                f'Matched DB:',
                                f'  Artist:   {db_artist}',
                                f'  Title:    {db_title}',
                                f'  Path:     {db_path}',
                                f'',
                                f'[WARNING] [DB-FUZZY] Possible duplicate: \'{fname}\' matches existing track:',
                                f'  AI Artist: {artist}',
                                f'  AI Title:  {title}',
                                f'  Existing:  {db_artist} - {db_title}',
                                f'  Path:      {db_path}',
                                f'  Linked this filename to the existing track. Skipping import!'
                            ],
                            'color': YELLOW
                        })
                        print_debug_box(debug_sections)
                    else:
                        log(f"{YELLOW}{BOLD}[DB-FUZZY]{NC} Possible duplicate: '{fname}' matches existing track:\n  AI Artist: {CYAN}{artist}{NC}\n  AI Title:  {CYAN}{title}{NC}\n  Existing:  {LIGHT_GREEN}{db_artist} - {db_title}{NC}\n  Path:      {db_path}\n  {YELLOW}Linked this filename to the existing track. Skipping import!{NC}", level="WARNING")
                    continue

            use_as_is, llm_artist, llm_title = None, None, None
            if (USE_OLLAMA or USE_OPENAI) and not dry_run:
                if debug:
                    debug_sections.append({
                        'header': f'{MAGENTA}[DEBUG] [LLM INPUT]{NC}',
                        'lines': [
                            f'Filename: {os.path.basename(fpath)}',
                            f'Artist:   {artist}' if artist else '',
                            f'Title:    {title}' if title else ''
                        ],
                        'color': MAGENTA
                    })
                if USE_OLLAMA:
                    use_as_is, llm_artist, llm_title = query_ollama_for_metadata(
                        os.path.basename(fpath),
                        existing_artist=artist,
                        existing_title=title,
                        debug=debug
                    )
                    if debug:
                        debug_sections.append({
                            'header': f'{CYAN}[LLM] [DEBUG] Ollama raw response:{NC}',
                            'lines': [
                                f'{use_as_is}, {llm_artist}, {llm_title}'
                            ],
                            'color': CYAN
                        })
                        debug_sections.append({
                            'header': f'{MAGENTA}[DEBUG] [LLM OUTPUT - OLLAMA]{NC}',
                            'lines': [
                                f'use_as_is: {use_as_is}',
                                f'artist:    {llm_artist}',
                                f'title:     {llm_title}'
                            ],
                            'color': MAGENTA
                        })
                    if use_as_is:
                        debug_sections.append({'header': None, 'lines': [f'[LLM] LLM (Ollama) says to use as is: {fpath}'], 'color': CYAN})
                    elif llm_artist and llm_title:
                        artist = llm_artist
                        title = llm_title
                        debug_sections.append({'header': None, 'lines': [f"[LLM] LLM (Ollama) extracted: artist='{artist}', title='{title}' for {fpath}"], 'color': CYAN})
                if USE_OPENAI and (not use_as_is and not (llm_artist and llm_title)):
                    use_as_is, llm_artist, llm_title = query_openai_for_metadata(
                        os.path.basename(fpath),
                        existing_artist=artist,
                        existing_title=title,
                        debug=debug
                    )
                    if debug:
                        debug_sections.append({
                            'header': f'{CYAN}[LLM] [DEBUG] OpenAI raw response:{NC}',
                            'lines': [
                                f'use_as_is: {use_as_is}, artist: {llm_artist}, title: {llm_title}'
                            ],
                            'color': CYAN
                        })
                        debug_sections.append({
                            'header': f'{MAGENTA}[DEBUG] [LLM OUTPUT - OPENAI]{NC}',
                            'lines': [
                                f'use_as_is: {use_as_is}',
                                f'artist:    {llm_artist}',
                                f'title:     {llm_title}'
                            ],
                            'color': MAGENTA
                        })
                    if use_as_is:
                        debug_sections.append({'header': None, 'lines': [f'[LLM] LLM (OpenAI) says to use as is: {fpath}'], 'color': CYAN})
                    elif llm_artist and llm_title:
                        artist = llm_artist
                        title = llm_title
                        debug_sections.append({'header': None, 'lines': [f"[LLM] LLM (OpenAI) extracted: artist='{artist}', title='{title}' for {fpath}"], 'color': CYAN})
                # After LLM, check for deduplication
                ext = os.path.splitext(fname)[1].lower()
                main_artist = artist.split(';')[0].strip() if artist else "Unknown_Artist"
                safe_artist = sanitize_filename(main_artist) if main_artist else "Unknown_Artist"
                safe_title = sanitize_filename(title) if title else "Unknown_Title"
                dest_dir = os.path.join(dest, safe_artist)
                dest_path = os.path.join(dest_dir, f"{safe_title}{ext}")
                duplicate_found = False
                if os.path.exists(dest_dir):
                    existing_files = [f for f in os.listdir(dest_dir) if os.path.splitext(f)[1].lower() in AUDIO_EXTS]
                    norm_title = normalize_string(title) if title else "unknown_title"
                    for f in existing_files:
                        f_title, f_ext = os.path.splitext(f)
                        f_norm_title = normalize_string(f_title)
                        if f_norm_title == norm_title:
                            duplicate_found = True
                            break
                if duplicate_found:
                    debug_sections.append({'header': None, 'lines': [f"[WARNING] [SKIP] Duplicate found for artist '{main_artist}' and title '{title}', skipping."], 'color': YELLOW})
                    insert_db_skipped(fname, "duplicate")
                    print_debug_box(debug_sections)
                    continue
            elif dry_ai:
                # Only query the AI and print what would be done
                if USE_OLLAMA:
                    use_as_is, llm_artist, llm_title = query_ollama_for_metadata(
                        os.path.basename(fpath),
                        existing_artist=artist,
                        existing_title=title,
                        debug=debug
                    )
                elif USE_OPENAI:
                    use_as_is, llm_artist, llm_title = query_openai_for_metadata(
                        os.path.basename(fpath),
                        existing_artist=artist,
                        existing_title=title,
                        debug=debug
                    )
                if debug:
                    debug_sections.append({
                        'header': f'{MAGENTA}[DEBUG] [LLM OUTPUT - DRY-AI]{NC}',
                        'lines': [
                            f'use_as_is: {use_as_is}',
                            f'artist:    {llm_artist}',
                            f'title:     {llm_title}'
                        ],
                        'color': MAGENTA
                    })
                if use_as_is:
                    debug_sections.append({'header': None, 'lines': [f"[DRY-AI] Would use as is: {fpath} -> {os.path.join(dest, artist if artist else 'Unknown_Artist', fname)}"], 'color': YELLOW})
                elif llm_artist and llm_title:
                    ext = os.path.splitext(fname)[1].lower()
                    base_name = f"{llm_title}"
                    dest_dir = os.path.join(dest, llm_artist if llm_artist else "Unknown_Artist")
                    dest_path = os.path.join(dest_dir, f"{base_name}{ext}")
                    debug_sections.append({'header': None, 'lines': [f"[DRY-AI] Would copy: {fpath} -> {dest_path} (artist='{llm_artist}', title='{llm_title}')"], 'color': YELLOW})
                else:
                    debug_sections.append({'header': None, 'lines': [f"[DRY-AI] Would move to _Unsorted: {fpath}"], 'color': YELLOW})
                print_debug_box(debug_sections)
                continue

            ext = os.path.splitext(fname)[1].lower()
            # Always use sanitized AI output for naming
            main_artist = artist.split(';')[0].strip() if artist else "Unknown_Artist"
            safe_artist = sanitize_filename(main_artist) if main_artist else "Unknown_Artist"
            safe_title = sanitize_filename(title) if title else "Unknown_Title"
            dest_dir = os.path.join(dest, safe_artist)
            dest_path = os.path.join(dest_dir, f"{safe_title}{ext}")

            # Deduplication: check for duplicates using normalization, but do not use normalized names for naming
            duplicate_found = False
            if os.path.exists(dest_dir):
                existing_files = [f for f in os.listdir(dest_dir) if os.path.splitext(f)[1].lower() in AUDIO_EXTS]
                norm_title = normalize_string(title) if title else "unknown_title"
                for f in existing_files:
                    f_title, f_ext = os.path.splitext(f)
                    f_norm_title = normalize_string(f_title)
                    if f_norm_title == norm_title:
                        duplicate_found = True
                        break
            if duplicate_found:
                log(f"[SKIP] Duplicate found for artist '{main_artist}' and title '{title}', skipping.", level="WARNING")
                insert_db_skipped(fname, "duplicate")
                continue

            if use_as_is:
                if os.path.exists(dest_path):
                    log(f"[SKIP] {dest_path} already exists, skipping.", level="WARNING")
                    continue
                if dry_run:
                    log(f"Would copy: {fpath} -> {dest_path}", level="DRY")
                else:
                    if not os.path.exists(dest_dir):
                        os.makedirs(dest_dir, exist_ok=True)
                    shutil.copy2(fpath, dest_path)
                    log(f"{fpath} -> {dest_path}", level="COPIED")
                    # Update metadata after copy (unchanged)
                    try:
                        audio = MutagenFile(dest_path, easy=True)
                        main_artist = artist.split(';')[0].strip() if artist else ""
                        all_artists_str = artist if artist else ""
                        all_artists_list = [all_artists_str] if all_artists_str else []
                        if audio is not None:
                            if ext == ".mp3":
                                try:
                                    tags = EasyID3(dest_path)
                                except ID3NoHeaderError:
                                    tags = EasyID3()
                                    tags.save(dest_path)
                                    tags = EasyID3(dest_path)
                                tags["artist"] = main_artist
                                tags["title"] = title if title else ""
                                tags.save(dest_path)
                                from mutagen.id3 import ID3
                                from mutagen.id3._frames import TXXX
                                id3 = ID3(dest_path)
                                id3.add(TXXX(encoding=3, desc="ARTISTS", text=all_artists_list))
                                id3.save(dest_path)
                            elif ext in [".flac", ".ogg", ".opus"]:
                                audio["artist"] = all_artists_list
                                audio["artists"] = all_artists_list
                                audio["title"] = title if title else ""
                                audio.save()
                            elif ext == ".m4a":
                                try:
                                    mp4audio = MP4(dest_path)
                                    mp4audio["\xa9ART"] = [main_artist]
                                    mp4audio["\xa9nam"] = [title if title else ""]
                                    mp4audio["aART"] = [main_artist]
                                    mp4audio.save()
                                    if len(all_artists_list) > 1:
                                        log(f"[M4A] Only main artist is supported for m4a files. All artists: {all_artists_str}", level="WARNING")
                                except Exception as e:
                                    log(f"[M4A] Failed to set artist for m4a: {e}", level="ERROR")
                            else:
                                audio["artist"] = main_artist
                                audio["title"] = title if title else ""
                                audio.save()
                    except Exception as e:
                        log(f"Failed to update metadata for {dest_path}: {e}", level="ERROR")
                if debug:
                    time.sleep(1)
                continue

            if not (artist and title):
                UNSORTED_DIR = os.path.join(dest, "_Unsorted")
                unsorted_dest = os.path.join(UNSORTED_DIR, os.path.basename(fpath))
                if dry_run or dry_ai:
                    log(f"Would move to _Unsorted: {fpath}", level="DRY")
                else:
                    if not os.path.exists(UNSORTED_DIR):
                        os.makedirs(UNSORTED_DIR, exist_ok=True)
                    shutil.copy2(fpath, unsorted_dest)
                    log(f"{fpath} -> {unsorted_dest} : LLM failed to extract metadata", level="UNSORTED")
                    insert_db_skipped(fname, "no_metadata")
                if debug:
                    time.sleep(1)
                continue

            if os.path.exists(dest_path):
                log(f"[SKIP] {dest_path} already exists, skipping.", level="WARNING")
                continue
            if dry_run:
                log(f"Would copy: {fpath} -> {dest_path}", level="DRY")
            else:
                if not os.path.exists(dest_dir):
                    os.makedirs(dest_dir, exist_ok=True)
                shutil.copy2(fpath, dest_path)
                log(f"{fpath} -> {dest_path}", level="COPIED")
                # Update metadata after copy (unchanged)
                try:
                    audio = MutagenFile(dest_path, easy=True)
                    main_artist = artist.split(';')[0].strip() if artist else ""
                    all_artists_str = artist if artist else ""
                    all_artists_list = [all_artists_str] if all_artists_str else []
                    if audio is not None:
                        if ext == ".mp3":
                            try:
                                tags = EasyID3(dest_path)
                            except ID3NoHeaderError:
                                tags = EasyID3()
                                tags.save(dest_path)
                                tags = EasyID3(dest_path)
                            tags["artist"] = main_artist
                            tags["title"] = title if title else ""
                            tags.save(dest_path)
                            from mutagen.id3 import ID3
                            from mutagen.id3._frames import TXXX
                            id3 = ID3(dest_path)
                            id3.add(TXXX(encoding=3, desc="ARTISTS", text=all_artists_list))
                            id3.save(dest_path)
                        elif ext in [".flac", ".ogg", ".opus"]:
                            audio["artist"] = all_artists_list
                            audio["artists"] = all_artists_list
                            audio["title"] = title if title else ""
                            audio.save()
                        elif ext == ".m4a":
                            try:
                                mp4audio = MP4(dest_path)
                                mp4audio["\xa9ART"] = [main_artist]
                                mp4audio["\xa9nam"] = [title if title else ""]
                                mp4audio["aART"] = [main_artist]
                                mp4audio.save()
                                if len(all_artists_list) > 1:
                                    log(f"[M4A] Only main artist is supported for m4a files. All artists: {all_artists_str}", level="WARNING")
                            except Exception as e:
                                log(f"[M4A] Failed to set artist for m4a: {e}", level="ERROR")
                        else:
                            audio["artist"] = main_artist
                            audio["title"] = title if title else ""
                            audio.save()
                except Exception as e:
                    log(f"Failed to update metadata for {dest_path}: {e}", level="ERROR")
            if debug:
                time.sleep(1)

            # DB deduplication: check for fuzzy match on AI artist/title
            fuzzy_match = check_db_fuzzy(artist, title, threshold=0.95)
            if fuzzy_match:
                db_artist, db_title, db_path = fuzzy_match
                # Insert the current original filename as a linked duplicate
                insert_db(fname, db_artist, db_title, db_path)
                log(f"{YELLOW}{BOLD}[DB-FUZZY]{NC} Possible duplicate: '{fname}' matches existing track:\n  AI Artist: {CYAN}{artist}{NC}\n  AI Title:  {CYAN}{title}{NC}\n  Existing:  {LIGHT_GREEN}{db_artist} - {db_title}{NC}\n  Path:      {db_path}\n  {YELLOW}Linked this filename to the existing track. Skipping import!{NC}", level="WARNING")
                continue

            # After successful copy, insert into DB
            insert_db(fname, artist, title, dest_path)
            if debug:
                debug_sections.append({
                    'header': f'{LIGHT_GREEN}[DEBUG] [DB-IMPORT] Inserted into DB:{NC}',
                    'lines': [
                        f'Filename: {fname}',
                        f'Artist:   {artist}',
                        f'Title:    {title}',
                        f'Path:     {dest_path}'
                    ],
                    'color': LIGHT_GREEN
                })
                print_debug_box(debug_sections)
            log(f"{LIGHT_GREEN}{BOLD}[DB]{NC} Imported: {CYAN}{fname}{NC} as {LIGHT_GREEN}{artist} - {title}{NC} -> {CYAN}{dest_path}{NC}", level="SUCCESS")

    sys.exit(exit_code)

if __name__ == "__main__":
    init_db()
    main() 
