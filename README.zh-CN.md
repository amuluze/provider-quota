<div align="center">

# Provider Quota

**[Tern](https://stencil.so/tern) 终端的供应商额度面板**——一眼看清所有已配置模型供应商的用量，按余量挑合适的干活。

简体中文 · [English](README.md)

![额度面板截图](docs/screenshot.png)

![Tern](https://img.shields.io/badge/Tern-plugin-blueviolet) ![Luau](https://img.shields.io/badge/Luau-%21strict-blue) ![Version](https://img.shields.io/badge/version-0.1.0-green)

</div>

## 能看到什么

- **供应商全景**——omp 存了凭据的供应商全部出现，不只是 omp 能查用量的那几家：有额度卡片、余额行，或带原因的「未上报」条目。
- **紧急排序 + 推荐**——消耗最多的供应商排最上；余量最足的带 **推荐** 标记。
- **状态栏常驻**——紧凑段（`额度 · 正常 · Weekly 53% · 1 需登录`），随窗口消耗自动升级 警告/耗尽 色调，点击打开面板。
- **直查适配器**——omp 查不到用量的供应商，用 omp 已存的 key 调官方文档接口。密钥只存在于内存与请求头——不落盘、不进日志。

| 供应商 | 数据源 | 展示 |
| --- | --- | --- |
| Z.AI / Anthropic / OpenAI Codex / … | `omp usage --json` | 各窗口余量条、重置倒计时 |
| DeepSeek | `GET api.deepseek.com/user/balance` | 余额（¥） |
| MiniMax CN | `GET api.minimaxi.com/v1/token_plan/remains` | 5 小时 / 本周余量 |
| Kimi Code | `GET api.kimi.com/coding/v1/usages` | 5 小时 / 本周 / 本月余量 |
| OpenCode Go | `GET opencode.ai/zen/go/v1/usage` | rolling / weekly / monthly 余量 |
| 其他 | `omp models --json` 目录 | 「未上报」行 + 模型数 |

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

## 使用

| 操作 | 方式 |
| --- | --- |
| 打开面板 | `ctrl+alt+q`、命令面板搜「打开额度面板」、或点击状态栏段 |
| 手动刷新 | 面板内按 `r`，或点「刷新」按钮 |
| 自动刷新 | 每 60s；失败时保留旧快照并显示原因 |
| 状态栏 | 默认隐藏——命令面板执行「status bar on」 |

面板在**焦点 pane 侧边拆分**打开，重复打开会复用已有面板。

## 工作原理

```mermaid
flowchart LR
  subgraph daemon["会话 daemon · host 半"]
    C["collector<br/>60s 轮询 · 失败保留旧快照"] -->|"omp usage / models"| O["omp（登录 shell）"]
    H["host.luau<br/>dashboard block"] --> C
    C -->|"omp token + 供应商 API"| P["DeepSeek / MiniMax / Kimi / OpenCode"]
  end
  H -->|"快照记录"| KV[("tern.kv<br/>plugin-data/kv.json")]
  subgraph win["每个窗口 · window 半"]
    W["window.luau"] -->|"2s 轮询"| KV
    W --> S["状态栏段"]
    W --> CMD["命令面板 ctrl+alt+q"]
  end
  H --> V["view.luau<br/>统计条 · 卡片 · 余量条"]
```

`host.luau` 通过登录 shell（`$SHELL -l -c`）调 omp，让 shell rc 里的供应商 API key 可见；`window.luau` 半只读取小体积的已发布记录。

## 配置

| 环境变量 | 说明 |
| --- | --- |
| `TERN_QUOTA_BIN` | omp 二进制路径；默认依次找 `~/.local/bin/omp`、Tern 内置 omp、`PATH` |

macOS GUI 启动的 daemon 设置方式：

```sh
launchctl setenv TERN_QUOTA_BIN /path/to/omp
```

## 文件结构

| 文件 | 作用 |
| --- | --- |
| `plugin.toml` | 清单：id、入口、block 声明 |
| `usage.luau` | 纯函数：normalize + 合并、严重度、时长格式化、状态栏摘要 |
| `balances.luau` | 直查适配器：DeepSeek / MiniMax CN / Kimi Code / OpenCode Go |
| `collector.luau` | 采集循环：60s 轮询、超时租约、失败保留旧快照 |
| `view.luau` | 纯渲染：快照 → 原生节点（stats / card / table / meter） |
| `host.luau` | host 半：block、登录 shell 调 omp、token 缓存、直查富化 |
| `window.luau` | window 半：面板命令、状态栏段、kv 变化轮询 |

host 与 window 两半通过 `tern.kv`（`<state>/plugin-data/provider-quota/kv.json`）共享快照。

---

以 [Tern 插件](https://docs.stencil.so/tern/)规范用 Luau 编写（纯函数模块 `--!strict`）。安装 Tern 插件即表示信任它——源码约 700 行，欢迎通读。
