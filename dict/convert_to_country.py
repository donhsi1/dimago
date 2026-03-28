#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Translate to Multiple Languages
- Reads from thai_dict.db
- Translates English to multiple languages
- Creates dict_country.db database
Supported languages: German, French, Spanish, Italian, Russian, Ukrainian, Hebrew, Japanese, Korean
"""

import sqlite3
import json
import time
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

# ============== Configuration ==============
SCRIPT_DIR = Path(__file__).parent
SRC_DB = SCRIPT_DIR / "thai_dict.db"
DEST_DB = SCRIPT_DIR / "dict_country.db"

# Supported languages with their Google Translate codes
LANGUAGES = {
    'german': 'de',
    'french': 'fr',
    'spanish': 'es',
    'italian': 'it',
    'russian': 'ru',
    'ukrainian': 'uk',
    'hebrew': 'he',
    'japanese': 'ja',
    'korean': 'ko'
}

# ============== Google Translate API ==============

def translate_text(text, target_lang, retries=3):
    """Translate text to target language using Google Translate API"""
    if not text or not text.strip():
        return ""
    
    url = 'https://translate.googleapis.com/translate_a/single'
    params = {
        'client': 'gtx',
        'sl': 'en',
        'tl': target_lang,
        'dt': 't',
        'q': text
    }
    
    url = url + '?' + urllib.parse.urlencode(params)
    
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                result = json.loads(response.read().decode('utf-8'))
                translation = ''
                for item in result[0]:
                    if item[0]:
                        translation += item[0]
                return translation
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(1)
            else:
                print(f"Translation failed for '{text[:30]}...' -> {target_lang}: {e}")
                return ""

# ============== Database Functions ==============

def create_country_db():
    """Create database with translations in multiple languages"""
    
    if not SRC_DB.exists():
        print(f"Error: Source database not found: {SRC_DB}")
        return False
    
    # Connect to source database
    src_conn = sqlite3.connect(SRC_DB)
    src_conn.row_factory = sqlite3.Row
    src_cursor = src_conn.cursor()
    
    # Create destination database
    if DEST_DB.exists():
        DEST_DB.unlink()
    
    dest_conn = sqlite3.connect(DEST_DB)
    dest_cursor = dest_conn.cursor()
    
    # Build dynamic table creation based on languages
    columns_sql = ["id INTEGER PRIMARY KEY"]
    columns_sql.append("english TEXT")
    for lang_name in LANGUAGES.keys():
        columns_sql.append(f"{lang_name} TEXT")
    
    create_sql = f"CREATE TABLE translations ({', '.join(columns_sql)})"
    dest_cursor.execute(create_sql)
    
    # Get all English text from source
    src_cursor.execute("SELECT id, english FROM dictionary WHERE english IS NOT NULL AND english != ''")
    rows = src_cursor.fetchall()
    
    total = len(rows)
    print(f"Found {total} rows to translate.")
    print(f"Target languages: {', '.join(LANGUAGES.keys())}")
    print()
    
    for i, row in enumerate(rows):
        row_id = row['id']
        english = row['english'] or ''
        
        translations = {'english': english}
        
        # Translate to each language
        for lang_name, lang_code in LANGUAGES.items():
            translation = translate_text(english, lang_code)
            translations[lang_name] = translation
            
            # Small delay to avoid rate limiting
            time.sleep(0.1)
        
        # Insert into destination database
        values = [row_id, english]
        values.extend([translations.get(lang, '') for lang in LANGUAGES.keys()])
        placeholders = ', '.join(['?'] * (2 + len(LANGUAGES)))
        dest_cursor.execute(
            f"INSERT INTO translations ({', '.join(['id', 'english'] + list(LANGUAGES.keys()))}) VALUES ({placeholders})",
            values
        )
        
        # Progress report every 10 rows
        if (i + 1) % 10 == 0:
            dest_conn.commit()
            print(f"Progress: {i+1}/{total} rows completed...")
    
    dest_conn.commit()
    
    # Close connections
    src_conn.close()
    dest_conn.close()
    
    print(f"\nDone! Created: {DEST_DB}")
    
    # Show sample
    show_sample()
    
    return True

def show_sample():
    """Display sample of translated data"""
    conn = sqlite3.connect(DEST_DB)
    cursor = conn.cursor()
    
    cursor.execute("SELECT * FROM translations LIMIT 5")
    rows = cursor.fetchall()
    
    # Get column names
    cursor.execute("PRAGMA table_info(translations)")
    columns = [row[1] for row in cursor.fetchall()]
    
    print("\n" + "="*120)
    print("Sample Data (First 5 rows):")
    print("="*120)
    
    # Print header
    header = f"{'ID':<5}"
    for col in columns[1:]:
        header += f" | {col:<15}"
    print(header)
    print("-"*120)
    
    # Print rows
    for row in rows:
        row_str = f"{row[0]:<5}"
        for val in row[1:]:
            display = str(val)[:15] if val else ''
            row_str += f" | {display:<15}"
        print(row_str)
    
    conn.close()

# ============== Main ==============

def main():
    print("="*80)
    print("Thai Dictionary - Multi-Language Translation")
    print("="*80)
    print(f"\nSource: {SRC_DB}")
    print(f"Output: {DEST_DB}")
    print(f"\nLanguages: {', '.join(LANGUAGES.keys())}")
    print("\nNote: This will translate all English text to 9 different languages.")
    print("      This may take a few minutes...")
    
    response = input("\nContinue? (y/n): ").strip().lower()
    if response != 'y':
        print("Cancelled.")
        return
    
    create_country_db()

if __name__ == "__main__":
    main()
