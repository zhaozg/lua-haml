# AGENT.md

> 本文件面向在本仓库工作的 AI 编程助手（以及人类协作者）。
> 目标是让你**在动手前就知道该改哪个文件、改完怎么验证、哪些地方碰了会出事**。
>
> 配套文档：`REFERENCE.md`（语言行为，唯一权威）· `README.md`（对外介绍）· `Changelog.md`（变更历史）

---

## 1. 项目要求（不可协商）

1. **不破坏既有接口**。已有测试用例是兼容性契约，不得为了让新实现通过而修改它们的输入/期望值。确需变更语义时，必须单独说明理由并获得确认。
2. **可以新增用例、提升覆盖率**。修 bug 必须附带能复现该 bug 的用例。
3. **新增特性必须有测试用例**。无测试的特性视为未完成。

---

## 2. 硬性约束（踩了会直接坏事）

| # | 约束 | 原因 |
|---|---|---|
| 1 | **绝不往 `spec/` 写文件** | `spec/` 是指向 `haml-spec` 的 git **子模块**，改动会污染共享仓库、在主仓库里也不可见 |
| 2 | **只写 Lua 5.1 / LuaJIT 兼容代码** | `haml/render.lua:2-3` 在模块顶层做 `local setfenv, loadstring = setfenv, loadstring`，在 5.2+ 上二者为 `nil`，直接崩 |
| 3 | **不引入新依赖** | 运行时依赖仅 `lpeg`；JSON 用的是仓库自带的 `json.lua` |
| 4 | **不要修改 `_options` 中已有默认值** | `haml/init.lua` 的默认值是兼容性契约（99 个上游用例依赖）。新行为请用 opt-in 选项 |
| 5 | **行为变更必须同步 `REFERENCE.md`** | 文档中每个示例都标注「实测验证」，与代码不一致即为缺陷 |

Lua 5.1 兼容的具体禁令：不用 `goto`、不用 `//`、不用位运算符、不用 `<close>`；`unpack` 一律写 `unpack or table.unpack`（参照 `haml/compile.lua:8`）。

---

## 3. 项目地图

| 文件 | 职责 | 什么时候改它 |
|---|---|---|
| `haml/parser.lua` | LPeg 语法 → AST | 新增/修改**语法**（新运算符、新字面量形式） |
| `haml/compile.lua` | AST → 编译后 AST（标签、属性、doctype、注释、块配对） | 改**属性/标签/空元素/doctype** 行为 |
| `haml/render.lua` | 编译后 AST → 字符串（最终 HTML 或 lhtml 中间态） | 改**空白、求值、转义、属性输出** |
| `haml/filter.lua` | 8 个过滤器（`cdata` `css` `escaped` `javascript` `lua` `markdown` `plain` `preserve`） | 改/加过滤器 |
| `haml/util.lua` | `print_r` 调试打印 | 基本不用动 |
| `haml/init.lua` | 公开 API（`parse` / `compile` / `render`）、默认选项、BOM 剥离 | 加选项、改入口 |
| `lhtml.lua` | `<% %>` 占位符 → Lua 源码 | 改**两阶段管道**的中间格式 |
| `luahaml.lua` | CLI | 改命令行行为 |
| `test.lua` | 测试驱动（读 JSON 套件） | 加测试套件、改断言语义 |
| `test_lhtml.lua` | **`lhtml.lua` 的单元测试**（33 条断言，失败退出码 1） | 改 `lhtml.lua` 时必跑 |
| `tests_patch.json` | **本项目自己的回归用例**（4 组 23 例） | 加用例默认放这里 |
| `spec/*.json` | 上游 `haml-spec` 套件（子模块，共 104 例） | 只读，不改 |
| `sample.haml` | 覆盖大部分语法的示例模板 | 端到端验证 |
| `bench.lua` | 性能基准 | 改性能时 |

---

## 4. 架构：两阶段管道（最容易踩的坑）

```
Haml 源码
  │ haml.parse            → AST
  │ haml.compile          → 编译后 AST（已含 <% %> 占位符 / 已求值结果）
  │ haml.render           → 字符串
  ▼
① options.lhaml = true  → 中间态字符串（全部是 <% %> 占位符）
② 默认                  → 尽量直接求值；**解析不了的表达式仍留 <%= %> 占位符**
  │ lhtml(mid)           → 生成 Lua 源码：print([===[文本]===]) / print(tostring(expr))
  │ loadstring(code)()   → 最终 HTML
  ▼
最终输出
```

**核心结论：`haml.render` 的返回值不一定就是最终 HTML。**

- `%p= greeting` 且 `locals` 能解析 → 直接得到 `<p>hi</p>`
- 表达式依赖模板内 `-` 定义的局部变量 → 只能拿到 `<p><%= greeting %></p>`，必须继续走 `lhtml` + `loadstring`

判断该走哪条路径：

| 场景 | 用法 |
|---|---|
| 纯静态模板 | `haml.render(tpl)` 即可 |
| 数据全部从 `locals` 传入 | `haml.render(tpl, opts, locals)` 即可 |
| 模板内用 `-` 声明局部变量再引用 | **必须完整管道**，或用 CLI |
| 不确定 | 用 CLI（`luahaml.lua`），它封装了全部阶段 |

求值时机速查：

| 写法 | 求值位置 |
|---|---|
| `%tag= expr`（可解析） | `haml/render.lua` 的 `try_code`，`pcall` 包裹 |
| `%tag= expr`（不可解析） | 保留占位符，第二阶段执行 |
| 独立行 `=` / `-` | 保留占位符，第二阶段执行 |
| 独立行 `&=` / `!=` / `~` | `haml/compile.lua` **立即** `loadstring`（无 `pcall`） |

---

## 5. 环境与命令

环境已具备：`luajit`（LuaJIT）+ `lpeg` 1.1.0。**`lua`/`lua5.x` 未安装**，一律用 `luajit`。

```bash
luajit test.lua                          # 全部 JSON 套件，通过时输出 "Test all passed"
luajit test_lhtml.lua                    # lhtml 单元测试，通过时输出 "Test all passed (33 assertions)"
luajit test.lua | grep -c '^Ok'          # 统计通过数（当前 127）
luajit luahaml.lua sample.haml           # 端到端渲染
echo '%p hi' | luajit luahaml.lua -s     # 从 stdin 渲染
luajit luahaml.lua -i '%p hi'            # 行内模板
luajit luahaml.lua -p -i '%p hi'         # 看 parse 结果（AST）
luajit luahaml.lua -c -i '%p hi'         # 看 compile 结果
luajit bench.lua sample.haml 1000        # 基准
```

测试耗时约 40ms，可以放心反复全量跑。

### 快速探针（写代码/文档前先自测）

不要凭源码推断输出，用探针确认真实行为：

```lua
-- 存为 /tmp/probe.lua，在本仓库根目录 luajit /tmp/probe.lua
local haml, lhtml = require "haml/init", require "lhtml"

-- 完整管道（等价 CLI 行为），返回最终 HTML
local function full(tpl, opts, locals)
  local mid  = haml.render(tpl, opts, locals)
  local code = table.concat(assert(lhtml(mid)), "")
  local out  = {}
  local env  = { print = function(...) out[#out+1] = tostring((...)) end }
  setmetatable(env, { __index = _G })
  local fn = assert(loadstring(code))
  setfenv(fn, env)
  fn()
  return table.concat(out, "")
end

print(full([[%p= x]], nil, { x = "<b>" }))                    --> <p><b></p>
print(full([[%p= x]], { escape_html = true }, { x = "<b>" })) --> <p>&lt;b&gt;</p>
print(full([[- local t = "Hi"
%h1= t]]))                      --> <h1>Hi</h1>
```

只想看单阶段时，直接用 `haml.render(tpl, opts, locals)`。

### 性能特征（实测，LuaJIT，`sample.haml` 2892 字节）

```
parse + compile + render   ~600 µs
  ├─ parse                 ~320 µs
  ├─ compile               ~120 µs
  └─ render                ~150 µs
```

**parse+compile 是 render 的 2.4 倍；模板越小差距越大**（186 字节模板实测 10.9 倍）。

所以：**编译一次，缓存，反复 render**。`haml.render(compiled_table)` 是受支持的，
而且从 0.4.2 起是幂等的——早期版本 `_recurse` 会就地削掉 AST 的元数据
（`tag`/`space`/`operator`…），同一个编译产物只能渲染一次，第二次只剩一个换行。
`bench.lua` 开头有断言锁住这一点。

```lua
-- 推荐：编译一次
local tpl = haml.compile(haml.parse(source), options)
for _ = 1, n do haml.render(tpl, options, locals) end   -- ~150 µs/次

-- 反例：每次都从头（~600 µs/次）
for _ = 1, n do haml.render(source, options, locals) end
```

其它已做的优化，改动时勿回退：

- `haml/parser.lua` 两个属性 grammar（html-style / ruby-style）是模块级常量——每次重建要 15 µs，是匹配本身的 16 倍。
- `lhtml.lua` 默认 handler 的 grammar 有缓存（自定义 handler 仍每次重建，因为 handler 被编进了 pattern）。
- `haml/render.lua` 尾部三个全串 `gsub` 各自有 `find` 守卫；无 `#{}` 的模板因此省约 30 µs。

---


## 6. 测试怎么写

### 用例格式

`tests_patch.json` 与 `spec/*.json` 结构一致：

```json
{
  "组名（随意，仅用于归类）": {
    "用例名（会打印在 Ok/Fail 后面）": {
      "haml": "%p= x",
      "html": "<p>V</p>",
      "locals": { "x": "V" },
      "config": { "escape_html": true },
      "optional": false
    }
  }
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `haml` | 是 | 输入模板 |
| `html` | 是 | **最终 HTML**（不是中间态） |
| `locals` | 否 | 传给 `render` 的第三参 |
| `config` | 否 | 传给 `render` 的第二参 |
| `optional` | 否 | ⚠️ **测试驱动会忽略该字段**，`true` 也照跑 |

### 关键陷阱

1. **`html` 必须是最终 HTML**。`test.lua` 在比对前会自己跑一遍 `lhtml` + `loadstring`（`test.lua:71-73`），所以要写的是求值之后的最终形态。
2. **属性按字母序输出，用单引号**。`haml/compile.lua:155` 与 `haml/render.lua:175,194` 都会 `sort`，写成 `"<div a='2' z='1'>"`。
3. **别依赖 `pairs()` 顺序**。模板里遍历哈希（如 `sample.haml` 的多语言列表）输出顺序不稳定，不同运行可能不同。测试若涉及多键遍历，请改用 `ipairs` 有序数组。
4. **一个用例产出非法 HTML 会中断整套测试**。`test.lua` 用 `assert(lhtml_compile(html))` 而非 `pcall`，异常会直接抛出、后续套件不再执行。新增用例后若看到 `Test all passed` 缺失，先确认没有崩溃。
5. **`config.sort = true` 是死标志**。`test.lua:60` 设置它，但代码库中无任何地方读取 `options.sort`——排序是无条件发生的。不要以为能靠它关掉排序。

### 加用例的位置

- 修 bug / 加特性 → 追加到 `tests_patch.json`（新建一个组，或并入同名组）
- 新建整个 JSON 文件 → 还需在 `test.lua` 的 `suites` 列表（`test.lua:104-109`）登记
- **不要动 `spec/`**

### 验证回归有效性

新增的回归用例必须在**旧代码上失败**，否则它没有价值：

```bash
git stash                                  # 暂存修复，回到旧实现
luajit test.lua | grep -c '^Fail'          # 应 > 0
git stash pop
```

---

## 7. 常见任务落点

| 任务 | 改哪里 | 配套动作 |
|---|---|---|
| 新增语法运算符 | `haml/parser.lua` 的 `syntax` 表 + `haml/compile.lua` 的 `handle_node` | 两者都要动，并加用例 |
| 改属性输出（引号/顺序/布尔） | `haml/render.lua` 的 `_recurse` 属性分支 + `haml/compile.lua:tag_for` | 检查两条路径都覆盖 |
| 改标签/空元素/doctype | `haml/compile.lua`（`tag_for` / `doctype_for` / `should_auto_close`） | `closed` 表在 `haml/init.lua` |
| 改空白行为 | `haml/render.lua` 的 `inner_ws` / `tight` 递归；`preserve` 逻辑 | 对照 `REFERENCE.md#空白移除` |
| 加过滤器 | `haml/filter.lua` 的 `_filters` 表 + 写一个 `xxx_filter` | 同步 `REFERENCE.md#过滤器` |
| 改求值/转义 | `haml/render.lua`（`try_code`、`escape_html`）+ `haml/compile.lua:186,208` | 注意 `lhaml` 模式行为 |
| 改中间格式 | `lhtml.lua` | 会牵动 CLI 与全部测试，谨慎 |

---

## 8. 代码风格约定

- **全局函数本地化**在文件顶部（`local concat = table.concat`），仓库各模块一致；新增代码请沿用。
- **不要用 `pcall` 吞异常**——除 `try_code` 这类「探测可否求值」的场景外，失败应显式暴露。
- 函数命名沿用小写下划线（`handle_node`、`tag_for`、`try_code`）。
- 注释用英文；面向用户的错误信息保持简短。
- 修改共享表前先 clone（`render.lua` 中 `_recurse` 会把 `node.xxx` 置 `nil` 做单次消费，属既有设计，注意别在同一节点上二次递归）。

---

## 9. 版本与发布

三处需同步（缺一会造成版本漂移）：

1. `VERSION`
2. `haml/init.lua` 顶部 `lit-meta` 块中的 `version`
3. `Changelog.md` 顶部新增小节

```markdown
## 0.4.2

* 一句话说明改了什么，以及**改动前的错误行为**。
```

---

## 10. 已知陷阱（实测，未修）

| # | 现象 | 位置 | 建议 |
|---|---|---|---|
| 1 | `spec/tests_ext.json` 是 **GBK** 编码（含中文），按 UTF-8 读会抛 `UnicodeDecodeError` | `spec/tests_ext.json` | 读取时显式 `encoding='gbk'`；该文件在子模块内，不要改 |
| 2 | CLI 版本号硬编码 `0.2.0`，与模块 `0.4.1` 不一致 | `luahaml.lua:3` | 顺手修时改为读 `VERSION` |
| 3 | `--copyright` 调用未定义的 `show_license` → 崩溃 | `luahaml.lua:146` | 修则补函数，否则移除该分支 |
| 4 | `&=` / `!=` / `~` 在 `haml/compile.lua` 中直接 `loadstring` 且无 `pcall`，表达式非法时抛裸错 | `haml/compile.lua:186,208` | 改造需保持错误信息可读 |
| 5 | `options.sort` 无读取方（死标志） | `test.lua:60` | 不影响功能，勿依赖 |
| 6 | 多行 `\|` 续行**必须每行都以 `\|` 结尾**，漏写则续行静默丢失 | `haml/parser.lua` `multiline_text` | 文档已标注；若要改为容错需加用例 |
| 7 | `%a(flag)` 原子属性在 xhtml 下也输出裸 `flag` | `haml/render.lua` 布尔分支 | 既有用例锁定该行为，改动需确认 |
| 8 | `suppress_eval` / `ugly` 声明了但无实现 | `haml/init.lua` | **不能当安全开关**，模板一律视为可信代码 |
| 9 | **CLI 输出逐次不稳定**：`sample.haml` 含 `pairs(greetings)`，40 次运行产出 4 种不同顺序 | `sample.haml:27` | 同陷阱 #3。比对输出时**不要**用 `cmp`/`md5`，要比较排序后的行或输出集合 |

---

## 11. 交付前自检清单

- [ ] `luajit test.lua` 输出 `Test all passed`（连跑 2 次，排除 `pairs` 顺序导致的偶发）
- [ ] 改动过 `lhtml.lua` → `luajit test_lhtml.lua` 输出 `Test all passed (33 assertions)`
- [ ] 新增用例在旧代码上会失败（回归有效性已验）
- [ ] `luajit luahaml.lua sample.haml` 输出无异常、无 `<%= %>` 残留
- [ ] 改过渲染/解析热路径 → `luajit bench.lua sample.haml 3000`，`render only (cached)` 无意外劣化
- [ ] 行为有变更 → `REFERENCE.md` 对应章节已更新，且示例**实测过**
- [ ] 版本变更 → `VERSION` + `lit-meta` + `Changelog.md` 三处同步
- [ ] `git status` 中**没有** `spec/` 相关改动
- [ ] 提交信息说明「改前错在哪」，而非只写「修复 bug」
