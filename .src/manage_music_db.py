#!/usr/bin/env python3
"""
manage_music_db.py

Simple CLI tool to view and manage the music import database.

Usage:
  python manage_music_db.py <db_path>

Features:
- Show all entries in a formatted table.
- Search by artist or title and delete a selected entry.

"""
import sys
import sqlite3
import os
from tabulate import tabulate

DB_TABLE = 'imports'


def print_table(rows, headers):
    if not rows:
        print("No entries found.")
        return
    print(tabulate(rows, headers=headers, tablefmt="fancy_grid", showindex=True))


def show_db(db_path):
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute(f'SELECT id, original_name, ai_artist, ai_title, storage_path, date_added FROM {DB_TABLE}')
    rows = c.fetchall()
    headers = ["ID", "Original Filename", "AI Artist", "AI Title", "Storage Path", "Date Added"]
    print_table(rows, headers)
    conn.close()


def search_and_delete(db_path):
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    term = input("Search for artist or title: ").strip()
    if not term:
        print("No search term entered.")
        return
    c.execute(f'''SELECT id, original_name, ai_artist, ai_title, storage_path, date_added FROM {DB_TABLE} \
                 WHERE ai_artist LIKE ? OR ai_title LIKE ?''', (f'%{term}%', f'%{term}%'))
    rows = c.fetchall()
    headers = ["ID", "Original Filename", "AI Artist", "AI Title", "Storage Path", "Date Added"]
    if not rows:
        print("No matches found.")
        return
    print_table(rows, headers)
    if len(rows) == 1:
        entry_id = rows[0][0]
        yn = input(f"Delete this entry? (y/N or 0 to delete): ").strip().lower()
        if yn == 'y' or yn == 'yes' or yn == '0':
            c.execute(f'DELETE FROM {DB_TABLE} WHERE id = ?', (entry_id,))
            conn.commit()
            print("Entry deleted.")
        else:
            print("Cancelled.")
        conn.close()
        return
    try:
        idx = int(input("Enter the index of the entry to delete (or blank to cancel): ").strip())
    except ValueError:
        print("Cancelled.")
        return
    if idx < 0 or idx >= len(rows):
        print("Invalid index.")
        return
    entry_id = rows[idx][0]
    confirm = input(f"Are you sure you want to delete entry ID {entry_id}? (y/N): ").strip().lower()
    if confirm == 'y':
        c.execute(f'DELETE FROM {DB_TABLE} WHERE id = ?', (entry_id,))
        conn.commit()
        print("Entry deleted.")
    else:
        print("Cancelled.")
    conn.close()


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <db_path> [--delete]")
        sys.exit(1)
    db_path = sys.argv[1]
    if not os.path.exists(db_path):
        print(f"Database file not found: {db_path}")
        sys.exit(2)
    if len(sys.argv) > 2 and sys.argv[2] == '--delete':
        search_and_delete(db_path)
    else:
        show_db(db_path)

if __name__ == "__main__":
    try:
        from tabulate import tabulate
    except ImportError:
        print("Please install the 'tabulate' package: pip install tabulate")
        sys.exit(1)
    main() 