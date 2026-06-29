# Codex Status Bar

一个 macOS 状态栏小工具，用来实时查看 Codex 的任务状态、5 小时用量、周用量以及可用重置次数。

> 非官方项目。它依赖本机 Codex 客户端的本地日志、认证文件和当前内部接口；如果 Codex 客户端后续调整实现，相关解析逻辑可能需要同步更新。

<p align="center">
  <img src="Resources/AppIcon.png" width="120" alt="Codex Status Bar app icon">
</p>

<p align="center">
  <img src="docs/assets/preview.jpg" alt="Codex Status Bar preview">
</p>

## 功能

- 在 macOS 状态栏直接显示关键信息，无需点开展开面板：
  - 当前任务状态
  - 5 小时剩余用量和刷新时间
  - 周剩余用量和刷新时间
  - 剩余可用重置次数和最早过期时间
- 每 5 秒刷新一次额度信息。
- 每 1 秒刷新一次任务状态。
- 当 Codex 处于需要用户确认、审批或等待输入的状态时，状态栏会闪烁提醒。
- 点击状态栏可查看更完整的详情面板，包括每一次可用重置次数的过期时间。
- 菜单栏常驻运行，不显示 Dock 图标。

## 截图

状态栏文本示例：

```text
运行中:思考中 | 5h 72%/19:52 | 周 84%/7/6 09:51 | 重置 2次/7/27 07:59
```

展开面板会显示：

- 当前任务状态
- 5 小时剩余用量
- 周剩余用量
- 剩余可用重置次数
- 每一次可用重置的过期时间

## 系统要求

- macOS 14 或更高版本
- Xcode Command Line Tools
- Swift 5.9 或更高版本
- 已安装并登录 Codex 桌面客户端

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

## 安装和运行

克隆仓库：

```bash
git clone git@github.com:andeyibiao/codex-status-bar.git
cd codex-status-bar
```

构建并运行：

```bash
script/build_and_run.sh
```

验证应用是否成功启动：

```bash
script/build_and_run.sh --verify
```

脚本会生成并启动：

```text
dist/CodexStatusBar.app
```

如果你想长期使用，可以把构建后的 app 拷贝到 `/Applications`：

```bash
cp -R dist/CodexStatusBar.app /Applications/
```

## 数据来源

这个工具为了尽量和 Codex 客户端自身展示保持一致，会读取或调用以下本机可用数据源：

- 额度信息：通过 Codex 客户端 app-server 调用 `account/rateLimits/read`
- 可用重置次数明细：使用本机 Codex 登录信息请求 ChatGPT 后端的 reset credits 数据
- 当前任务状态：读取本机 `~/.codex/logs_2.sqlite` 中的 Codex 运行日志

状态推断会识别常见阶段：

- `空闲`
- `运行中`
- `思考中`
- `执行命令`
- `调用工具`
- `修改文件`
- `输出中`
- `等待确认`
- `已完成`
- `失败`

## 隐私说明

- 应用不采集、不上传你的项目代码。
- 应用会读取本机 Codex 日志数据库 `~/.codex/logs_2.sqlite` 来推断任务状态。
- 应用会读取本机 `~/.codex/auth.json` 中的 Codex 登录信息，用于请求 reset credits 明细。
- 除了请求 ChatGPT/OpenAI 相关接口获取额度和重置次数外，应用没有自己的第三方后端。

请只在你信任的本机环境中运行。

## 项目结构

```text
.
├── Package.swift
├── Resources/
│   ├── AppIcon.icns
│   └── AppIcon.png
├── Sources/CodexStatusBar/
│   ├── App/
│   ├── Models/
│   ├── Services/
│   ├── Stores/
│   ├── Support/
│   └── Views/
└── script/
    └── build_and_run.sh
```

## 开发

构建：

```bash
swift build
```

运行：

```bash
script/build_and_run.sh
```

查看日志：

```bash
script/build_and_run.sh --logs
```

调试：

```bash
script/build_and_run.sh --debug
```

## 已知限制

- 这是一个非官方工具，不使用公开稳定 API。
- Codex 客户端的日志格式、app-server 方法或认证文件结构变化后，可能需要更新解析逻辑。
- 首次运行时，如果 macOS 阻止打开未签名应用，需要在系统设置中允许打开，或从源码本地构建运行。
- 当前没有偏好设置界面，刷新间隔和展示字段写在代码里。

## License

尚未添加许可证文件。开源发布前建议补充 `LICENSE`，例如 MIT License。
