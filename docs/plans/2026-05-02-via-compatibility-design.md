# Via Compatibility Design

## Context

移动端文档站在 Edge 和 Chrome 上表现正常，但在 Via 浏览器中左侧导航显示异常。现有站点基于 Material for MkDocs，并叠加了较多自定义样式，里面使用了 `color-mix()`、`backdrop-filter` 等较新的 CSS 特性。对于兼容性较弱的安卓浏览器内核，这类特性更容易触发布局退化。

## Goal

在不重写导航结构的前提下，让不支持这些新 CSS 特性的浏览器尽量正常浏览；如果关键特性缺失，则明确提示用户当前浏览器兼容性有限，并建议改用 Chrome / Edge。

## Approaches

### A. 样式降级 + 运行时兼容提示

先为关键视觉效果提供保守回退样式，再用一小段前端脚本检查关键 CSS 特性是否支持；如果不支持，就显示一条可关闭提示。

优点：
- 改动范围小，不碰 Material 的导航逻辑
- 对现代浏览器无副作用
- 兼顾“尽量可用”和“必要时提示”

缺点：
- 不能保证所有旧内核都完全恢复一致视觉
- 需要维护一小段前端检测脚本

### B. 去掉所有新 CSS 特性

直接移除 `color-mix()`、`backdrop-filter` 等写法，统一退回更保守的静态样式。

优点：
- 兼容性最好
- 不需要脚本检测

缺点：
- 会明显削弱当前主题视觉质量
- 对现代浏览器也一刀切降级

### C. 仅提示用户更换浏览器

保留现有视觉和 CSS，不做降级，只加一个兼容性提示。

优点：
- 实现最简单
- 风险最低

缺点：
- 实际可用性没有改善
- 依赖用户自行切换浏览器

## Recommendation

采用 A。它是最小且合理的工程折中：先让页面具备稳妥回退，再在检测到特性缺失时提示用户。这样即使 Via 不能完整支持当前样式，也不会只能靠人工猜测问题。

## Scope

- 修改 `docs/stylesheets/extra.css`
- 修改 `overrides/main.html`
- 新增一个构建后检查脚本，验证兼容提示和关键检测逻辑已经进入生成产物

## Verification

- `mkdocs build --strict`
- `bash tools/check_mobile_nav.sh`
- `bash tools/check_homepage_links.sh`
- 新增兼容性检查脚本，验证生成站点包含降级提示和检测逻辑
