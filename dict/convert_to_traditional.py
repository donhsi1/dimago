#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Convert Simplified Chinese to Traditional Chinese
- Reads from thai_dict.db
- Creates dict_tw.db with only Traditional Chinese field
"""

import sqlite3
import os
from pathlib import Path

# ============== Configuration ==============
SCRIPT_DIR = Path(__file__).parent
SRC_DB = SCRIPT_DIR / "thai_dict.db"
DEST_DB = SCRIPT_DIR / "dict_tw.db"

# Try to import opencc for conversion, fallback to manual mapping
try:
    import opencc
    converter = opencc.OpenCC('s2t')  # Simplified to Traditional
    def to_traditional(simp):
        if simp:
            return converter.convert(simp)
        return simp
    USE_OPENCC = True
except ImportError:
    print("Note: 'opencc' not installed, using manual character mapping.")
    print("To install: pip install opencc-python")
    USE_OPENCC = False
    
    # Simple manual mapping for common Simplified -> Traditional
    SIMP_TO_TRAD = {
        '对': '對', '为': '為', '开': '開', '无': '無', '过': '過',
        '时': '時', '见': '見', '现': '現', '学': '學', '认': '認',
        '长': '長', '电': '電', '业': '業', '东': '東', '车': '車',
        '号': '號', '关': '關', '应': '應', '声': '聲', '会': '會',
        '语': '語', '动': '動', '变': '變', '节': '節', '产': '產',
        '馆': '館', '机': '機', '务': '務', '当': '當', '质': '質',
        '员': '員', '体': '體', '进': '進', '远': '遠', '运': '運',
        '还': '還', '连': '連', '适': '適', '里': '裡', '时间': '時間',
        '读': '讀', '写': '寫', '书': '書', '经': '經', '结': '結',
        '给': '給', '论': '論', '设': '設', '场': '場', '处': '處',
        '总': '總', '网': '網', '请': '請', '况': '況', '极': '極',
        '务': '務', '单': '單', '导': '導', '复': '複', '据': '據',
        '比': '比', '义': '義', '区': '區', '达': '達', '被': '被',
        '众': '眾', '传': '傳', '众': '眾', '从': '從', '向': '向',
        '告': '告', '命': '命', '商': '商', '国': '國', '际': '際',
        '内': '內', '容': '容', '际': '際', '制': '製', '统': '統',
        '际': '際', '际': '際', '际': '際',
    }
    
    def to_traditional(simp):
        if not simp:
            return simp
        result = simp
        for key, val in SIMP_TO_TRAD.items():
            result = result.replace(key, val)
        return result

# ============== Main Functions ==============

def create_traditional_db():
    """Create new database with Traditional Chinese content"""
    
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
    
    # Create table with only Traditional Chinese
    dest_cursor.execute('''
        CREATE TABLE traditional_chinese (
            id INTEGER PRIMARY KEY,
            traditional TEXT
        )
    ''')
    
    # Read all data from source
    src_cursor.execute("SELECT id, chinese FROM dictionary")
    rows = src_cursor.fetchall()
    
    total = len(rows)
    converted = 0
    
    print(f"Converting {total} rows to Traditional Chinese...")
    
    for row in rows:
        simp_chinese = row['chinese'] or ''
        trad_chinese = to_traditional(simp_chinese)
        
        dest_cursor.execute(
            "INSERT INTO traditional_chinese (id, traditional) VALUES (?, ?)",
            (row['id'], trad_chinese)
        )
        
        if trad_chinese and trad_chinese != simp_chinese:
            converted += 1
    
    dest_conn.commit()
    
    # Close connections
    src_conn.close()
    dest_conn.close()
    
    print(f"Done! Created: {DEST_DB}")
    print(f"Converted {converted} rows with character differences.")
    
    # Show sample
    show_sample()
    
    return True

def show_sample():
    """Display sample of converted data"""
    conn = sqlite3.connect(DEST_DB)
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM traditional_chinese LIMIT 20")
    rows = cursor.fetchall()
    
    print("\n" + "="*60)
    print("Sample Data (First 20 rows):")
    print("="*60)
    print(f"{'ID':<5} {'Traditional Chinese':<30}")
    print("-"*60)
    
    for row in rows:
        trad = row[1] or ''
        print(f"{row[0]:<5} {trad:<30}")
    
    conn.close()

# ============== Main ==============

def main():
    print("="*60)
    print("Thai Dictionary - Convert to Traditional Chinese")
    print("="*60)
    print(f"\nSource: {SRC_DB}")
    print(f"Output: {DEST_DB}")
    
    if not USE_OPENCC:
        print("\nUsing manual character mapping (limited conversion).")
    
    create_traditional_db()

if __name__ == "__main__":
    main()
