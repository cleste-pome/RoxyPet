# 语料位置

每个人物的语料都在 `02-assets/speech/<人物ID>.json`（运行时可被 `~/.roxy-pet/speech/<人物ID>.json` 覆盖）：

| 人物 | 语料 JSON | 文字原稿 / 生成方式 |
|---|---|---|
| 洛琪希 `roxy` | `02-assets/speech/roxy.json` | 内置池在 `01-src/speech.swift`；导出：`Roxy --export-speech > 02-assets/speech/roxy.json` |
| 艾丽丝 `eris` | `02-assets/speech/eris.json` | `07-docs/corpora/eris.md` → `03-scripts/import-speech.py` |
| 希露菲 `sylphie` | `02-assets/speech/sylphie.json` | `07-docs/corpora/sylphie.md` → `03-scripts/import-speech.py` |

台词里的 `{称呼}` 是占位符，显示时会替换成用户在设置里配置的称呼（未设置则优雅省略）。
