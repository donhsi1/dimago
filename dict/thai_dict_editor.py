#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Thai Dictionary Excel Editor
- Reads from specified SQLite database and displays in Excel-like format
- Click on any cell to edit
- FILE menu with Save command to persist changes
- Usage: python thai_dict_editor.py [--file <db_file>]
"""

import sqlite3
import sys
import argparse
from pathlib import Path
from tkinter import *
from tkinter import ttk, messagebox, filedialog

# ============== Configuration ==============
SCRIPT_DIR = Path(__file__).parent
DEFAULT_DB = SCRIPT_DIR / "thai_dict.db"

# Global database file path
DB_FILE = None
TABLE_NAME = "dictionary"

# ============== Command Line Arguments ==============

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description="Thai Dictionary Excel Editor - Edit SQLite database in grid view",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python thai_dict_editor.py                           # Opens thai_dict.db
  python thai_dict_editor.py --file mydata.db          # Opens mydata.db
  python thai_dict_editor.py -f dict_tw.db             # Opens dict_tw.db
        """
    )
    parser.add_argument(
        '-f', '--file',
        type=str,
        default=None,
        help='Path to SQLite database file (default: thai_dict.db in script directory)'
    )
    parser.add_argument(
        '-t', '--table',
        type=str,
        default='dictionary',
        help='Table name to edit (default: dictionary)'
    )
    
    return parser.parse_args()

# ============== Database Functions ==============

def get_db_connection():
    """Get database connection"""
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn

def get_all_words():
    """Retrieve all words from database"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(f"SELECT * FROM {TABLE_NAME} ORDER BY id")
    rows = cursor.fetchall()
    conn.close()
    # Convert Row objects to dicts (to allow modification)
    return [dict(row) for row in rows]

def get_columns():
    """Get column names from database"""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(f"PRAGMA table_info({TABLE_NAME})")
    columns = [row[1] for row in cursor.fetchall()]
    conn.close()
    return columns

def save_all_changes(rows_data, columns):
    """Save all changes to database"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Build dynamic UPDATE statement based on columns
    set_clause = ', '.join([f"{col}=?" for col in columns if col != 'id'])
    update_sql = f"UPDATE {TABLE_NAME} SET {set_clause} WHERE id=?"
    
    for row in rows_data:
        values = [row[col] for col in columns if col != 'id']
        values.append(row['id'])
        cursor.execute(update_sql, values)
    
    conn.commit()
    conn.close()

def get_table_names():
    """Get list of tables in the database"""
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [row[0] for row in cursor.fetchall() if not row[0].startswith('sqlite_')]
    conn.close()
    return tables

# ============== GUI Application ==============

class ExcelEditor:
    def __init__(self, root, db_file, table_name='dictionary'):
        global DB_FILE, TABLE_NAME
        DB_FILE = db_file
        TABLE_NAME = table_name
        
        self.root = root
        self.root.title(f"Thai Dictionary Editor - {DB_FILE.name} [{TABLE_NAME}]")
        self.root.geometry("1200x600")
        
        # Data tracking
        self.columns = get_columns()
        self.data = get_all_words()
        self.edited_cells = {}  # {(row_idx, col_name): new_value}
        self.has_changes = False
        
        self.setup_ui()
        self.load_data()
    
    def setup_ui(self):
        """Setup the user interface"""
        # Create menu bar
        menubar = Menu(self.root)
        self.root.config(menu=menubar)
        
        # FILE menu
        file_menu = Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=file_menu)
        file_menu.add_command(label="Open...", command=self.open_file, accelerator="Ctrl+O")
        file_menu.add_command(label="Save", command=self.save_changes, accelerator="Ctrl+S")
        file_menu.add_separator()
        file_menu.add_command(label="Reload", command=self.reload_data)
        file_menu.add_separator()
        file_menu.add_command(label="Exit", command=self.on_exit)
        
        # Create main container
        main_frame = Frame(self.root)
        main_frame.pack(fill=BOTH, expand=True)
        
        # Create Treeview (Excel-like grid)
        display_columns = tuple(self.columns)
        self.tree = ttk.Treeview(main_frame, columns=display_columns, show="headings")
        
        # Configure columns
        col_widths = {
            'id': 50,
            'thai': 150,
            'roman': 150,
            'english': 200,
            'chinese': 200,
            'chinese_roman': 150,
            'traditional': 200,
            'category': 100
        }
        
        for col in self.columns:
            self.tree.heading(col, text=col.title())
            width = col_widths.get(col, 100)
            anchor = CENTER if col == 'id' or col == 'category' else W
            self.tree.column(col, width=width, anchor=anchor, minwidth=50)
        
        # Add scrollbars
        vsb = ttk.Scrollbar(main_frame, orient="vertical", command=self.tree.yview)
        hsb = ttk.Scrollbar(main_frame, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=vsb.set, xscrollcommand=hsb.set)
        
        # Grid layout
        self.tree.grid(row=0, column=0, sticky=N+S+E+W)
        vsb.grid(row=0, column=1, sticky=N+S)
        hsb.grid(row=1, column=0, sticky=E+W)
        main_frame.columnconfigure(0, weight=1)
        main_frame.rowconfigure(0, weight=1)
        
        # Bottom status bar
        self.status_label = Label(self.root, text="Ready", bd=1, relief=SUNKEN, anchor=W)
        self.status_label.pack(side=BOTTOM, fill=X)
        
        # Bind events
        self.tree.bind("<Double-1>", self.on_double_click)
        self.tree.bind("<Button-1>", self.on_cell_click)
        self.root.bind("<Control-s>", lambda e: self.save_changes())
        self.root.bind("<Control-o>", lambda e: self.open_file())
        self.root.protocol("WM_DELETE_WINDOW", self.on_exit)
    
    def load_data(self):
        """Load data into the grid"""
        # Clear existing items
        for item in self.tree.get_children():
            self.tree.delete(item)
        
        # Insert rows
        for row in self.data:
            values = [row[col] or '' for col in self.columns]
            self.tree.insert("", END, iid=str(row['id']), values=values)
        
        self.update_status()
    
    def on_cell_click(self, event):
        """Handle single click on a cell"""
        # Get the region that was clicked
        region = self.tree.identify("region", event.x, event.y)
        if region != "cell":
            return
        
        # Get column info
        column_id = self.tree.identify_column(event.x)
        column_name = self.columns[int(column_id.replace('#', '')) - 1]
        item_id = self.tree.identify_row(event.y)
        
        # Don't allow editing ID column
        if column_name == 'id':
            return
        
        # Show cell editor
        self.edit_cell(item_id, column_name)
    
    def on_double_click(self, event):
        """Handle double-click to edit"""
        region = self.tree.identify("region", event.x, event.y)
        if region != "cell":
            return
        
        column_id = self.tree.identify_column(event.x)
        column_name = self.columns[int(column_id.replace('#', '')) - 1]
        item_id = self.tree.identify_row(event.y)
        
        if column_name != 'id':
            self.edit_cell(item_id, column_name)
    
    def edit_cell(self, item_id, column_name):
        """Edit a specific cell"""
        # Get bounding box of the cell
        column_idx = self.columns.index(column_name) + 1
        x, y, width, height = self.tree.bbox(item_id, f"#{column_idx}")
        
        # Create entry widget
        entry = Entry(self.tree, width=width//8)
        entry.place(x=x, y=y, width=width, height=height)
        
        # Get current value
        current_values = self.tree.item(item_id, "values")
        current_value = current_values[self.columns.index(column_name)]
        entry.insert(0, current_value)
        
        # Focus on entry
        entry.focus_set()
        
        def on_entry_submit(e=None):
            """Handle entry submission"""
            new_value = entry.get()
            entry.destroy()
            
            # Check if value changed
            if new_value != current_value:
                # Update tree display
                new_values = list(current_values)
                new_values[self.columns.index(column_name)] = new_value
                self.tree.item(item_id, values=new_values)
                
                # Track change
                row_idx = int(item_id)
                self.edited_cells[(row_idx, column_name)] = new_value
                self.has_changes = True
                self.update_status()
        
        def on_entry_cancel(e):
            """Handle entry cancellation"""
            entry.destroy()
        
        entry.bind("<Return>", on_entry_submit)
        entry.bind("<Escape>", on_entry_cancel)
        entry.bind("<FocusOut>", on_entry_submit)
    
    def save_changes(self):
        """Save all changes to database"""
        if not self.has_changes:
            messagebox.showinfo("No Changes", "No changes to save.")
            return
        
        try:
            # Update data with edits
            editable_columns = [col for col in self.columns if col != 'id']
            for row in self.data:
                row_idx = row['id']
                for col_name in editable_columns:
                    if (row_idx, col_name) in self.edited_cells:
                        row[col_name] = self.edited_cells[(row_idx, col_name)]
            
            # Save to database
            save_all_changes(self.data, self.columns)
            
            # Clear tracking
            self.edited_cells = {}
            self.has_changes = False
            
            messagebox.showinfo("Success", "Changes saved to database!")
            self.update_status()
            
        except Exception as e:
            messagebox.showerror("Error", f"Failed to save: {e}")
    
    def open_file(self):
        """Open a new database file"""
        if self.has_changes:
            if not messagebox.askyesno("Unsaved Changes", 
                    "You have unsaved changes. Open another file will discard them. Continue?"):
                return
        
        filepath = filedialog.askopenfilename(
            title="Open Database",
            filetypes=[("SQLite Database", "*.db *.sqlite *.sqlite3"), ("All Files", "*.*")]
        )
        
        if filepath:
            # Get table names
            global DB_FILE, TABLE_NAME
            DB_FILE = Path(filepath)
            
            try:
                tables = get_table_names()
                if not tables:
                    messagebox.showerror("Error", "No tables found in database.")
                    return
                
                if len(tables) == 1:
                    TABLE_NAME = tables[0]
                else:
                    # Let user select table
                    table_win = Toplevel(self.root)
                    table_win.title("Select Table")
                    table_win.geometry("300x200")
                    
                    Label(table_win, text="Select a table:").pack(pady=10)
                    
                    selected_table = [None]
                    
                    for tbl in tables:
                        Button(table_win, text=tbl, width=20,
                               command=lambda t=tbl: selected_table.__setitem__(0, t) or table_win.destroy()
                               ).pack(pady=2)
                    
                    table_win.wait_window()
                    
                    if selected_table[0]:
                        TABLE_NAME = selected_table[0]
                    else:
                        return
                
                # Reload data
                self.columns = get_columns()
                self.data = get_all_words()
                self.edited_cells = {}
                self.has_changes = False
                
                # Recreate tree columns
                for col in self.tree['columns']:
                    self.tree.column(col, width=0)
                    self.tree.heading(col, text='')
                
                col_widths = {
                    'id': 50, 'thai': 150, 'roman': 150, 'english': 200,
                    'chinese': 200, 'chinese_roman': 150, 'traditional': 200, 'category': 100
                }
                
                self.tree['columns'] = tuple(self.columns)
                for col in self.columns:
                    self.tree.heading(col, text=col.title())
                    width = col_widths.get(col, 100)
                    anchor = CENTER if col == 'id' or col == 'category' else W
                    self.tree.column(col, width=width, anchor=anchor, minwidth=50)
                
                self.load_data()
                self.root.title(f"Thai Dictionary Editor - {DB_FILE.name} [{TABLE_NAME}]")
                
            except Exception as e:
                messagebox.showerror("Error", f"Failed to open database: {e}")
    
    def reload_data(self):
        """Reload data from database"""
        if self.has_changes:
            if not messagebox.askyesno("Unsaved Changes", 
                    "You have unsaved changes. Reload will discard them. Continue?"):
                return
        
        self.data = get_all_words()
        self.edited_cells = {}
        self.has_changes = False
        self.load_data()
        self.update_status()
    
    def update_status(self):
        """Update status bar"""
        total = len(self.data)
        edited = len(self.edited_cells)
        if self.has_changes:
            self.status_label.config(
                text=f"Total: {total} rows | {edited} cells edited (unsaved) | Press Ctrl+S to save | DB: {DB_FILE}")
            self.root.title(f"Thai Dictionary Editor - {DB_FILE.name} [{TABLE_NAME}] *")
        else:
            self.status_label.config(text=f"Total: {total} rows | All changes saved | DB: {DB_FILE}")
            self.root.title(f"Thai Dictionary Editor - {DB_FILE.name} [{TABLE_NAME}]")
    
    def on_exit(self):
        """Handle window close"""
        if self.has_changes:
            if not messagebox.askyesno("Unsaved Changes", 
                    "You have unsaved changes. Exit without saving?"):
                return
        self.root.destroy()

# ============== Main Entry Point ==============

def main():
    args = parse_args()
    
    # Determine database file
    global DB_FILE, TABLE_NAME
    if args.file:
        DB_FILE = Path(args.file)
        if not DB_FILE.exists():
            print(f"Error: Database file not found: {DB_FILE}")
            sys.exit(1)
    else:
        DB_FILE = DEFAULT_DB
        if not DB_FILE.exists():
            print(f"Error: Default database not found: {DB_FILE}")
            print("Please specify a database file with --file option.")
            sys.exit(1)
    
    TABLE_NAME = args.table
    
    # Check table exists
    try:
        tables = get_table_names()
        if TABLE_NAME not in tables:
            print(f"Warning: Table '{TABLE_NAME}' not found.")
            print(f"Available tables: {', '.join(tables)}")
            if tables:
                TABLE_NAME = tables[0]
                print(f"Using table: {TABLE_NAME}")
            else:
                print("Error: No tables in database.")
                sys.exit(1)
    except Exception as e:
        print(f"Error accessing database: {e}")
        sys.exit(1)
    
    root = Tk()
    app = ExcelEditor(root, DB_FILE, TABLE_NAME)
    root.mainloop()

if __name__ == "__main__":
    main()
