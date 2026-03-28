import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;
import 'database_helper.dart';
import 'language_prefs.dart';

class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  String? _filePath;
  String? _fileName;

  // 列选择：A=0, B=1, ... 默认泰语=C(2), 中文=D(3)
  int _thaiCol = 2;
  int _chineseCol = 3;

  List<CategoryEntry> _categories = [];
  int? _selectedCategoryId;

  bool _loading = false;
  String? _previewError;
  List<List<String>> _preview = []; // →行预→'

  String? _resultMsg;
  bool _resultSuccess = false;

  // 列选项
  static const _colOptions = [
    'A (→→', 'B (→→', 'C (→→', 'D (→→',
    'E (→→', 'F (→→', 'G (→→', 'H (→→',
  ];

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final cats = await DatabaseHelper.getAllCategories();
    if (mounted) {
      setState(() {
        _categories = cats;
        if (cats.isNotEmpty) _selectedCategoryId = cats.first.id;
      });
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
      withData: false,
      withReadStream: false,
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;

    setState(() {
      _filePath = path;
      _fileName = result.files.first.name;
      _previewError = null;
      _preview = [];
      _resultMsg = null;
    });

    _updatePreview();
  }

  void _updatePreview() {
    if (_filePath == null) return;
    try {
      final bytes = File(_filePath!).readAsBytesSync();
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables[excel.tables.keys.first];
      if (sheet == null) {
        setState(() => _previewError = '无法读取工作→');
        return;
      }

      final rows = <List<String>>[];
      int count = 0;
      for (final row in sheet.rows) {
        if (count >= 5) break;
        final maxCol = row.length;
        final thaiVal = _thaiCol < maxCol
            ? (row[_thaiCol]?.value?.toString() ?? '')
            : '';
        final chineseVal = _chineseCol < maxCol
            ? (row[_chineseCol]?.value?.toString() ?? '')
            : '';
        if (thaiVal.isNotEmpty || chineseVal.isNotEmpty) {
          rows.add([thaiVal, chineseVal]);
          count++;
        }
      }

      setState(() {
        _preview = rows;
        _previewError = null;
      });
    } catch (e) {
      setState(() => _previewError = '读取文件失败: $e');
    }
  }

  Future<void> _doImport() async {
    if (_filePath == null) {
      _showSnack('请先选择 Excel 文件');
      return;
    }
    if (_selectedCategoryId == null) {
      _showSnack('请选择类别');
      return;
    }

    setState(() {
      _loading = true;
      _resultMsg = null;
    });

    try {
      final bytes = await File(_filePath!).readAsBytes();
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables[excel.tables.keys.first];
      if (sheet == null) throw Exception('无法读取工作→');

      final rows = <Map<String, String>>[];
      for (final row in sheet.rows) {
        final maxCol = row.length;
        final thai = _thaiCol < maxCol
            ? (row[_thaiCol]?.value?.toString() ?? '').trim()
            : '';
        final chinese = _chineseCol < maxCol
            ? (row[_chineseCol]?.value?.toString() ?? '').trim()
            : '';
        if (thai.isNotEmpty && chinese.isNotEmpty) {
          rows.add({'thai': thai, 'chinese': chinese});
        }
      }

      final result = await DatabaseHelper.bulkImport(rows, _selectedCategoryId!);
      final ins = result['inserted'] ?? 0;
      final skp = result['skipped'] ?? 0;
      final l = L10n(AppLangNotifier().uiLang);
      final isEn = l.isEn;
      final isTW = l.isZhTW;

      setState(() {
        _resultMsg = isEn
            ? 'Import complete: $ins added, $skp skipped'
            : (isTW ? '匯入完成：新→$ins 筆，跳過重複 $skp →' : '导入完成：新→$ins 条，跳过重复 $skp →');
        _resultSuccess = true;
      });
    } catch (e) {
      setState(() {
        _resultMsg = '导入失败: $e';
        _resultSuccess = false;
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n(AppLangNotifier().uiLang);
    final isEn = l.isEn;
    final isTW = l.isZhTW;

    final step1 = isEn ? '1. Select Excel File' : (isTW ? '1. 選擇 Excel 檔案' : '1. 选择 Excel 文件');
    final step2 = isEn ? '2. Column Settings' : (isTW ? '2. 設定欄位' : '2. 设置→');
    final step3 = isEn ? '3. Select Category' : (isTW ? '3. 選擇類別' : '3. 选择类别');
    final step4 = isEn ? '4. Preview (first 5 rows)' : (isTW ? '4. 資料預覽（前5行）' : '4. 数据预览（前5行）');
    final pickHint = isEn ? 'Tap to select .xlsx file' : (isTW ? '點擊選擇 .xlsx 檔案' : '点击选择 .xlsx 文件');
    final thaiColLabel = isEn ? 'Thai Column' : (isTW ? '泰語→' : '泰语→');
    final chineseColLabel = isEn ? 'Chinese Column' : (isTW ? '中文→' : '中文→');
    final noCategories = isEn ? 'No categories available' : (isTW ? '沒有可用類別' : '没有可用类别');
    final noDataHint = isEn ? 'No data in selected columns. Adjust column settings.' : (isTW ? '所選欄無資料，請調整欄位設→' : '所选列无数据，请调整列设置');
    final importBtn = isEn ? 'Start Import' : (isTW ? '開始匯入' : '开始导→');
    final importingBtn = isEn ? 'Importing→' : (isTW ? '匯入中→' : '导入中→');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: Text(l.importTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 选择文件 ─────────────────────────────────────
            _SectionTitle(title: step1),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open),
              label: Text(_fileName ?? pickHint),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: Color(0xFF1565C0)),
                foregroundColor: const Color(0xFF1565C0),
              ),
            ),

            const SizedBox(height: 20),

            // ── 列设→───────────────────────────────────────
            _SectionTitle(title: step2),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _ColDropdown(
                    label: thaiColLabel,
                    value: _thaiCol,
                    options: _colOptions,
                    onChanged: (v) {
                      setState(() => _thaiCol = v);
                      _updatePreview();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ColDropdown(
                    label: chineseColLabel,
                    value: _chineseCol,
                    options: _colOptions,
                    onChanged: (v) {
                      setState(() => _chineseCol = v);
                      _updatePreview();
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── 类别 ─────────────────────────────────────────
            _SectionTitle(title: step3),
            const SizedBox(height: 8),
            if (_categories.isEmpty)
              Text(noCategories, style: const TextStyle(color: Colors.grey))
            else
              DropdownButtonFormField<int>(
                value: _selectedCategoryId,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                ),
                items: _categories
                    .map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(c.name),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedCategoryId = v),
              ),

            const SizedBox(height: 20),

            // ── 预览 ─────────────────────────────────────────
            if (_filePath != null) ...[
              _SectionTitle(title: step4),
              const SizedBox(height: 8),
              if (_previewError != null)
                Text(_previewError!,
                    style: const TextStyle(color: Colors.red))
              else if (_preview.isEmpty)
                Text(noDataHint,
                    style: const TextStyle(color: Colors.orange))
              else
                Table(
                  border: TableBorder.all(
                      color: Colors.grey.shade300, width: 1),
                  columnWidths: const {
                    0: FlexColumnWidth(1),
                    1: FlexColumnWidth(1),
                  },
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                          color: const Color(0xFF1565C0).withOpacity(0.08)),
                      children: [
                        _TableCell(text: isEn ? 'Thai' : 'ภาษาไท→', header: true),
                        _TableCell(text: isEn ? 'Chinese' : (isTW ? '中文' : '中文'), header: true),
                      ],
                    ),
                    ..._preview.map((row) => TableRow(
                          children: [
                            _TableCell(text: row[0]),
                            _TableCell(text: row[1]),
                          ],
                        )),
                  ],
                ),
              const SizedBox(height: 20),
            ],

            // ── 导入按钮 ─────────────────────────────────────
            ElevatedButton.icon(
              onPressed: _loading ? null : _doImport,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upload_rounded),
              label: Text(_loading ? importingBtn : importBtn),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),

            // ── 结果 ─────────────────────────────────────────
            if (_resultMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _resultSuccess
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _resultSuccess
                          ? Colors.green.shade300
                          : Colors.red.shade300,
                    ),
                  ),
                  child: Text(
                    _resultMsg!,
                    style: TextStyle(
                      color: _resultSuccess
                          ? Colors.green.shade800
                          : Colors.red.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── 小组→────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 15,
        color: Color(0xFF1565C0),
      ),
    );
  }
}

class _ColDropdown extends StatelessWidget {
  final String label;
  final int value;
  final List<String> options;
  final ValueChanged<int> onChanged;

  const _ColDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 4),
        DropdownButtonFormField<int>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
          items: options
              .asMap()
              .entries
              .map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value,
                        style: const TextStyle(fontSize: 13)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

class _TableCell extends StatelessWidget {
  final String text;
  final bool header;
  const _TableCell({required this.text, this.header = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: header ? FontWeight.bold : FontWeight.normal,
          color: header ? const Color(0xFF1565C0) : Colors.black87,
        ),
      ),
    );
  }
}
