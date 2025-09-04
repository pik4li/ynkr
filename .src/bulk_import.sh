#!/bin/bash

# Bulk import script to prevent future AI queries
# This will add all files in the source directory to the database without processing them

if [ $# -eq 0 ]; then
    echo "Usage: $0 <source_directory>"
    echo "This will bulk import all files to the database to prevent future AI queries"
    exit 1
fi

SOURCE_DIR="$1"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist"
    exit 1
fi

echo "Bulk importing all files from '$SOURCE_DIR' to prevent future AI queries..."
echo "This will NOT process or copy any files, just add them to the database."
echo "Press Ctrl+C to cancel, or any key to continue..."
read -n 1 -s

python3 import.py "$SOURCE_DIR" --bulk-import

echo "Bulk import complete!"
echo "Now you can run the normal import script and it will skip all these files." 