#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把每个函数里的 nameref 局部变量重命名为函数专属名字，消除 circular name reference。

bash 中 `local -n X=$1` 若调用函数时传入的对象名也叫 X，就会出现
"circular name reference" 警告并导致字段读取失败。本脚本按函数粒度
把 X 换成 __self_<函数名>，函数名中的 :: 换成 _。
"""
import re
import sys
from pathlib import Path

FN_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_:]*)\(\)\s*\{\s*$')
NR_RE = re.compile(r'local\s+-n\s+([A-Za-z_][A-Za-z0-9_]*)=\$1\b')


def sanitize(name: str) -> str:
    return '__self_' + name.replace('::', '_')


def process(path: Path) -> int:
    lines = path.read_text(encoding='utf-8').split('\n')
    cur_fn = None
    cur_var = None
    changed = 0
    for i, line in enumerate(lines):
        m = FN_RE.match(line)
        if m:
            cur_fn = m.group(1)
            cur_var = None
            continue
        if cur_fn is None:
            continue
        m = NR_RE.search(line)
        if m:
            cur_var = m.group(1)
            new = sanitize(cur_fn)
            line = line[:m.start(1)] + new + line[m.end(1):]
            lines[i] = line
            changed += 1
            continue
        if cur_var:
            # 替换函数体内对该 nameref 变量的引用（含 ${v[..]} / $v[..] / "v" 传参）
            pat = re.compile(r'(?<![\w$])' + re.escape(cur_var) + r'(?![\w])')
            new_line, n = pat.subn(sanitize(cur_fn), line)
            if n:
                lines[i] = new_line
                changed += n
    path.write_text('\n'.join(lines), encoding='utf-8')
    return changed


total = 0
for p in sys.argv[1:]:
    total += process(Path(p))
print(f'替换完成，共 {total} 处')
