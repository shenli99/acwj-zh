# GitHub Pages Deployment Design

**Date:** 2026-05-02

## Goal

为当前 MkDocs 教程站点接入 GitHub 官方 Pages 发布流程，使站点在内容合并到主分支 `master` 后，能够自动构建并发布到项目站点地址 `https://shenli99.github.io/acwj-zh/`。

## Scope

本次只解决自动发布链路：

- 配置项目站点所需的 MkDocs 站点 URL
- 增加文档构建依赖清单
- 增加 GitHub Actions Pages 工作流
- 让主分支上的提交自动触发构建和部署

不处理自定义域名，不做额外缓存优化，不引入第二套发布分支。

## Current State

- 仓库已经有可构建的 `mkdocs.yml`
- 教程内容通过 `docs/` 软链接镜像供 MkDocs 使用
- 本地 `mkdocs build --strict` 已可通过
- 仓库中还没有 `.github/workflows/` 或任何 Pages 配置

## Constraints

- 用户希望最终从主分支发布，而不是从当前功能分支直接对外
- 仓库当前实际主分支名是 `master`，不是 `main`
- 项目站点托管在仓库路径下，因此资源 URL 需要正确考虑 `/acwj-zh/` 前缀
- 不应把构建产物 `site/` 提交到 git 历史中

## Chosen Approach

采用 GitHub 官方推荐的 Pages 自定义工作流：

1. 主分支 `master` 上的推送触发工作流
2. 工作流安装文档依赖
3. 运行 `mkdocs build --strict`
4. 用 `actions/upload-pages-artifact` 上传 `site/`
5. 用 `actions/deploy-pages` 发布到 GitHub Pages

这样做的原因是：

- 不需要维护 `gh-pages` 分支
- 源码和构建产物完全分离
- 工作流与 GitHub Pages 当前官方发布方式一致

## Repository Changes

预计新增或修改：

- 修改 `mkdocs.yml`
- 新增 `requirements-docs.txt`
- 新增 `.github/workflows/pages.yml`

## MkDocs Configuration

`mkdocs.yml` 需要补充：

- `site_url: https://shenli99.github.io/acwj-zh/`

这样项目站点下的绝对资源与 canonical URL 会与真实访问路径一致。

## Workflow Design

工作流应包含：

- `on.push.branches: [master]`
- `on.workflow_dispatch`
- 最小权限：
  - `contents: read`
  - `pages: write`
  - `id-token: write`
- 并发控制，避免重复部署互相覆盖
- Python 安装
- `pip install -r requirements-docs.txt`
- `mkdocs build --strict`
- 上传 `site/`
- 部署到 Pages

## Dependency Strategy

新增一个单独的文档依赖文件，而不是把包名散落在工作流里：

- `mkdocs`
- `mkdocs-material`
- `pymdown-extensions`

这样工作流、本地复现和后续版本维护会更一致。

## Release Flow

部署生效顺序应为：

1. 当前功能分支完成 Pages 配置
2. 配置被合并进 `master`
3. GitHub 仓库设置中启用 Pages，源选择 GitHub Actions
4. 之后主分支上的提交自动触发发布

## Verification

最低验收标准：

- 本地 `mkdocs build --strict` 继续通过
- 工作流 YAML 结构完整、无明显语法错误
- 依赖文件足以让工作流独立完成 MkDocs 构建
- `mkdocs.yml` 中项目站点 URL 与仓库地址一致
