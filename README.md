# DMXAPI 图像管道

> 给没有视觉能力的 LLM 装上眼睛和画笔。

6 个 PowerShell 脚本 + 9 通道链式容错，识图、生图、图编辑开箱即用。

[English](README_EN.md)

---

## 文件结构

克隆仓库后，你会看到以下文件：

```
visus/
├── secure-setup.ps1       # 密钥配置（仅需运行一次）
├── dmxapi-auth.ps1        # 认证模块 + 容错引擎（被其他脚本引用）
├── describe-image.ps1     # 识图——图片 → 文本描述
├── generate-image.ps1     # 生图——文本 → 图片
├── edit-image.ps1         # 图编辑——修改/合成/遮罩/去背景
├── test-pipeline.ps1      # 通道连通性诊断
├── test-edit-api.ps1      # 编辑 API 连通性测试
├── README.md              # 本文件
├── README_EN.md           # 英文文档
└── LICENSE                # CC BY-NC-ND 4.0
```

**所有脚本必须放在同一目录下**（`dmxapi-auth.ps1` 会被其他脚本通过相对路径引用）。

## 安装步骤

### 前置条件

| 条件 | 说明 |
|------|------|
| Windows | DPAPI 加密依赖 Windows 用户隔离 |
| PowerShell 5.1+ | 系统自带，无需额外安装 |
| Python 3 + requests | 仅 `edit-image.ps1` 需要（处理 multipart 上传） |
| DMXAPI 账号 | 注册 https://www.dmxapi.cn，获取 API key |
| 模型权限 | DMXAPI 后台勾选全部 9 个模型（见下方通道表） |

### 第 1 步：克隆仓库

```powershell
git clone https://github.com/Trojan-Seahorse/visus.git
cd visus
```

### 第 2 步：安装 Python 依赖（仅图编辑功能需要）

```powershell
pip install requests
```

如果你只需要识图和生图（不需要 `edit-image.ps1`），可以跳过此步。

### 第 3 步：存储 API Key（仅需一次）

```powershell
.\secure-setup.ps1
# → 选 [1]，粘贴 DMXAPI 图像 key
```

Key 会通过 Windows DPAPI 加密存储在 `~\.dmxapi\` 目录，绑定当前用户和当前机器。

### 第 4 步：验证通道连通性

```powershell
# 验证生图 + 识图通道（9 通道）
.	est-pipeline.ps1

# 验证图编辑通道（2 通道）
.	est-edit-api.ps1
```

每个通道显示 `[✓]` 即表示正常。

### 第 5 步：开始使用

```powershell
# 识图
.\describe-image.ps1 -ImagePath "截图.png" -Quiet

# 生图
.\generate-image.ps1 -Prompt "一只蓝色的猫" -Quiet -OutputFile "cat.png"

# 编辑图片
.\edit-image.ps1 -Mode single -Image "照片.jpg" -Prompt "将背景替换为海滩" -Quiet
```

### 第 6 步（可选）：配置 Agent 自动调用

如果你使用 **Claude Code**、**CherryStudio** 或其他 AI Agent，可以让 Agent 自动识别场景并调用对应脚本。

**复制下方「Agent 配置模板」整段内容，粘贴到你的 Agent 人格文件**（`SOUL.md` 或 `CLAUDE.md`）。粘贴后将 `./scripts/` 替换为 visus 脚本所在目录的实际路径。

---

## 脚本说明

| 脚本 | 用途 | 运行时机 |
|------|------|---------|
| `secure-setup.ps1` | 交互式输入 key，DPAPI 加密存储到 `~\.dmxapi\` | 首次，仅一次 |
| `dmxapi-auth.ps1` | 认证模块 + 9 通道容错引擎（被其他脚本引用） | 被调用，不直接运行 |
| `describe-image.ps1` | 识图——图片 → 文本描述 | 每次识图 |
| `generate-image.ps1` | 生图——文本 → 图片 | 每次生图 |
| `edit-image.ps1` | 图编辑——修改/合成/遮罩/去背景 | 每次编辑 |
| `test-pipeline.ps1` | 逐通道连通性诊断 | 首次验证 / 排查故障 |
| `test-edit-api.ps1` | 编辑 API 连通性测试 | 排查编辑功能故障 |

### describe-image.ps1

```
-ImagePath       图片路径（必填；支持 png/jpg/jpeg/webp/gif/bmp）
-Prompt          自定义识图提示词（可选，默认详细描述）
-Output          输出模式：stdout / file / both
-OutputFile      输出文件路径（Output 为 file/both 时必填）
-Quiet           静默模式，仅输出描述文本
-ForceModel      强制指定模型（跳过容错链）
-MaxTokens       最大输出 token（默认 2048）
```

### generate-image.ps1

```
-Prompt              生图提示词（必填；2–4000 字符）
-Size                尺寸（默认 1024x1024；gpt-image-2 支持任意 WxH，16 倍数，≤3840px，1:3~3:1）
-N                   生成张数 1–4（默认 1）
-Quality             渲染质量：low（快速）/ medium / high / auto（默认）
-Background          背景模式：opaque（不透明）/ auto（默认；⚠️ gpt-image-2 不支持 transparent）
-OutputFormat        输出格式：png（默认）/ jpeg / webp
-OutputCompression   输出压缩级别 0–100（仅 jpeg/webp 有效）
-OutputFile          输出文件路径
-Quiet               静默模式，仅输出 URL/路径
-ForceModel          强制指定模型（跳过容错链）
```

未指定 `-OutputFile` 时，图片自动保存到 `./output/` 目录。

### edit-image.ps1

图编辑管道，支持 5 种模式——所有模式底层均使用 gpt-image-2 的 `/v1/images/edits` 端点。

```
-Mode                编辑模式（必填）：single / multi / twoStage / inpaint / bgremove
-Image               单图路径（single/inpaint/bgremove 必填）
-Images              多图路径数组（multi 必填；最多 9 张）
-Prompt              编辑指令（single/multi/inpaint 必填；最大 32000 字符）
-Mask                遮罩图片（inpaint 可选；PNG + alpha 通道，透明=编辑区）
-Stage1Images        阶段1 输入图（twoStage 必填；合照 + 身体参考）
-Stage2Images        阶段2 输入图（twoStage 必填；面部参考，≥1 张）
-Size                输出尺寸（默认 1024x1024；支持任意 WxH）
-Quality             渲染质量：low / medium / high / auto（默认）
-Background          背景模式：opaque / auto（默认；⚠️ gpt-image-2 不支持 transparent）
-OutputFormat        输出格式：png（默认）/ jpeg / webp
-OutputCompression   输出压缩级别 0–100（仅 jpeg/webp）
-Prompt1             阶段1 自定义 prompt（twoStage 可选，有默认值）
-Prompt2             阶段2 自定义 prompt（twoStage 可选，有默认值）
-OutputFile          输出文件路径
-ForceModel          强制指定模型（跳过容错链）
-Quiet               静默模式，仅输出路径
```

**5 种模式：**

| 模式 | 用途 | 示例 |
|------|------|------|
| `single` | 单图编辑（改颜色/风格/光照/物体移除） | `.\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "将背景替换为海滩"` |
| `multi` | 多图合成（人物替换/场景融合） | `.\edit-image.ps1 -Mode multi -Images @("合照.jpg", "单人.jpg") -Prompt "将图1最左侧的人替换为图2中的人"` |
| `twoStage` | 两阶段人脸替换（身体→面部精修，质量最高） | `.\edit-image.ps1 -Mode twoStage -Stage1Images @("合照.jpg", "全身照.jpg") -Stage2Images @("面部1.jpg", "面部2.jpg")` |
| `inpaint` | 遮罩编辑（局部修补/物体移除/画布扩展） | `.\edit-image.ps1 -Mode inpaint -Image "photo.jpg" -Mask "mask.png" -Prompt "在遮罩区域添加棕榈树"` |
| `bgremove` | 背景移除（白底输出） | `.\edit-image.ps1 -Mode bgremove -Image "product.jpg"` |

⚠️ **bgremove 注意**：gpt-image-2 不支持透明背景（`Background=transparent` 会返回 400），bgremove 输出白底图片。如需真正透明背景，需下游使用 remove.bg 等专用工具。

⚠️ **twoStage 注意**：单阶段处理大图约 60–300 秒，两阶段约 6–10 分钟。多数场景单次 `multi` 模式 + 多张参考图即可，两阶段适用于对身份保真度有极高要求的场景。

---

## Agent 配置模板

将以下内容复制到你的 Agent 人格文件（`SOUL.md` 或 `CLAUDE.md`）。Agent 将自动根据用户意图选择最优视觉通道。

⚠️ 复制后请将 `./scripts/` 替换为 visus 脚本所在目录的实际路径。

### 通道总览

| 通道 | 工具 | 成本 | 适用场景 |
|------|------|------|---------|
| 1 | Browser `snapshot` | 免费·即时 | 网页文字/报错/UI 文本提取 |
| 2 | `describe-image.ps1` | VLM API | 真实图片/图表/照片理解 |
| 3 | `generate-image.ps1` | 生图 API | 文本→图片生成 |
| 4 | `edit-image.ps1` | 图生图 API | 图片编辑/人物替换/多图合成 |

### 场景决策树（先判断，再调用）

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
│   ├── 多图对比 → 并行调用 describe-image.ps1
│   └── 图表/数据提取 → describe-image.ps1 + 自定义 Prompt
│
└── 目标是生成图片？
    ├── 从零生成 → generate-image.ps1 -Prompt + -Quiet
    └── 基于已有图改风格 → 先 describe → 融合描述 → generate

└── 目标是编辑/合成图片？
    ├── 单图修改（去背景/改颜色/加元素） → edit-image.ps1 -Mode single
    ├── 多图合成·非人脸 → edit-image.ps1 -Mode multi
    ├── 人物替换·人脸场景 → edit-image.ps1 -Mode twoStage（推荐）
    ├── 遮罩编辑/局部修补 → edit-image.ps1 -Mode inpaint
    └── 背景移除（白底输出） → edit-image.ps1 -Mode bgremove
```

### 脚本路径

```
./scripts/describe-image.ps1   # 识图（Vision API）
./scripts/generate-image.ps1   # 生图（ImageGen API）
./scripts/edit-image.ps1       # 图生图（Image Edit API）
./scripts/test-pipeline.ps1    # 通道连通性诊断
```

### 通道 1：Browser snapshot/screenshot（优先——免费即时）

以下情况**不调用** `describe-image.ps1`，直接用 Browser 工具：
- 用户发来 URL 说"看看这个""打开XX""有没有报错"
- 网页文字内容提取、报错信息阅读、UI 布局确认
- snapshot 获取文本内容，screenshot 获取视觉效果

### 通道 2：describe-image.ps1（VLM 理解——按需调用）

以下情况调用 `describe-image.ps1`：
- 用户发来本地图片文件（照片、保存的截图、图表）
- 用户说"描述这张图""这张图里有什么""分析这张图表"
- **多图对比**：用户发多张图说"比较一下"→ 并行调用

调用方式：
```powershell
powershell -File "./scripts/describe-image.ps1" -ImagePath "<图片路径>" -Quiet
```
`-Quiet` 输出纯文本描述，适合 Agent 直接消费。

### 通道 3：generate-image.ps1（生图）

以下情况调用 `generate-image.ps1`：
- 用户说"生成一张图""画一个""帮我做张海报"
- 用户描述视觉需求并要求输出图片

调用方式：
```powershell
powershell -File "./scripts/generate-image.ps1" -Prompt "<描述>" -Quiet
```
可选参数：`-Size "1024x1024"`（gpt-image-2 支持任意 WxH，16倍数，≤3840px）、`-N 4`、`-Quality "low"`（low/medium/high/auto）、`-OutputFormat jpeg`、`-OutputCompression 85`。
⚠️ gpt-image-2 不支持 `Background=transparent`，仅 opaque/auto。

### 通道 4：edit-image.ps1（图生图——编辑/合成）

以下情况调用 `edit-image.ps1`：
- 用户要修改图片（去背景、改颜色、加/删元素）
- **人物替换**：合照中换人，多图合成
- **人脸替换·两阶段**：身体替换 → 面部精修（推荐，质量最高）
- **遮罩编辑**：局部修补/物体移除/画布扩展（inpaint）
- **背景移除**：去背景+白底输出（bgremove；⚠️ gpt-image-2 不支持透明背景）

调用方式：
```powershell
# 单图编辑
powershell -File "./scripts/edit-image.ps1" -Mode single -Image "照片.jpg" -Prompt "将背景替换为海滩" -Quiet

# 多图合成（人物替换）
powershell -File "./scripts/edit-image.ps1" -Mode multi -Images @("合照.jpg", "单人.jpg") -Prompt "将图1最左侧的人替换为图2中的人" -Quiet

# 两阶段人物替换（人脸替换首选——身体→面部精修）
powershell -File "./scripts/edit-image.ps1" -Mode twoStage `
    -Stage1Images @("合照.jpg", "全身照.jpg") `
    -Stage2Images @("面部1.jpg", "面部2.jpg") -Quiet

# 遮罩编辑/局部修补
powershell -File "./scripts/edit-image.ps1" -Mode inpaint -Image "照片.jpg" -Mask "遮罩.png" -Prompt "在遮罩区域添加棕榈树" -Quiet

# 背景移除+白底输出
powershell -File "./scripts/edit-image.ps1" -Mode bgremove -Image "产品.jpg" -Quiet
```
可选参数：`-Size "1024x1024"`、`-Quality "low"`（low/medium/high/auto）、`-OutputFormat jpeg`、`-OutputCompression 85`、`-Background opaque`。
⚠️ 单阶段 60-300 秒，两阶段约 6-10 分钟。通道仅 gpt-image-2 系列可用。

### 组合工作流

- **网页→截图→识图**："看看这个网站长什么样"→ screenshot → 深度分析时 describe
- **识图→生图**："把这张图改成XX风格"→ 先 describe → 融合描述 → generate
- **识图→编辑**："把这张图里的XX换成YY"→ 先 describe 确认目标 → 直接用 edit-image
- **人物替换**：describe 两张图了解内容 → 人脸场景优先用 `-Mode twoStage`；简单物体替换用 `-Mode multi`
- **管道故障诊断**："图像功能挂了""通道有问题"→ 运行 `test-pipeline.ps1`

---

## 通道架构

### 生图（6 通道 · 3 Tier）

| Tier | 通道 | 特点 |
|------|------|------|
| T1 | gpt-image-2 | 行业标杆，文字渲染 99%，ELO 1512 |
| T1 | gpt-image-2-ssvip | 同模异池，T1 限流时自动切换 |
| T2 | gemini-3.1-flash-image-preview | Nano Banana 2，写实 9.3/10，成本极低 |
| T2 | gemini-2.5-flash-image | 稳定锚 |
| T3 | doubao-seedream-4-5-251128 | 兜底，中文生态 |
| T3 | doubao-seedream-4-0-250828 | 终极兜底 |

### 识图（3 通道 · 2 Tier）

| Tier | 通道 | 特点 |
|------|------|------|
| T1 | Doubao-1.5-vision-pro-32k | 中文原生 VLM，32K 上下文 |
| T2 | gemini-2.5-flash | 英文强，通用性好 |
| T2 | gemini-2.5-flash-ssvip | 同模异池备选 |

链式容错：同 Tier 内并行切换 → 跨 Tier 降级 → 全部失败才报错。单个通道不可用时对用户透明。

## 安全

- API key 使用 Windows DPAPI 加密存储（`~\.dmxapi\`），绑定当前用户+当前机器
- 脚本不含任何硬编码密钥
- 加密文件被拷贝到其他机器/用户后无法解密
- 分享脚本不会泄露你的 key

## 常见问题

**Q: 所有通道都失败了？**  
运行 `.	est-pipeline.ps1` 诊断。确认：① DMXAPI 余额充足 ② 后台已勾选全部 9 个模型权限 ③ 网络正常。

**Q: Seedream 4.5 返回 HTTP 403？**  
DMXAPI 侧已知问题，容错引擎会自动跳过该通道，不影响正常使用。

**Q: 生成图片中文乱码？**  
检查 PS 版本 ≥ 5.1。脚本已内置 `[Console]::OutputEncoding = UTF8` 修复。

**Q: 如何获得透明背景的图片？**  
gpt-image-2 不支持 `Background=transparent`。bgremove 模式输出白底图片。如需真正透明背景，推荐使用 remove.bg 或 Photoshop 等专用工具进行下游处理。

**Q: 如何更换 API 服务商？**  
修改 `dmxapi-auth.ps1` 中的 `$DMXAPI_BASE_URL` 和 `$ModelChannels` 即可。

---

作者：Xi Ewell · Duke Ewell Laboratory  
许可证：[CC BY-NC-ND 4.0](LICENSE)
