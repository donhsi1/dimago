#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Thai Dictionary Viewer
- Reads dictionary.json and stores data in SQLite database
- Translates English to Chinese via Google API
- Displays data in an Excel-like grid view on Windows
"""

import json
import os
import sqlite3
import sys
import urllib.request
import urllib.parse
import urllib.error
import time
from pathlib import Path
from tkinter import *
from tkinter import ttk, messagebox, filedialog

# ============== Configuration ==============
SCRIPT_DIR = Path(__file__).parent
JSON_FILE = SCRIPT_DIR / "dictionary.json"
DB_FILE = SCRIPT_DIR / "thai_dict.db"

# ============== Google Translate API ==============

def translate_to_chinese(text, retries=3):
    """Translate English text to Chinese using Google Translate API"""
    if not text or not text.strip():
        return ""
    
    url = 'https://translate.googleapis.com/translate_a/single'
    params = {
        'client': 'gtx',
        'sl': 'en',
        'tl': 'zh-CN',
        'dt': 't',
        'q': text
    }
    
    url = url + '?' + urllib.parse.urlencode(params)
    
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                result = json.loads(response.read().decode('utf-8'))
                # result[0] contains the translation
                translation = ''
                for item in result[0]:
                    if item[0]:
                        translation += item[0]
                return translation
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(1)  # Wait before retry
            else:
                print(f"Translation failed for '{text}': {e}")
                return ""

# ============== Database Functions ==============

def init_database():
    """Initialize SQLite database and create table"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Create table if not exists
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS dictionary (
            id INTEGER PRIMARY KEY,
            thai TEXT NOT NULL,
            roman TEXT,
            english TEXT,
            chinese TEXT,
            category TEXT
        )
    ''')
    
    # Add chinese column if it doesn't exist (for existing databases)
    try:
        cursor.execute("ALTER TABLE dictionary ADD COLUMN chinese TEXT")
    except sqlite3.OperationalError:
        pass  # Column already exists
    
    conn.commit()
    return conn

def import_json_to_db(show_progress=True):
    """Import data from JSON file to SQLite database with translation"""
    if not JSON_FILE.exists():
        messagebox.showerror("Error", f"JSON file not found: {JSON_FILE}")
        return None
    
    try:
        with open(JSON_FILE, encoding='utf-8') as f:
            data = json.load(f)
        
        conn = init_database()
        cursor = conn.cursor()
        
        # Clear existing data
        cursor.execute("DELETE FROM dictionary")
        
        total = len(data)
        translated_count = 0
        
        for i, item in enumerate(data):
            english = item.get('english', '')
            
            # Translate English to Chinese
            chinese = translate_to_chinese(english)
            if chinese:
                translated_count += 1
            
            cursor.execute('''
                INSERT OR REPLACE INTO dictionary (id, thai, roman, english, chinese, category)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (item.get('id'), item.get('thai', ''), item.get('roman', ''), 
                  english, chinese, item.get('category', '')))
            
            # Save progress periodically
            if (i + 1) % 10 == 0:
                conn.commit()
                if show_progress:
                    print(f"Progress: {i+1}/{total} words translated...")
        
        conn.commit()
        conn.close()
        
        return total, translated_count
    except Exception as e:
        messagebox.showerror("Error", f"Failed to import JSON: {e}")
        return None

def get_all_words():
    """Retrieve all words from database"""
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM dictionary ORDER BY id")
    rows = cursor.fetchall()
    conn.close()
    return rows

def search_words(keyword):
    """Search words by Thai, Roman, English, Chinese, or Category"""
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute('''
        SELECT * FROM dictionary 
        WHERE thai LIKE ? OR roman LIKE ? OR english LIKE ? OR chinese LIKE ? OR category LIKE ?
        ORDER BY id
    ''', (f'%{keyword}%', f'%{keyword}%', f'%{keyword}%', f'%{keyword}%', f'%{keyword}%'))
    rows = cursor.fetchall()
    conn.close()
    return rows

def add_word(thai, roman, english, chinese, category):
    """Add a new word to the database"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Get next ID
    cursor.execute("SELECT MAX(id) FROM dictionary")
    max_id = cursor.fetchone()[0] or 0
    
    cursor.execute('''
        INSERT INTO dictionary (id, thai, roman, english, chinese, category)
        VALUES (?, ?, ?, ?, ?, ?)
    ''', (max_id + 1, thai, roman, english, chinese, category))
    
    conn.commit()
    conn.close()
    return max_id + 1

def update_word(word_id, thai, roman, english, chinese, category):
    """Update an existing word"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    cursor.execute('''
        UPDATE dictionary SET thai=?, roman=?, english=?, chinese=?, category=?
        WHERE id=?
    ''', (thai, roman, english, chinese, category, word_id))
    conn.commit()
    conn.close()

def delete_word(word_id):
    """Delete a word from the database"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    cursor.execute("DELETE FROM dictionary WHERE id=?", (word_id,))
    conn.commit()
    conn.close()

def export_db_to_json():
    """Export database to JSON file"""
    words = get_all_words()
    data = []
    for row in words:
        data.append({
            'id': row['id'],
            'thai': row['thai'],
            'roman': row['roman'],
            'english': row['english'],
            'chinese': row['chinese'],
            'category': row['category']
        })
    
    output_file = SCRIPT_DIR / "exported_dictionary.json"
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    return output_file

# ============== GUI Application ==============

class ThaiDictionaryApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Thai Dictionary Viewer - 泰语词典")
        self.root.geometry("1400x700")
        
        # Import data on startup
        self.import_on_startup()
        
        self.setup_ui()
        self.refresh_grid()
    
    def import_on_startup(self):
        """Import JSON and translate on startup"""
        if JSON_FILE.exists():
            print("Importing JSON and translating to Chinese...")
            result = import_json_to_db(show_progress=True)
            if result:
                total, translated = result
                print(f"Import complete: {total} words, {translated} translated to Chinese")
    
    def setup_ui(self):
        """Setup the user interface"""
        # Top toolbar
        toolbar = Frame(self.root)
        toolbar.pack(fill=X, padx=10, pady=5)
        
        # Search
        Label(toolbar, text="Search:").pack(side=LEFT, padx=5)
        self.search_entry = Entry(toolbar, width=30)
        self.search_entry.pack(side=LEFT, padx=5)
        Button(toolbar, text="Search", command=self.on_search).pack(side=LEFT, padx=5)
        Button(toolbar, text="Show All", command=self.refresh_grid).pack(side=LEFT, padx=5)
        
        # Import/Export buttons
        Button(toolbar, text="Re-import JSON", command=self.on_import).pack(side=RIGHT, padx=5)
        Button(toolbar, text="Export JSON", command=self.on_export).pack(side=RIGHT, padx=5)
        
        # Grid frame
        grid_frame = Frame(self.root)
        grid_frame.pack(fill=BOTH, expand=True, padx=10, pady=5)
        
        # Create Treeview (Excel-like grid)
        columns = ("id", "thai", "roman", "english", "chinese", "category")
        self.tree = ttk.Treeview(grid_frame, columns=columns, show="headings", height=25)
        
        # Configure columns
        self.tree.heading("id", text="ID")
        self.tree.heading("thai", text="Thai (泰文)")
        self.tree.heading("roman", text="Romanization (罗马拼音)")
        self.tree.heading("english", text="English (英文)")
        self.tree.heading("chinese", text="Chinese (中文)")
        self.tree.heading("category", text="Category (类别)")
        
        self.tree.column("id", width=50, anchor=CENTER)
        self.tree.column("thai", width=150)
        self.tree.column("roman", width=150)
        self.tree.column("english", width=200)
        self.tree.column("chinese", width=200)
        self.tree.column("category", width=100, anchor=CENTER)
        
        # Add scrollbars
        vsb = ttk.Scrollbar(grid_frame, orient="vertical", command=self.tree.yview)
        hsb = ttk.Scrollbar(grid_frame, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        
        # Grid layout
        self.tree.grid(row=0, column=0, sticky=N+S+E+W)
        vsb.grid(row=0, column=1, sticky=N+S)
        hsb.grid(row=1, column=0, sticky=E+W)
        grid_frame.columnconfigure(0, weight=1)
        grid_frame.rowconfigure(0, weight=1)
        
        # Bottom status bar
        self.status_label = Label(self.root, text="Ready", bd=1, relief=SUNKEN, anchor=W)
        self.status_label.pack(side=BOTTOM, fill=X)
        
        # Bind events
        self.tree.bind("<Double-1>", self.on_double_click)
    
    def refresh_grid(self, words=None):
        """Refresh the grid with data"""
        # Clear existing items
        for item in self.tree.get_children():
            self.tree.delete(item)
        
        # Get words from database if not provided
        if words is None:
            words = get_all_words()
        
        # Insert rows
        for word in words:
            self.tree.insert("", END, values=(
                word['id'],
                word['thai'],
                word['roman'],
                word['english'],
                word['chinese'] or '',
                word['category']
            ))
        
        self.status_label.config(text=f"Total: {len(words)} words | Database: {DB_FILE}")
    
    def on_search(self):
        """Handle search button click"""
        keyword = self.search_entry.get().strip()
        if keyword:
            words = search_words(keyword)
            self.refresh_grid(words)
        else:
            self.refresh_grid()
    
    def on_import(self):
        """Handle import button click"""
        result = import_json_to_db(show_progress=True)
        if result:
            total, translated = result
            messagebox.showinfo("Success", f"Successfully imported {total} words\n{translated} translated to Chinese")
            self.refresh_grid()
    
    def on_export(self):
        """Handle export button click"""
        output_file = export_db_to_json()
        messagebox.showinfo("Success", f"Database exported to: {output_file}")
    
    def on_double_click(self, event):
        """Handle double-click on a row"""
        # Get the item that was clicked
        region = self.tree.identify("region", event.x, event.y)
        if region != "cell":
            return
        
        # Get current values
        item = self.tree.identify_row(event.y)
        if not item:
            return
        
        values = self.tree.item(item, "values")
        
        # Create edit popup
        self.show_edit_popup(item, values)
    
    def show_edit_popup(self, item, values):
        """Show popup to edit a word"""
        popup = Toplevel(self.root)
        popup.title("Edit Word")
        popup.geometry("450x350")
        popup.transient(self.root)
        popup.grab_set()
        
        # Form fields
        labels = ["Thai:", "Romanization:", "English:", "Chinese:", "Category:"]
        entries = []
        
        for i, (label, value) in enumerate(zip(labels, values[1:])):  # Skip ID
            Label(popup, text=label, width=15, anchor=W).grid(row=i, column=0, padx=10, pady=5)
            entry = Entry(popup, width=40)
            entry.insert(0, value)
            entry.grid(row=i, column=1, padx=10, pady=5)
            entries.append(entry)
        
        def save_changes():
            thai = entries[0].get()
            roman = entries[1].get()
            english = entries[2].get()
            chinese = entries[3].get()
            category = entries[4].get()
            
            update_word(values[0], thai, roman, english, chinese, category)
            self.refresh_grid()
            popup.destroy()
        
        def translate_current():
            """Translate current English to Chinese"""
            english = entries[2].get()
            chinese = translate_to_chinese(english)
            entries[3].delete(0, END)
            entries[3].insert(0, chinese)
        
        def delete_word_action():
            if messagebox.askyesno("Confirm", f"Delete word '{values[1]}'?"):
                delete_word(values[0])
                self.refresh_grid()
                popup.destroy()
        
        # Buttons
        btn_frame = Frame(popup)
        btn_frame.grid(row=6, column=0, columnspan=2, pady=20)
        
        Button(btn_frame, text="Save", width=10, command=save_changes).pack(side=LEFT, padx=5)
        Button(btn_frame, text="Translate", width=10, command=translate_current).pack(side=LEFT, padx=5)
        Button(btn_frame, text="Delete", width=10, command=delete_word_action).pack(side=LEFT, padx=5)
        Button(btn_frame, text="Cancel", width=10, command=popup.destroy).pack(side=LEFT, padx=5)

# ============== Main Entry Point ==============

def main():
    root = Tk()
    app = ThaiDictionaryApp(root)
    root.mainloop()

if __name__ == "__main__":
    main()
