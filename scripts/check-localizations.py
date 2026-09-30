#!/usr/bin/env python3
"""检查中文字符串目录的翻译状态和格式占位符，防止运行时漏译或格式错误。"""
import argparse
import collections
import json
from pathlib import Path
import re
import sys

CATALOG = Path(__file__).resolve().parents[1] / 'Thaw/Resources/Localizable.xcstrings'
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.\d+)?(ll|l|z)?([@diuoxXfFeEgGcs])')


def placeholders(text):
    result = collections.Counter()
    for index, match in enumerate(FORMAT.finditer(text.replace('%%', '')), 1):
        position, length, kind = match.groups()
        result[(int(position) if position else index, (length or '') + kind)] += 1
    return result


def units(node):
    if isinstance(node, dict):
        if 'stringUnit' in node:
            yield node['stringUnit']
        for key, value in node.items():
            if key != 'stringUnit':
                yield from units(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extracted-dir', type=Path, help='编译器生成的 .stringsdata 目录，用于检查漏收录文案')
    args = parser.parse_args()
    entries = json.loads(CATALOG.read_text())['strings']
    errors = []
    checked = 0
    if args.extracted_dir:
        files = list(args.extracted_dir.glob('*.stringsdata'))
        if not files:
            errors.append('指定目录没有编译器提取的字符串文件。请先构建工程。')
        for path in files:
            extracted = json.loads(path.read_text())
            for record in extracted.get('tables', {}).get('Localizable', []):
                if record['key'] not in entries:
                    errors.append(f"字符串目录未收录 {path.stem} 中的文案：{record['key']}")
    for key, entry in entries.items():
        if not key or entry.get('shouldTranslate') is False:
            continue
        for locale in ('zh-Hans', 'zh-Hant'):
            localized = list(units(entry.get('localizations', {}).get(locale, {})))
            if not localized:
                errors.append(f'{locale} 缺少翻译：{key}')
            for unit in localized:
                checked += 1
                if unit.get('state') != 'translated':
                    errors.append(f'{locale} 翻译未完成：{key}')
                if placeholders(key) != placeholders(unit.get('value', '')):
                    errors.append(f'{locale} 格式占位符不一致：{key}')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'中文翻译检查通过：{checked} 条字符串，涵盖简体和繁体中文。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
