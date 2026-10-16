# 新角色模板

把本文件夹复制到 `02-assets/characters/<装束ID>/`（英文命名），然后：

1. 把 `spritesheet.png` 换成该角色的序列帧图（推荐 RGBA 3072×4576，8 列 × 11 行）
2. 编辑 `character.json`，把 `<…>` 占位全部替换为实际内容
3. 重新构建即可在「角色」菜单里看到（`bash 03-scripts/build.sh`）

完整字段说明、语料接入与「落位速查表」见上一级：[角色与语料扩展](../characters.md)。
