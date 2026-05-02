# MkDocs Site Design

**Date:** 2026-05-02

## Goal

为当前教程仓库增加一套可直接浏览的 MkDocs 文档站点配置，优先展示顶层 `Readme.md`、各章节 `*/Readme.md`，并把 `64_6809_Target/docs/NOTES.md` 作为附录页面纳入站点。

## Scope

本次只解决“教程 Markdown 到网页阅读”的问题，不处理源码文件展示，不处理搜索增强、主题定制、插件扩展，也不继续汉化 `NOTES.md`。

## Constraints

- 仓库现有 Markdown 分散在根目录和各章节目录中，不是 MkDocs 默认的 `docs/` 布局。
- 用户希望尽量忠实复用现有文档，而不是手工维护两份正文内容。
- `NOTES.md` 体量很大，仍需能在站点中正常访问。
- 已安装 `mkdocs`，但仓库中当前没有任何现成的 MkDocs 配置。

## Chosen Approach

采用“轻量站点目录 + 原文档软链接”的方案：

- 新增一个专用的 `docs/` 目录，作为 MkDocs 的 `docs_dir`。
- `docs/` 中不复制正文内容，只放：
  - 首页入口文件
  - 章节文档的软链接
  - `64_6809_Target/docs/NOTES.md` 和相关资源的软链接
- 新增一个很小的脚本，用于根据仓库现有章节结构生成/刷新这些软链接。
- 新增 `mkdocs.yml`，显式维护导航。

这样做的结果是：

- MkDocs 使用标准 `docs_dir`，兼容性最好。
- 教程正文仍以原始文件为准，不会引入手工维护的双份 Markdown。
- 构建后的站点只暴露教程文档，不会把大量 `.c`、`.h`、`Makefile` 等源码文件当静态资源一起发布。

## Rejected Alternatives

### 1. 直接把仓库根目录设为 `docs_dir`

不采用。虽然配置最少，但会把大量非文档文件暴露给 MkDocs，且 `site_dir` 的放置会变得别扭，后续维护也混乱。

### 2. 直接复制所有 Markdown 到 `docs/`

不采用。第一版可行，但长期会形成两套正文，后续章节修订时容易漂移。

## Information Architecture

站点导航采用三层概念：

- 首页
  - 顶层 `Readme.md`
- 教程章节
  - `00_Introduction/Readme.md` 到 `64_6809_Target/Readme.md`
- 附录
  - `64_6809_Target/docs/NOTES.md`

第一版导航不追求花哨分组，只要求顺序清晰、章节命名可读。

## File Layout

计划新增/修改：

- 新增 `mkdocs.yml`
- 新增 `docs/`
- 新增 `docs/index.md`（首页入口，优先使用软链接指向顶层 `Readme.md`）
- 新增 `tools/generate_mkdocs_docs.py` 或同等小脚本
- 脚本生成：
  - `docs/00_Introduction/Readme.md` -> `../00_Introduction/Readme.md`
  - ...
  - `docs/64_6809_Target/Readme.md` -> `../64_6809_Target/Readme.md`
  - `docs/64_6809_Target/docs/NOTES.md` -> `../../64_6809_Target/docs/NOTES.md`
  - `docs/64_6809_Target/docs/` 下正文引用到的图片/PDF 等资源软链接

## Link Strategy

现有文档中的相对链接、图片路径和 `../NN/Readme.md` 形式的“下一步”链接尽量原样保留。

因此生成 `docs/` 时要尽量镜像原来的目录层级，让大多数相对路径无需改写即可工作。

## Build and Verification

最低验证标准：

- `mkdocs build` 成功
- 首页可解析
- 至少抽查以下页面能正确渲染：
  - 首页
  - 一个早期章节
  - 一个中期章节
  - `64_6809_Target/Readme.md`
  - `64_6809_Target/docs/NOTES.md`
- 抽查若干“下一步”相对链接和图片资源链接

## Non-Goals

- 不接入 Material 主题或额外插件
- 不做中文搜索、全文索引或版本化
- 不展示源码树
- 不在本次中清理或重写既有 Markdown 链接结构
