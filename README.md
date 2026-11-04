# Provider Quota（额度面板）

Tern 插件：展示**所有已配置**模型供应商的使用额度，方便按余量选择合适的供应商干活。

数据来自两条 omp 命令加直查适配器，不保存任何密钥：

- `omp usage --json`：已登录账户的限额报告、OAuth 失效凭据、无用量端点的账户
- `omp models --json`：模型目录——凡是配置了凭据（API key 或 OAuth）的供应商都会出现，附模型数
- **直查适配器**（`balances.luau`）：omp 查不到用量的供应商，用 `omp token` 取 key 后直查官方端点——DeepSeek 余额、MiniMax CN 订阅余量（5 小时/本周）、Kimi Code 配额（5 小时/本周/本月）、OpenCode Go 用量（rolling/weekly/monthly）。密钥只进请求头，不落盘

两者合并成供应商全景：有额度/余额数据的显示余量条与重置倒计时（omp 报告的 + 直查适配器补的）；没有任何用量端点的列在「未上报额度」卡片；OAuth 失效的列在「需要重新登录」卡片。余量最充足的供应商带「推荐」标记。

## 功能

- **额度面板**（block `provider-quota.dashboard`）
  - 统计条：已配置 / 正常 / 偏低 / 耗尽 / 需登录
  - 每个有额度的供应商一张卡片：各额度窗口的余量条、剩余百分比、用量计数、重置倒计时，按紧急程度排序
  - 「推荐」标记：当前剩余最多的供应商，一眼可挑
  - 「未上报额度」卡片：列出无用量端点的已配置供应商（附模型数）；直查被上游拒绝时显示原因（如 OpenCode「key 已过期」）
  - 「需要重新登录」卡片：OAuth 失效凭据及原因
  - 按 `r` 或点击「刷新」立即重新采集；每 60s 自动刷新
- **状态栏段**（window 半）：`额度 · 正常` + 最紧的 2 个额度 + 需登录数，点击打开面板
- **命令面板**：`打开额度面板`（默认 `ctrl+alt+q`），在当前 tab **侧边拆分**打开小窗，复用已打开的面板

## 安装

```sh
tern plugin install github.com/amuluze/provider-quota
```

更新到最新版：

```sh
tern plugin install github.com/amuluze/provider-quota --force
```

开发模式（改动即时生效）：

```sh
git clone https://github.com/amuluze/provider-quota && tern plugin link ./provider-quota
```

打开方式：命令面板搜「打开额度面板」或「New Provider Quota block」，或 `ctrl+alt+q`。

## 配置

| 环境变量 | 说明 |
| --- | --- |
| `TERN_QUOTA_BIN` | omp 二进制路径；默认依次找 `~/.local/bin/omp`、Tern 内置 omp、`PATH` |

daemon 环境里设置（Tern.app 启动的 daemon 继承其环境）：

```sh
launchctl setenv TERN_QUOTA_BIN /path/to/omp   # macOS GUI 进程
```

## 文件结构

| 文件 | 作用 |
| --- | --- |
| `plugin.toml` | 清单：id、入口、block 声明 |
| `usage.luau` | 纯函数：normalize `omp usage --json`、合并模型目录、严重度、时长格式化、状态栏摘要 |
| `balances.luau` | 直查适配器：DeepSeek / MiniMax CN / Kimi Code / OpenCode Go 的端点与响应解析 |
| `collector.luau` | 采集循环：60s 轮询、超时租约、失败保留旧快照 |
| `view.luau` | 纯渲染：快照 → 原生节点（stats/card/table/meter） |
| `host.luau` | host 半：定义 block、登录 shell 调 omp、token 缓存、直查富化、5s tick |
| `window.luau` | window 半：面板命令、状态栏段、2s 轮询 kv 变化 |

host 与 window 通过 `tern.kv`（`<state>/plugin-data/provider-quota/kv.json`）共享快照记录。

## 排障

- Kimi Code 配额：`KIMI_API_KEY` 是 Kimi Code（api.kimi.com/coding/）的 key，面板直查 `GET /coding/v1/usages`（与官方 CLI `/usage` 同源，api.kimi.ai 国际区、api.moonshot.ai 旧全球区自动回退），按 5 小时/本周/本月窗口显示。
- OpenCode Go 已有官方查询接口：`GET https://opencode.ai/zen/go/v1/usage`（rolling/weekly/monthly 三个窗口的消耗百分比与重置时间，Zen API key 认证），面板已接入。omp 里存的 key 过期时会在 OpenCode Console（opencode.ai → workspace → API keys）重建后自动恢复——omp 存的旧 key 重新登录不会续期，需新建 key 更新凭据。

- 供应商缺一家：omp 从**环境变量**读 API key（如 `KIMI_API_KEY`），而 GUI 启动的 daemon 看不到 shell rc 里的变量。本插件已通过用户登录 shell（`$SHELL -l -c`）调 omp 继承 rc 环境；若变量写在仅交互 shell 加载的文件（如 `.zshrc`）里仍可能缺失，移到 `~/.zshenv` 或用 `omp auth import` 存进凭据库。
- 面板显示「无法启动 omp」：daemon 的 PATH 找不到 omp，设 `TERN_QUOTA_BIN` 后 `tern plugin reload`。
- 状态栏无段：Tern 默认隐藏状态栏，命令面板执行「status bar on」。
- 看插件日志：`STENCIL_LOG=warn,stencil=info,tern::plugin=debug` 启动 daemon。
