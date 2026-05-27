# DMXAPI 图像管道

> 给没有视觉能力的 LLM 装上眼睛和画笔。
>
> 6 个 PowerShell 脚本 + 9 通道链式容错，识图、生图、图编辑开箱即用。

[English](README_EN.md)

---

## 文件结构

下载仓库后，你会看到以下文件（**所有脚本必须放在同一目录下**）：

```
visus/
├── secure-setup.ps1       # 密钥配置（仅需运行一次）
├── dmxapi-auth.ps1        # 认证模块 + 容错引擎（被其他脚本引用，勿直接运行）
├── describe-image.ps1     # 识图——图片 → 文本描述
├── generate-image.ps1     # 生图——文本 → 图片
├── edit-image.ps1         # 图编辑——修改/合成/遮罩/去背景
├── test-pipeline.ps1      # 通道连通性诊断
├── test-edit-api.ps1      # 编辑 API 连通性测试
├── AGENT_CONFIG.md        # Agent 配置模板（供 AI Agent 使用）
├── README.md              # 本文件
├── README_EN.md           # 英文文档
└── LICENSE                # CC BY-NC-ND 4.0
```

---

## 前置条件

| 需要什么 | 如何准备 |
|----------|---------|
| **Windows 系统** | DPAPI 加密依赖 Windows 用户隔离。macOS/Linux 暂不支持。 |
| **PowerShell 5.1+** | Windows 10/11 自带，无需安装。 |
| **Python 3 + requests** | 仅 `edit-image.ps1` 需要。在 visus 目录下运行 `pip install requests`。如果只用识图和生图，可以跳过。 |
| **DMXAPI 账号** | 去 https://www.dmxapi.cn 注册，在后台获取 API key。 |
| **模型权限** | DMXAPI 后台 → 模型管理 → 勾选全部 9 个模型（见下方通道表）。 |

---

## 安装步骤

有两种方式获取文件。**选一种即可。**

### 方式一：使用 Git（推荐）

如果你已安装 Git，打开 PowerShell 后执行：

```powershell
git clone https://github.com/Trojan-Seahorse/visus.git
cd visus
```

### 方式二：手动下载

如果没有 Git：

1. 用浏览器打开 https://github.com/Trojan-Seahorse/visus
2. 点击绿色 **"<> Code"** 按钮 → **"Download ZIP"**
3. 将下载的 `visus-main.zip` 解压到任意目录（例如 `D:\visus`）
4. 记住解压后的文件夹路径，后续步骤都在这个文件夹里操作

> **如何打开 PowerShell？** 按 `Win + R`，输入 `powershell`，回车。然后 `cd` 到 visus 文件夹：
> ```powershell
> cd D:\visus    # 替换为你的实际路径
> ```

---

## 第 1 步：安装 Python 依赖

> 只有使用 `edit-image.ps1`（图片编辑功能）才需要。只做识图和生图的可以跳到第 2 步。

在 visus 目录下执行：

```powershell
pip install requests
```

如果提示 `pip 不是可识别的命令`，说明你的 Python 没有添加到系统 PATH。解决方法：
- 重新安装 Python，**安装时勾选 "Add Python to PATH"**
- 或者用完整路径：`C:\Users\你的用户名\AppData\Local\Programs\Python\Python3xx\python.exe -m pip install requests`

---

## 第 2 步：存储 API Key

> 只需运行一次。Key 通过 Windows DPAPI 加密保存在 `~\.dmxapi\` 目录，绑定当前用户和当前机器。

在 visus 目录下执行：

```powershell
.\secure-setup.ps1
```

选择 `[1] 图像 API Key`，粘贴你的 DMXAPI 图像 key。如果提示 **"无法加载文件，因为在此系统上禁止运行脚本"**，先用管理员身份运行：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

然后重新执行 `.\secure-setup.ps1`。

---

## 第 3 步：验证通道连通性

```powershell
# 验证生图 + 识图通道（9 通道）
.\test-pipeline.ps1

# 验证图编辑通道（2 通道）
.\test-edit-api.ps1
```

每个通道显示 `[√]` 即表示正常。有红色 `[×]` 的通道说明该模型不可用（网络问题或权限未开通），容错引擎会自动跳过。

---

## 第 4 步：开始使用

```powershell
# 识图
.\describe-image.ps1 -ImagePath "截图.png" -Quiet

# 生图
.\generate-image.ps1 -Prompt "一只蓝色的猫" -Quiet -OutputFile "cat.png"

# 编辑图片（单图修改）
.\edit-image.ps1 -Mode single -Image "照片.jpg" -Prompt "将背景替换为海滩" -Quiet

# 背景移除
.\edit-image.ps1 -Mode bgremove -Image "产品.jpg" -Quiet
```

未指定 `-OutputFile` 时，图片自动保存到 `./output/` 目录。

---

## 第 5 步（可选）：配置 AI Agent 自动调用

如果你使用 **Claude Code**、**CherryStudio** 或其他 AI Agent，可以让 Agent 自动识别视觉需求并调用对应脚本。

打开项目中的 **[AGENT_CONFIG.md](AGENT_CONFIG.md)** 文件，复制全部内容，粘贴到你的 Agent 人格文件（`SOUL.md` 或 `CLAUDE.md`）。然后将文件中所有 `./scripts/` 替换为 visus 脚本所在目录的实际路径。

---

## 脚本说明

| 脚本 | 用途 | 运行时机 |
|------|------|---------|
| `secure-setup.ps1` | 交互式输入 key，DPAPI 加密存储 | 首次安装，仅一次 |
| `dmxapi-auth.ps1` | 认证 + 9 通道容错引擎 | 被调用，不直接运行 |
| `describe-image.ps1` | 图片 → 文本描述 | 每次识图 |
| `generate-image.ps1` | 文本 → 图片 | 每次生图 |
| `edit-image.ps1` | 修改/合成/遮罩/去背景 | 每次编辑 |
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
-Size                尺寸（默认 1024x1024；支持任意 WxH，16 倍数，≤3840px，1:3~3:1）
-N                   生成张数 1–4（默认 1）
-Quality             渲染质量：low（快速）/ medium / high / auto（默认）
-Background          背景模式：opaque（不透明）/ auto（默认）
-OutputFormat        输出格式：png（默认）/ jpeg / webp
-OutputCompression   输出压缩级别 0–100（仅 jpeg/webp 有效）
-OutputFile          输出文件路径
-Quiet               静默模式，仅输出 URL/路径
-ForceModel          强制指定模型（跳过容错链）
```

⚠️ gpt-image-2 **不支持** `Background=transparent`（透明背景），仅 opaque/auto。

### edit-image.ps1

图编辑管道，支持 5 种模式——所有模式底层均使用 gpt-image-2 的 `/v1/images/edits` 端点。

```
-Mode                编辑模式（必填）：single / multi / twoStage / inpaint / bgremove
-Image               单图路径（single/inpaint/bgremove 必填）
-Images              多图路径数组（multi 必填；最多 9 张）
-Prompt              编辑指令（single/multi/inpaint 必填）
-Mask                遮罩图片（inpaint 可选；PNG + alpha 通道，透明=编辑区）
-Stage1Images        阶段1 输入图（twoStage 必填；合照 + 身体参考）
-Stage2Images        阶段2 输入图（twoStage 必填；面部参考，≥1 张）
-Size                输出尺寸（默认 1024x1024）
-Quality             渲染质量：low / medium / high / auto（默认）
-Background          背景模式：opaque / auto（默认）
-OutputFormat        输出格式：png（默认）/ jpeg / webp
-OutputCompression   输出压缩级别 0–100（仅 jpeg/webp）
-Prompt1             阶段1 自定义 prompt（twoStage 可选，有默认值）
-Prompt2             阶段2 自定义 prompt（twoStage 可选，有默认值）
-OutputFile          输出文件路径
-ForceModel          强制指定模型（跳过容错链）
-Quiet               静默模式，仅输出路径
```

**5 种编辑模式：**

| 模式 | 用途 | 示例 |
|------|------|------|
| `single` | 单图编辑（改颜色/风格/光照/物体移除） | `.\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "将背景替换为海滩"` |
| `multi` | 多图合成（人物替换/场景融合） | `.\edit-image.ps1 -Mode multi -Images @("合照.jpg", "单人.jpg") -Prompt "将图1最左侧的人替换为图2中的人"` |
| `twoStage` | 两阶段人脸替换（身体→面部精修，质量最高） | `.\edit-image.ps1 -Mode twoStage -Stage1Images @("合照.jpg", "全身照.jpg") -Stage2Images @("面部1.jpg", "面部2.jpg")` |
| `inpaint` | 遮罩编辑（局部修补/物体移除/画布扩展） | `.\edit-image.ps1 -Mode inpaint -Image "photo.jpg" -Mask "mask.png" -Prompt "在遮罩区域添加棕榈树"` |
| `bgremove` | 背景移除（白底输出） | `.\edit-image.ps1 -Mode bgremove -Image "product.jpg"` |

⚠️ **bgremove 注意**：gpt-image-2 不支持透明背景（`Background=transparent` 会返回 400 错误），bgremove 输出白底图片。如需真正的透明背景，需下游使用 remove.bg 或 Photoshop 等专用工具处理。

⚠️ **twoStage 注意**：单阶段 60–300 秒，两阶段约 6–10 分钟。大多数场景单次 `multi` + 多张参考图即可，两阶段适用于对身份保真度要求极高的场景。

---

## 通道架构

### 生图（6 通道）

| Tier | 通道 | 特点 |
|------|------|------|
| T1 | gpt-image-2 | 行业标杆，文字渲染 99%，ELO 1512 |
| T1 | gpt-image-2-ssvip | 同模异池，T1 限流时自动切换 |
| T2 | gemini-3.1-flash-image-preview | 写实 9.3/10，成本极低 |
| T2 | gemini-2.5-flash-image | 稳定锚 |
| T3 | doubao-seedream-4-5-251128 | 兜底，中文生态 |
| T3 | doubao-seedream-4-0-250828 | 终极兜底 |

### 识图（3 通道）

| Tier | 通道 | 特点 |
|------|------|------|
| T1 | Doubao-1.5-vision-pro-32k | 中文原生 VLM，32K 上下文 |
| T2 | gemini-2.5-flash | 英文强，通用性好 |
| T2 | gemini-2.5-flash-ssvip | 同模异池备选 |

链式容错：同 Tier 内并行切换 → 跨 Tier 降级 → 全部失败才报错。单个通道不可用对用户透明。

---

## 安全

- API key 使用 Windows DPAPI 加密存储（`~\.dmxapi\`），绑定当前用户和当前机器
- 脚本不含任何硬编码密钥
- 加密文件被拷贝到其他机器/用户后无法解密
- 分享脚本不会泄露你的 key

---

## 常见问题

**Q: 所有通道都失败了？**
运行 `.\test-pipeline.ps1` 诊断。确认：① DMXAPI 余额充足 ② 后台已勾选全部 9 个模型权限 ③ 网络正常。

**Q: 运行脚本提示"无法加载文件，因为在此系统上禁止运行脚本"？**
以管理员身份运行 PowerShell，执行：
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
然后重新运行脚本。

**Q: Seedream 4.5 返回 HTTP 403？**
DMXAPI 侧已知问题，容错引擎会自动跳过该通道，不影响正常使用。

**Q: 生成图片中文乱码？**
检查 PowerShell 版本 ≥ 5.1。脚本已内置编码修复。

**Q: 如何获得透明背景的图片？**
gpt-image-2 不支持 `Background=transparent`。bgremove 模式输出白底图片。如需真正透明背景，推荐使用 remove.bg 或 Photoshop 等专用工具进行下游处理。

**Q: pip 不是可识别的命令？**
你的 Python 没有加入系统 PATH。重新安装 Python 时勾选 "Add Python to PATH"，或使用完整路径运行 pip。

**Q: 如何更换 API 服务商？**
修改 `dmxapi-auth.ps1` 中的 `$DMXAPI_BASE_URL` 和 `$ModelChannels` 即可。

---

作者：Xi Ewell · Duke Ewell Laboratory
许可证：[CC BY-NC-ND 4.0](LICENSE)
