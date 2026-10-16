#!/usr/bin/env python3
"""Import the user's separately authored Markdown corpora without rewriting any line."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEYS = set('chat morning day evening night weekend workday hover drag look_end lonely up up_right right down_right down down_left left up_left greeting greetings battery20 battery10 battery_full done notice idle thinking fail ai_thinking ai_fail'.split())
ALIASES = {'greetings': 'greeting', 'thinking': 'ai_thinking', 'fail': 'ai_fail'}

def parse(source):
    pools = {}
    key = None
    in_block = False
    for line in source.splitlines():
        if line.startswith('#'):
            match = re.search(r'（([a-z_0-9]+)', line)
            key = match.group(1) if match else None
            in_block = False
        elif line.startswith('```'):
            in_block = not in_block
        elif in_block and key in KEYS and line.strip():
            pools.setdefault(ALIASES.get(key, key), []).append(line.strip())
        elif key == 'hourly' and line.startswith('|'):
            cells = [v.strip() for v in line.strip('|').split('|')]
            if len(cells) != 2 or '{h}' not in cells[1]:
                continue
            label = cells[0]
            period = next((k for term, k in [('7–11', 'morning'), ('12', 'noon'), ('13–17', 'day'), ('18–22', 'evening'), ('其他', 'default')] if term in label), None)
            if period:
                pools['hourly_' + period] = [cells[1]]
    required = {'chat', 'greeting', 'hover', 'drag', 'up', 'right', 'down', 'left', 'ai_thinking', 'ai_fail'}
    if not required.issubset(pools):
        raise ValueError('Missing corpus sections: ' + ', '.join(sorted(required - pools.keys())))
    return pools

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=ROOT.parent)
    args = parser.parse_args()
    out = ROOT / '02-assets/speech'
    archive = ROOT / '07-docs/corpora'
    out.mkdir(parents=True, exist_ok=True)
    archive.mkdir(parents=True, exist_ok=True)
    for character, pattern in [('eris', '*艾*语料库.md'), ('sylphie', '*希露菲*语料库.md')]:
        files = sorted(args.source_dir.glob(pattern))
        if not files:
            saved = archive / (character + '.md')
            files = [saved] if saved.exists() else []
        if len(files) != 1:
            raise SystemExit(f'Expected one {character} corpus, found {len(files)}')
        source = files[0].read_text()
        pools = parse(source)
        (out / (character + '.json')).write_text(json.dumps(pools, ensure_ascii=False, indent=2) + '\n')
        (archive / (character + '.md')).write_text(source)
        print(f'{character}: {sum(len(v) for k,v in pools.items() if not k.startswith("hourly_"))} lines, {len(pools)} categories; copied unchanged from {files[0].name}')
