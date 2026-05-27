# visus Agent 配置模板

> 将本文件内容复制到你的 Agent 人格文件（SOUL.md / CLAUDE.md），Agent 将自动根据用户意图选择最优视觉通道。
>
> **复制后请将下面所有路径中的 `./scripts/` 替换为 visus 脚本所在目录的实际路径**（例如 `D:\visus\`）。

---

## 通道总览

| 通道 | 工具 | 成本 | 适用场景 |
|------|------|------|---------|
| 1 | Browser `snapshot` | 免费·即时 | 网页文字/报错/UI 文本提取 |
| 2 | `describe-image.ps1` | VLM API | 真实图片/图表/照片理解 |
| 3 | `generate-image.ps1` | 生图 API | 文本→图片生成 |
| 4 | `edit-image.ps1` | 图生图 API | 图片编辑/人物替换/多图合成 |

## 场景决策树

收到视觉相关请求时，按以下决策树选择通道：

```
收到视觉相关请求
├── 目标是网页/URL？
│   ├── 要"看内容/报错/文字" → snapshot（免费即时）
│   ├── 要"看布局/长什么样/设计" → screenshot
│   ├── snapshot 不可用时 → web_fetch_exa 降级
│   └── 需要登录/交互 → open + showWindow=true + snapshot
│
├── 目标是本地图片文件？
│   ├── 单图描述 → describe-image.ps1 -Quiet
│   ├── 多图对比 → 并行调用 describe-image.ps1，拿到结果后综合比较
│   └── 图表/数据提取 → describe-image.ps1 + 自定义 Prompt
│
└── 目标是生成图片？
    ├── 从零生成 → generate-image.ps1 -Prompt + -Quiet
    └── 基于已有图改风格 → 先 describe 获取描述 → 融合新需求 → generate

└── 目标是编辑/合成图片？
    ├── 单图修改（去背景/改颜色/加元素） → edit-image.ps1 -Mode single
    ├── 多图合成·非人脸 → edit-image.ps1 -Mode multi
    ├── 人物替换·人脸场景 → edit-image.ps1 -Mode twoStage（推荐·两阶段）
    ├── 遮罩编辑/局部修补 → edit-image.ps1 -Mode inpaint
    └── 背景移除（白底输出） → edit-image.ps1 -Mode bgremove
```

## 脚本路径

```
./scripts/describe-image.ps1   # 识图（Vision API）
./scripts/generate-image.ps1   # 生图（ImageGen API）
./scripts/edit-image.ps1       # 图生图（Image Edit API）
./scripts/test-pipeline.ps1    # 通道连通性诊断
```

## 通道 1：Browser snapshot/screenshot（优先——免费即时）

以下情况**不调用** `describe-image.ps1`，直接用 Browser 工具：
- 用户发来 URL 说"看看这个""打开XX""有没有报错"
- 网页文字内容提取、报错信息阅读、UI 布局确认
- snapshot 获取文本内容，screenshot 获取视觉效果

## 通道 2：describe-image.ps1（VLM 理解）

以下情况调用 `describe-image.ps1`：
- 用户发来本地图片文件（照片、保存的截图、图表）
- 用户说"描述这张图""这张图里有什么""分析这张图表"
- **多图对比**：用户发多张图说"比较一下"→ 并行调用

调用方式：

```powershell
powershell -File "./scripts/describe-image.ps1" -ImagePath "<图片路径>" -Quiet
```

`-Quiet` 输出纯文本描述，适合 Agent 直接消费。

## 通道 3：generate-image.ps1（生图）

以下情况调用 `generate-image.ps1`：
- 用户说"生成一张图""画一个""帮我做张海报"
- 用户描述视觉需求并要求输出图片

调用方式：

```powershell
powershell -File "./scripts/generate-image.ps1" -Prompt "<描述>" -Quiet
```

可选参数：
- `-Size "1024x1024"` — gpt-image-2 支持任意 WxH，16 倍数，≤3840px，1:3~3:1 比例
- `-N 4` — 生成张数 1–4
- `-Quality "low"` — low（快速）/ medium / high / auto（默认）
- `-OutputFormat jpeg` — png / jpeg / webp
- `-OutputCompression 85` — 压缩级别 0–100
- `-Background opaque` — opaque / auto

⚠️ gpt-image-2 **不支持** `Background=transparent`，仅 opaque/auto。

## 通道 4：edit-image.ps1（图生图——编辑/合成）

以下情况调用 `edit-image.ps1`：
- 用户要修改图片（去背景、改颜色、加/删元素）
- **人物替换**：合照中换人，多图合成
- **人脸替换·两阶段**：身体替换 → 面部精修（推荐，质量最高）
- **遮罩编辑**：局部修补/物体移除/画布扩展（inpaint）
- **背景移除**：去背景+白底输出（bgremove；⚠️ 非透明背景）

调用方式：

```powershell
# 单图编辑
powershell -File "./scripts/edit-image.ps1" -Mode single -Image "照片.jpg" -Prompt "将背景替换为海滩" -Quiet

# 多图合成（人物替换）
powershell -File "./scripts/edit-image.ps1" -Mode multi -Images @("合照.jpg", "单人.jpg") -Prompt "将图1最左侧的人替换为图2中的人，保留胸牌" -Quiet

# 两阶段人物替换（人脸替换首选——身体→面部精修）
powershell -File "./scripts/edit-image.ps1" -Mode twoStage `
    -Stage1Images @("合照.jpg", "全身照.jpg") `
    -Stage2Images @("面部1.jpg", "面部2.jpg", "面部3.jpg", "面部4.jpg") -Quiet

# 遮罩编辑/局部修补
powershell -File "./scripts/edit-image.ps1" -Mode inpaint -Image "照片.jpg" -Mask "遮罩.png" -Prompt "在遮罩区域添加棕榈树" -Quiet

# 背景移除+白底输出
powershell -File "./scripts/edit-image.ps1" -Mode bgremove -Image "产品.jpg" -Quiet
```

可选参数：`-Size "1024x1024"`、`-Quality "low"`（low/medium/high/auto，默认 auto）、`-OutputFormat jpeg`、`-OutputCompression 85`、`-Background opaque`。

⚠️ 单阶段 60–300 秒，两阶段约 6–10 分钟。

## 组合工作流

- **网页→截图→识图**："看看这个网站长什么样"→ screenshot → 深度分析时 describe
- **识图→生图**："把这张图改成XX风格"→ 先 describe → 融合描述 → generate
- **识图→编辑**："把这张图里的XX换成YY"→ 先 describe 确认目标 → 直接用 edit-image
- **人物替换**：describe 两张图了解内容 → 人脸场景优先用 `-Mode twoStage`；简单物体替换用 `-Mode multi`
- **管道故障诊断**："图像功能挂了""通道有问题"→ 运行 `test-pipeline.ps1`
