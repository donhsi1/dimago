#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Add Chinese Romanization (拼音) to database
- Adds 'chinese_roman' column to database
- Generates pinyin romanization for Chinese text
- Uses pypinyin library for accurate Chinese pinyin conversion
"""

import sqlite3
import os
import sys
from pathlib import Path

# ============== Configuration ==============
SCRIPT_DIR = Path(__file__).parent
DB_FILE = SCRIPT_DIR / "thai_dict.db"

# Try to import pypinyin, install if not available
try:
    from pypinyin import lazy_pinyin
except ImportError:
    print("Installing pypinyin...")
    os.system("pip install pypinyin")
    from pypinyin import lazy_pinyin

# ============== Database Functions ==============

def add_chinese_roman_column():
    """Add chinese_roman column to database if not exists"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Check if column exists
    cursor.execute("PRAGMA table_info(dictionary)")
    columns = [row[1] for row in cursor.fetchall()]
    
    if 'chinese_roman' not in columns:
        cursor.execute("ALTER TABLE dictionary ADD COLUMN chinese_roman TEXT")
        print("Added 'chinese_roman' column to database.")
    else:
        print("'chinese_roman' column already exists.")
    
    conn.commit()
    conn.close()

def generate_pinyin(chinese_text):
    """Generate pinyin romanization from Chinese text"""
    if not chinese_text or not chinese_text.strip():
        return ""
    
    try:
        # Generate pinyin for Chinese text
        pinyin_list = lazy_pinyin(chinese_text)
        return ''.join(pinyin_list)
    except Exception as e:
        print(f"Error generating pinyin for '{chinese_text}': {e}")
        return ""

def update_all_pinyin():
    """Read all data and generate pinyin for Chinese column"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Get all rows
    cursor.execute("SELECT id, chinese FROM dictionary WHERE chinese IS NOT NULL AND chinese != ''")
    rows = cursor.fetchall()
    
    total = len(rows)
    print(f"Processing {total} rows to generate pinyin...")
    
    for i, (row_id, chinese) in enumerate(rows):
        if chinese:
            pinyin = generate_pinyin(chinese)
            cursor.execute("UPDATE dictionary SET chinese_roman=? WHERE id=?", (pinyin, row_id))
            
            if (i + 1) % 10 == 0:
                conn.commit()
                print(f"Progress: {i+1}/{total}")
    
    conn.commit()
    conn.close()
    print(f"Completed! Generated pinyin for {total} rows.")

def display_sample():
    """Display sample of updated data"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    cursor.execute("SELECT id, thai, chinese, chinese_roman FROM dictionary LIMIT 20")
    rows = cursor.fetchall()
    
    print("\n" + "="*80)
    print("Sample Data (First 20 rows):")
    print("="*80)
    print(f"{'ID':<5} {'Chinese':<20} {'Pinyin':<25}")
    print("-"*50)
    
    for row in rows:
        chinese = row[2] or ''
        pinyin = row[3] or ''
        print(f"{row[0]:<5} {chinese:<20} {pinyin:<25}")
    
    conn.close()

# ============== Main ==============

def main():
    print("="*60)
    print("Thai Dictionary - Adding Chinese Romanization (拼音)")
    print("="*60)
    
    # Step 1: Add column
    print("\nStep 1: Adding 'chinese_roman' column...")
    add_chinese_roman_column()
    
    # Step 2: Generate pinyin for all Chinese text
    print("\nStep 2: Generating pinyin for Chinese text...")
    update_all_pinyin()
    
    # Step 3: Display sample
    display_sample()
    
    print("\nDone! The database now includes Chinese romanization (拼音).")

if __name__ == "__main__":
    main()
