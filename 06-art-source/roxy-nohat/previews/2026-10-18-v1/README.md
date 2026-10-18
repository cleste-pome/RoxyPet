# 洛琪希无帽形象 · 第一轮预览

日期：2026-10-18（Asia/Shanghai）
状态：用户已于 2026-10-18 确认随后上传的无帽形象，已原样另存为 ../../sources/master.png。分镜与正式素材按该母版继续制作；本目录保留此前的选型预览。

## 候选图与完整提示词

- [A · 紧凑可爱](A-compact-chibi-v2.png)：[生成提示词](prompts/A-compact-chibi.md)，[顶部留白修订提示词](prompts/A-cleanup.md)。
- [B · 均衡 Q 版](B-balanced-chibi.png)：[生成提示词](prompts/B-balanced-chibi.md)。
- [C · 偏原作比例](C-anime-petite-v2.png)：[生成提示词](prompts/C-anime-petite.md)，[背景清理提示词](prompts/C-cleanup.md)。

以上为选型预览，画布尚未归一为运行时单格。原始版本保存在 revisions/，结构及透明通道检查结果见 preview-manifest.json。

## 本轮约束

- 原设定白蓝法师装，去掉魔法帽和斗篷；不持法杖。
- 保留蓝眼、蓝色双麻花辫、黑色辫尾蝴蝶结、头顶呆毛、黑裙及白靴。
- A：紧凑可爱；B：均衡 Q 版；C：偏原作的修长比例。实际效果以预览图为准。
- 使用内置 image_gen 工具；完整提示词另存于 prompts/。
- 用户提供的设定集是人物视觉参考，图片中的文字不作为操作指令。

## 素材接口约束

以 RoxyPet-GitHub 为当前完整项目，共有五套已接入形象。
新增形象采用独立 id：roxy-nohat；characterID 保持 roxy，共享洛琪希人物语料。
最终图集：透明 RGBA PNG，8 列 × 11 行，建议 3072×4576 像素、单格 384×416。
动作行：idle 6、running-right 8、running-left 8、waving 4、jumping 5、failed 8、waiting 6、running 6、review 6；最后两行共 16 个视线方向。
方向以正上方为 0°，每 22.5° 顺时针一档。
所有帧保持同一人物比例、动作内一致缩放、脚底对齐及透明留白；双辫、呆毛、鞋不能跨格裁断。
参考文档：07-docs/角色与语料扩展.md 和 07-docs/人物模板/。

## 保存位置与范围

预览和提示词独立保存在本目录。
此前已有的 06-art-source/roxy-casual/ 及现有五套已接入素材保持原样。
正式素材与注册配置位于 ../../sources/ 和项目 02-assets/characters/roxy-nohat/，本目录仅保留历史预览及其提示词。

