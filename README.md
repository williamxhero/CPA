# CPA

CPA 是用于统一发布和管理 SPEC 的主库。实现阶段，再将 SPEC 分配到对应的独立 `CPA-*` 子库；本库不包含源码、不使用 submodule，也不建立 sub-repository 关系。

## 子库

| 子库 | GitHub 地址 | 一句话描述 |
| --- | --- | --- |
| CPA-Aliyun-Quota | [williamxhero/CPA-Aliyun-Quota](https://github.com/williamxhero/CPA-Aliyun-Quota) | 只读读取阿里云百炼 Token Plan 用量，并保留 BSS 账户余额与月消费查询能力。 |
| CPA-Core-ex | [williamxhero/CPA-Core-ex](https://github.com/williamxhero/CPA-Core-ex) | 提供兼容 OpenAI、Gemini、Claude 和 Codex 协议的统一 API 服务，并负责多 provider 凭证路由。 |
| CPA-Manager-Plus-ex | [williamxhero/CPA-Manager-Plus-ex](https://github.com/williamxhero/CPA-Manager-Plus-ex) | 提供 CPA/CLIProxyAPI 管理面板，以及请求、用量、成本、额度、失败和账户健康度观测。 |
| CPA-OpenCode-ex | [williamxhero/CPA-OpenCode-ex](https://github.com/williamxhero/CPA-OpenCode-ex) | 提供 OpenCode Go 计划模型的 CLIProxyAPI 插件，统一支持多种请求协议。 |
| CPA-Qwen | [williamxhero/CPA-Qwen](https://github.com/williamxhero/CPA-Qwen) | 将阿里云百炼 Qwen Coding/Token Plan 作为 CPA 原生 provider，提供凭证、额度和兼容协议支持。 |
| CPA-Usage-Keeper-ex | [williamxhero/CPA-Usage-Keeper-ex](https://github.com/williamxhero/CPA-Usage-Keeper-ex) | 独立的 CPA 用量追踪服务，使用 SQLite 保存历史并提供内置仪表板。 |

新的 SPEC 统一提交到本库的 GitHub Issues；实现时再关联到具体子库。

## 当前重点大项

- [SPEC：Hermes 兼容官方最新 GPT 模型与 Responses/Image 能力](https://github.com/williamxhero/CPA/issues/28)：由 CPA 内部完成 Chat Completions 到官方 Responses 的协议适配、工具超过 128 个时的延迟工具搜索、能力一致的凭证回退，以及 `gpt-image-2.6` 的图像专用路由。Hermes 无需修改；目标模型包括 `gpt-6.1-sol`、`gpt-6-astra`、`gpt-6.1-terra` 和 `gpt-image-2.6`。
- [SPEC：CPA 错误分类、Provider 不可用与统一自动重试](https://github.com/williamxhero/CPA/issues/35)：统一管理可恢复传输错误、provider overload、429/5xx、凭证轮换、等待/backoff、重试预算和最终脱敏聚合错误；Codex TLS EOF 容错为子 SPEC [#34](https://github.com/williamxhero/CPA/issues/34)。
