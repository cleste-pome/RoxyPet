# 角色与语料扩展

右键桌宠或点击菜单栏图标 →「角色」，可选择洛琪希、短发艾丽丝、长发艾丽丝。长发穿裙装，短发穿旅行装。切换后记住选择，无需重启；进行 AI 回复或任务时暂停切换，避免结果串到其他人物。

## 添加人物或装束

菜单「角色 → 添加其他角色…」打开 `~/.roxy-pet/characters/`。复制项目 `02-assets/characters/eris-short/` 为模板，使用独立子文件夹，并修改 `character.json` 和 `spritesheet.png`。点击「重新载入角色与语料」即可读取。

仓库内置角色放在 `02-assets/characters/<装束ID>/`，构建时一同打包。

```json
{
  "id": "sylphie-default",
  "characterID": "sylphie",
  "name": "希露菲",
  "appearance": "日常装",
  "actionVerb": "请",
  "historyTitle": "对话记录",
  "screenTitle": "一起看看屏幕",
  "persona": "填写该角色的身份与说话风格。",
  "atlas": "spritesheet.png",
  "speech": {}
}
```

- `id`：每套装束唯一；仅小写字母、数字、下划线、连字符，必须以字母或数字开头。
- `characterID`：人物身份。艾丽丝长短发都用 `eris`，因此共享语料和 Claude 会话；希露菲使用 `sylphie`。
- `actionVerb` + `name` 组成菜单请求措辞。洛琪希「吩咐」，艾丽丝「拜托」。窗口标题、显示 / 隐藏、退出按 `name` 更新。
- `atlas`：同一目录里的 PNG 文件名，推荐 RGBA 3072×4576，8 列×11 行，单格 384×416；也兼容原洛琪希的 1536×2288 图集。逻辑单格统一为 192×208，实际窗口为 144×156 点，高清像素保留给 Retina 显示。每格留下透明边距、脚底对齐。
- `speech`：可直接写入分组语料，也可留空使用独立语料文件。
- 重复 ID、路径不合法、缺图或配置损坏的扩展不会加入菜单；图片加载失败时保留当前人物。

动画行顺序：0 待机眨眼、1 向右跑、2 向左跑、3 挥手、4 跳跃、5 受挫、6 等待、7 工作、8 检视、9–10 共 16 个视线方向。视线从正上方开始，顺时针每 22.5° 一档。动画使用帧数分别为 6、8、8、4、5、8、6、6、6、8、8。

## 语料来源与接入

本次不另行创作语料。`08-docs/corpora/eris.md` 与 `08-docs/corpora/sylphie.md` 是项目文件夹中 Claude Code 产出的语料快照；导入器保留每条原文，只转换分类键。艾丽丝界面名按用户要求显示为「艾丽丝」，源文件中的「艾莉丝」标题不改写。

```sh
python3 03-scripts/import-speech.py
# 若原文件在其他目录：
python3 03-scripts/import-speech.py --source-dir /path/to/corpora
```

导入结果：`02-assets/speech/eris.json`、`02-assets/speech/sylphie.json`。打包后按人物 ID 读取。希露菲目前只有预留语料，没有模型，不展示不可使用的角色选项。

本地更新也可放在 `~/.roxy-pet/speech/<characterID>.json`，再点击「重新载入角色与语料」；同分类覆盖内置语料。洛琪希继续使用原有 `speech.swift` 与 `~/.roxy-pet/speech.json`，不改变既有扩展格式。

JSON 为「分类名 → 字符串数组」。支持 chat、greeting、hover、drag、look_end、lonely、morning、day、evening、night、weekend、workday、battery20、battery10、battery_full、done、notice、idle、ai_thinking、ai_fail；8 个方位键为 up、up_right、right、down_right、down、down_left、left、up_left。报时键为 hourly_morning、hourly_noon、hourly_day、hourly_evening、hourly_default，使用 `{h}` 占位。缺少某类语料时该事件保持安静，不借用洛琪希台词。

## 美术与构建检查

艾丽丝图片由内置 image_gen 按用户设定图生成；原图和最终提示词记录见 [素材制作记录](eris-art-generation.md)。将生成原图重新组装为高清图集（Python 需要 Pillow、numpy）：

```sh
python3 03-scripts/pack-eris-atlas.py 07-art-source/eris/short/sources 02-assets/characters/eris-short
python3 03-scripts/pack-eris-atlas.py 07-art-source/eris/long/sources 02-assets/characters/eris-long
python3 03-scripts/pack-eris-atlas.py --self-test
python3 03-scripts/render-character-previews.py
bash 03-scripts/build.sh
./RoxyPet.app/Contents/MacOS/RoxyPet --self-test
```

自检验证三种装束连续切换、动画帧完整性、Retina 原始像素保留、两处菜单、语料与人设路由、损坏图集回退、旧记录和新记录的角色名称。需要在 macOS 图形会话中运行；不调用 API，不修改用户偏好或聊天记录。

聊天记录继续保存到原路径，旧记录默认署名洛琪希，新记录附带人物身份与名称。Claude 会话按人物隔离；艾丽丝长短发共享。opencode 的全局续聊仅保留给原洛琪希，其他人物使用新会话，避免跨人物继承口吻。
