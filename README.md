# DMXAPI 图像管道

一句话：给没有视觉能力的 LLM 装上眼睛和画笔。

4 个 PowerShell 脚本 + 9 通道链式容错，识图和生图开箱即用。

## 前置条件

| 条件 | 说明 |
|------|------|
| Windows | DPAPI 加密依赖 Windows 用户隔离 |
| PowerShell 5.1+ | 系统自带，无需额外安装 |
| DMXAPI 账号 | 注册 https://www.dmxapi.cn，获取 API key |
| 模型权限 | DMXAPI 后台勾选以下 9 个模型（见下方通道表） |

## 快速开始

```
# 1. 存储 API key（仅需一次）
.\secure-setup.ps1
# → 选 [1]，粘贴 DMXAPI 图像 key

# 2. 验证通道连通性（可选）
.\test-pipeline.ps1

# 3. 使用
.\describe-image.ps1 -ImagePath "截图.png" -Quiet
.\generate-image.ps1 -Prompt "一只蓝色的猫" -Quiet -OutputFile "cat.png"
```

## 脚本说明

| 脚本 | 用途 | 运行时机 |
|------|------|---------|
| `secure-setup.ps1` | 交互式输入 key，DPAPI 加密存储到 `~\.dmxapi\` | 首次，仅一次 |
| `dmxapi-auth.ps1` | 认证模块 + 9 通道容错引擎（被下面两个引用） | 被调用，不直接运行 |
| `describe-image.ps1` | 识图——图片 → 文本描述 | 每次识图 |
| `generate-image.ps1` | 生图——文本 → 图片 | 每次生图 |
| `test-pipeline.ps1` | 逐通道连通性诊断 | 首次验证 / 排查故障 |

### describe-image.ps1

```
-ImagePath       图片路径（必填）
-Prompt          自定义识图提示词（可选，默认详细描述）
-Output          输出模式：stdout / file / both
-OutputFile      输出文件路径（Output 为 file/both 时必填）
-Quiet           静默模式，仅输出描述文本
-ForceModel      强制指定模型（跳过容错链）
-MaxTokens       最大输出 token（默认 2048）
```

### generate-image.ps1

```
-Prompt          生图提示词（必填）
-Size            尺寸：1024x1024 / 1024x1536 / 1536x1024（默认 1024x1024）
-N               生成张数 1-4（默认 1）
-OutputFile      输出文件路径
-Quiet           静默模式，仅输出 URL/路径
-ForceModel      强制指定模型（跳过容错链）
```

未指定 `-OutputFile` 时，图片自动保存到 `./output/` 目录。

## Agent 自动调用配置

如果你使用 Claude Code / CherryStudio 等 Agent，将以下规则加入 Agent 人格文件（`SOUL.md` 或 `CLAUDE.md`），Agent 会自动识别场景并选择最优路径。

路径示例中的 `./scripts/` 需替换为你的脚本实际存放路径。

```markdown
## 图像与视觉能力

我的主模型不能看图也不能生图。但我有三条视觉通道：

| 通道 | 工具 | 成本 | 适用场景 |
|------|------|------|---------|
| 1 | Browser `snapshot` | 免费·即时 | 网页文字/报错/UI 文本提取 |
| 2 | `describe-image.ps1` | VLM API | 真实图片/图表/照片理解 |
| 3 | `generate-image.ps1` | 生图 API | 文本→图片生成 |

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
```

### 脚本位置

```
./scripts/describe-image.ps1   # 识图（Vision API）
./scripts/generate-image.ps1   # 生图（ImageGen API）
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
可选参数：`-Size "1024x1024"`、`-N 4`。

### 组合工作流

- **网页→截图→识图**："看看这个网站长什么样"→ screenshot → 深度分析时 describe
- **识图→生图**："把这张图改成XX风格"→ 先 describe → 融合描述 → generate
- **管道故障诊断**："图像功能挂了""通道有问题"→ 运行 `test-pipeline.ps1`
```

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
运行 `.\test-pipeline.ps1` 诊断。确认：① DMXAPI 余额充足 ② 后台已勾选全部 9 个模型权限 ③ 网络正常。

**Q: Seedream 4.5 返回 HTTP 403？**
DMXAPI 侧已知问题，容错引擎会自动跳过该通道，不影响正常使用。

**Q: 生成图片中文乱码？**
检查 PS 版本 ≥ 5.1。脚本已内置 `[Console]::OutputEncoding = UTF8` 修复。

**Q: 如何更换 API 服务商？**
修改 `dmxapi-auth.ps1` 中的 `$DMXAPI_BASE_URL` 和 `$ModelChannels` 即可。

---

作者：Xi Ewell · Duke Ewell Laboratory
