# Thai Dictionary Project - 泰语词典

## 项目概述

这是一个用于管理和学习泰语词汇的工具，支持从 JSON 导入数据、自动翻译为中文，并提供 Excel 风格的图形界面。

## 文件结构

```
dict/
├── dictionary.json              # 原始泰语词典数据
├── 1000_common_thai_words.json # 1000个常用泰语词汇
├── thai_dict.db                # SQLite 数据库（自动生成）
├── dict_tw.db                  # 繁体中文数据库
├── dict_country.db             # 多语言数据库（9种语言）
├── translation.db              # 综合翻译数据库（12种语言+拼音，由 dict_gen.py 生成）
├── thai_dict_viewer.py         # 词典查看器（搜索+导入）
├── thai_dict_editor.py         # Excel 风格编辑器（支持 --file 参数）
├── update_pinyin.py            # 生成中文拼音脚本
├── convert_to_traditional.py   # 转换为繁体中文脚本
├── convert_to_country.py       # 多语言翻译脚本（9种语言）
├── dict_gen.py                 # ★ 综合翻译生成器（12种语言+拼音，一键生成）
└── README.md                   # 本文件
```

## 数据库结构

### thai_dict.db - dictionary 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键 |
| thai | TEXT | 泰文 |
| roman | TEXT | 罗马拼音（泰语） |
| english | TEXT | 英文翻译 |
| chinese | TEXT | 中文翻译 |
| chinese_roman | TEXT | 中文拼音 |
| category | TEXT | 类别 |

### dict_tw.db - traditional_chinese 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键 |
| traditional | TEXT | 繁体中文 |

### dict_country.db - translations 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键 |
| english | TEXT | 英文原文 |
| german | TEXT | 德语 |
| french | TEXT | 法语 |
| spanish | TEXT | 西班牙语 |
| italian | TEXT | 意大利语 |
| russian | TEXT | 俄语 |
| ukrainian | TEXT | 乌克兰语 |
| hebrew | TEXT | 希伯来语 |
| japanese | TEXT | 日语 |
| korean | TEXT | 韩语 |

---

## 程序说明

### 1. thai_dict_viewer.py - 词典查看器

**用途**: 浏览和搜索词典，支持导入 JSON 数据

**运行方式**:
```bash
python thai_dict_viewer.py
```

**功能特性**:
- 自动导入 `dictionary.json` 并通过 Google Translate API 翻译为中文
- Excel 风格表格显示所有词汇
- 搜索功能（支持搜索泰文、拼音、英文、中文、类别）
- 双击行打开编辑弹窗，可编辑或删除词汇
- 编辑时可手动翻译英文到中文
- 支持重新导入 JSON 和导出数据库为 JSON

---

### 2. thai_dict_editor.py - Excel 风格编辑器

**用途**: 直接在单元格中编辑数据，通过 FILE 菜单保存

**运行方式**:
```bash
# 打开默认数据库 thai_dict.db
python thai_dict_editor.py

# 指定数据库文件
python thai_dict_editor.py --file dict_tw.db
python thai_dict_editor.py --file dict_country.db

# 指定数据库和表名
python thai_dict_editor.py --file mydata.db --table words
```

**功能特性**:
- Excel 风格表格，无需弹窗即可编辑
- 单击或双击任意单元格直接编辑
- 支持打开任意 SQLite 数据库文件
- 自动检测数据库中的表，多表时让您选择
- FILE 菜单：
  - **Open...** (Ctrl+O) - 打开其他数据库文件
  - **Save** (Ctrl+S) - 保存所有更改到数据库
  - **Reload** - 重新加载数据
  - **Exit** - 退出程序
- 底部状态栏显示当前数据库和表名
- 未保存更改时窗口标题带 `*` 标记

---

### 3. update_pinyin.py - 中文拼音生成脚本

**用途**: 为数据库中的中文内容生成拼音罗马拼音

**运行方式**:
```bash
pip install pypinyin
python update_pinyin.py
```

**功能特性**:
- 在数据库中添加 `chinese_roman` 列（如果不存在）
- 读取所有数据行，根据中文内容生成拼音
- 使用 `pypinyin` 库进行准确的中文拼音转换
- 显示处理进度和示例数据

---

### 4. convert_to_traditional.py - 转换为繁体中文

**用途**: 将简体中文转换为繁体中文，创建新数据库

**运行方式**:
```bash
# 使用 opencc 库（推荐，更准确）
pip install opencc
python convert_to_traditional.py

# 或使用内置字符映射
python convert_to_traditional.py
```

**功能特性**:
- 读取 `thai_dict.db` 中的中文内容
- 转换为繁体中文
- 创建 `dict_tw.db` 数据库

---

### 6. dict_gen.py - ★ 综合多语言翻译生成器

**用途**: 一键将 dictionary.json 翻译为 12 种语言并生成中文拼音，输出 translation.db

**运行方式**:
```bash
# 默认：读取 dictionary.json → 输出 translation.db
python dict_gen.py

# 指定输入/输出文件
python dict_gen.py --input dictionary.json --output translation.db

# 续跑模式：跳过已翻译的行（适合中断后继续）
python dict_gen.py --resume
```

**输出数据库**: `translation.db`，表名 `translations`

| 字段 | 说明 |
|------|------|
| id | 主键 |
| thai | 泰文原文 |
| roman | 泰语罗马拼音 |
| english | 英文原文 |
| category | 类别 |
| chinese_simplified | 中文简体 (zh-CN) |
| chinese_traditional | 中文繁体 (zh-TW) |
| german | 德语 |
| french | 法语 |
| spanish | 西班牙语 |
| italian | 意大利语 |
| russian | 俄语 |
| ukrainian | 乌克兰语 |
| hebrew | 希伯来语 |
| japanese | 日语 |
| korean | 韩语 |
| burmese | 缅甸语 |
| roman_cn | 中文拼音（Roman-CN），从中文简体生成 |

**功能特性**:
- 读取 `dictionary.json`，逐行翻译 `english` 字段到 12 种语言
- 使用 Google Translate 免费接口，无需 API Key
- 从中文简体自动生成拼音（优先使用 `pypinyin`，若未安装则用 Google 接口）
- 支持 `--resume` 续跑模式，中断后可继续而不重复翻译
- 实时显示翻译进度
- 使用 `INSERT OR REPLACE`，可安全重复运行

**依赖安装（可选，提高拼音准确性）**:
```bash
pip install pypinyin
```

---

### 5. convert_to_country.py - 多语言翻译脚本（旧版）

**用途**: 将英文翻译为9种语言，创建多语言数据库

**运行方式**:
```bash
python convert_to_country.py
```

**支持语言**:
| 语言 | 代码 |
|------|------|
| 德语 | German |
| 法语 | French |
| 西班牙语 | Spanish |
| 意大利语 | Italian |
| 俄语 | Russian |
| 乌克兰语 | Ukrainian |
| 希伯来语 | Hebrew |
| 日语 | Japanese |
| 韩语 | Korean |

**功能特性**:
- 读取 `thai_dict.db` 中的英文内容
- 通过 Google Translate API 翻译为9种语言
- 创建 `dict_country.db` 数据库
- 显示处理进度和示例数据
- 运行前会提示确认

**示例输出**:
```
ID | English | German | French | Spanish | Japanese | Korean
1  | hello   | Hallo  | Salut  | Hola    | こんにちは | 안녕하세요
```

---

## 技术实现

- **GUI**: Tkinter (Python 标准库)
- **数据库**: SQLite3 (Python 标准库)
- **翻译**: Google Translate API (免费，无需密钥)
- **拼音生成**: pypinyin 库
- **简繁转换**: opencc 库（或内置字符映射）
- **命令行参数**: argparse (Python 标准库)

## 数据来源

- `dictionary.json`: 基础泰语词汇表
- `1000_common_thai_words.json`: 1000个常用泰语词汇

## 注意事项

1. 首次运行会自动翻译所有词汇，需要几秒钟时间
2. Google Translate API 有请求限制，如遇翻译失败会自动重试
3. 数据库文件 `thai_dict.db` 会自动创建，如需重置可删除后重新运行 `thai_dict_viewer.py`
4. 使用 `thai_dict_editor.py` 编辑时，记得点击 **File > Save** 保存更改！
5. 运行 `update_pinyin.py` 前需要先安装 `pip install pypinyin`
6. 运行 `convert_to_traditional.py` 前建议先安装 `pip install opencc`
7. `convert_to_country.py` 需要网络连接，会翻译所有词汇（需要几分钟）

## 修改记录

- 2026-03-25: 创建项目
- 2026-03-25: 添加中文翻译功能（通过 Google Translate API）
- 2026-03-25: 添加 Excel 风格编辑器 `thai_dict_editor.py`
- 2026-03-25: 添加中文拼音生成脚本 `update_pinyin.py`
- 2026-03-25: 添加简繁转换脚本 `convert_to_traditional.py`
- 2026-03-25: `thai_dict_editor.py` 支持 `--file` 参数打开任意数据库
- 2026-03-25: 添加多语言翻译脚本 `convert_to_country.py`
- 2026-03-26: 添加综合翻译生成器 `dict_gen.py`（12种语言+中文拼音，输出 translation.db）
