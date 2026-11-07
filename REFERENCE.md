# Lua Haml 语言参考

> **本文档对应 lua-haml v0.4.1**（见 `VERSION`），**不是** Ruby Haml 的官方文档。
>
> 原始 Ruby Haml 文档请见上游：<https://haml.info/docs/yardoc/file.REFERENCE.html>
>
> **本文所有代码示例均已在本仓库实测验证**（luajit + lpeg）。标注「⚠️ 缺陷」的行为
> 与 Ruby Haml 不一致，请以本文为准。

Lua Haml 是 [Haml](https://haml.info) 标记语言的 Lua 实现。它沿用 Haml 的**语法**，
但脚本语言是 **Lua** 而非 Ruby，并且**不实现** Ruby/Rails 特有的特性。

---

## 目录

- [与 Ruby Haml 的差异](#与-ruby-haml-的差异)
- [架构与使用方式](#架构与使用方式)
- [安全性说明](#安全性说明)
- [选项](#选项)
- [纯文本](#纯文本)
- [HTML 元素](#html-元素)
- [属性](#属性)
- [Class 与 ID](#class-与-id)
- [空元素](#空元素)
- [空白移除](#空白移除)
- [Doctype](#doctype)
- [注释](#注释)
- [Lua 求值](#lua-求值)
- [过滤器](#过滤器)
- [多行](#多行)
- [空白保留](#空白保留)
- [已知缺陷与限制](#已知缺陷与限制)

---

## 与 Ruby Haml 的差异

### 不支持的 Ruby 特性

| 特性 | Ruby Haml 写法 | Lua Haml |
|---|---|---|
| 属性方法 | `%html{html_attrs('fr-fr')}` | ❌ 不支持 |
| 对象引用 | `%div[@user, :greeting]` | ❌ 不支持 |
| `haml_object_ref` | 自定义对象引用类名 | ❌ 不支持 |
| `find_and_preserve` | `= find_and_preserve(...)` | ❌ 用 `~` 或 `:preserve` 替代 |
| Helper 方法 | `surround` / `precede` / `succeed` | ❌ 不支持 |
| Rails XSS 集成 | `Haml::Template.options` | ❌ 不适用 |
| Rails / Sinatra / Turbo | 框架集成 | ❌ 不适用 |
| 编码声明 | `-# coding: utf-8` | ❌ 不支持 |
| 自定义过滤器注册 | `Haml::Filters::Base` + Temple | ❌ 无注册机制 |
| 嵌套 `data`/`aria` 展开 | `%a{:data => {:x => 1}}` | ❌ 解析报错 |
| `:hyphenate_data_attrs` | 选项 | ❌ 不存在 |
| `:cdata` 选项 | 选项 | ❌ 不存在 |
| `:autoclose` | 选项 | 改为 `closed` 表 + `auto_close` 开关 |

### 脚本语言差异

- 所有 `=` / `-` / `&=` / `!=` / `~` 后的代码是 **Lua**，不是 Ruby。
- 块结构使用 Lua 语法（`do ... end`、`for ... do`、`if ... then`），由缩进自动配对。
- `#{}` 插值是**查表**而非表达式求值。

### 仅实现 8 个过滤器

`:cdata`、`:css`、`:escaped`、`:javascript`、`:lua`、`:markdown`、`:plain`、`:preserve`。
详见 [过滤器](#过滤器)。

---

## 架构与使用方式

> ⚠️ **这是最容易踩坑的地方。** `haml.render` 单独调用**只产出中间格式**，
> 动态内容会以 `<% %>` 占位符形式残留，必须经 `lhtml` 二次处理才能真正求值。

### 两阶段管道

```
Haml 源码
   │  haml.parse
   ▼
  AST
   │  haml.compile
   ▼
编译后 AST
   │  haml.render(..., { lhaml = true })
   ▼
lhtml 字符串（含 <% %> / <%= %> 占位符）
   │  lhtml(...)
   ▼
Lua 源代码（print([===[...]===]) / print(tostring(expr))）
   │  loadstring(...)()
   ▼
最终 HTML
```

### 推荐用法：使用 CLI

```sh
lua luahaml.lua my_template.haml > my_template.html
```

CLI（`luahaml.lua`）已封装全部阶段，是最可靠的使用方式。

### 手动执行完整管道

```lua
local haml  = require "haml/init"
local lhtml = require "lhtml"

local tpl = [[
- local title = "Hi"
%h1= title
%ul
  - for i = 1, 3 do
    %li= "item " .. i
]]

-- 阶段 1-3：产出 lhtml 中间字符串
local mid = haml.render(haml.compile(haml.parse(tpl)), { lhaml = true })

-- 阶段 4：转换为 Lua 代码
local code = table.concat(lhtml(mid), "")

-- 阶段 5：执行生成代码，得到 HTML
local html = assert(loadstring(code))()

io.write(html)
```

输出：

```html
<h1>
Hi
</h1>
<ul>

<li>
item 1
</li>
...
</ul>
```

### 直接调用 `haml.render` 的局限

```lua
-- 静态内容：正常
haml.render("%p Hello")
-- => "<p>Hello</p>\n"

-- 动态内容：locals 可解析时直接求值
haml.render("%p= greeting", nil, { greeting = "hi" })
-- => "<p>hi</p>\n"

-- locals 无法解析时，保留占位符交给 lhtml 阶段
haml.render("%p= title")          -- title 未定义
-- => "<p><%= title %></p>\n"
```

**求值规则**（`render.lua` 的 `try_code`）：

- `options.lhaml` 为 `true`（`lhtml` 别名）→ `=` 与 `#{}` 都输出
  `<%= %>` 占位符（供两阶段管道使用）
- 否则 → 尝试用 `locals` 求值
  - 能 `loadstring` 且执行不报错、结果非 `nil` → 直接内联结果
  - 否则 → 回退为 `<%= %>` 占位符（`strict_eval = true` 时改为报错）

**因此**：仅依赖 `locals` 的动态模板可以只用 `haml.render`；
若模板用 `-` 先定义局部变量、再由后续 `=` 引用（同一 Lua chunk 内生效），
则必须走完整管道或用 CLI。

### 位置参数

```lua
haml.render(haml_string_or_compiled, options, locals)
```

| 参数 | 说明 |
|---|---|
| 第 1 个 | Haml 字符串，或已编译的 AST 表 |
| 第 2 个 | 选项表，见 [选项](#选项) |
| 第 3 个 | `locals` 表，供 `#{}` 插值与属性值解析使用 |

### 其他导出函数

| 函数 | 说明 |
|---|---|
| `haml.parse(str)` | 解析为 AST |
| `haml.compile(input, options, locals)` | 编译 AST |
| `haml.render(input, options, locals)` | 渲染 |
| `haml.print_r(t)` | 调试打印 AST |

---

## 安全性说明

> ⚠️ **本节是使用 Lua Haml 前必须阅读的内容。**
> 0.4.3 起，**模板文本**与**来自 `locals` 的数据**走不同的通道：模板仍是代码，
> 数据不再是代码。但模板本身仍必须视为可信输入。

### 1. 模板即代码：生成并执行 Lua

完整管道的最后一环是 `loadstring(generated_code)()`——执行由模板生成的 Lua 代码。
此外，以下路径在编译期直接求值：

- `code_for`（`haml/compile.lua`）— `!=`、`&=`、`~`
- `compile` 对独立成行的 `=` **不再求值**；`=` 统一由 `render` 处理（0.4.3 起）

**结论：Haml 模板必须视为可信代码，绝不能接受用户上传或用户可控的内容。**
模板注入等同于远程代码执行（RCE）。编译期求值现在有 `pcall` 和可读错误，
但不会因此变成沙箱。

### 2. 数据不是代码：`locals` 值会被中和

从 `locals` 进入输出的值（`=`、`#{}`、属性值）会做三件事：

1. 把 `<%` 编码成 `&lt;%`，防止 `lhtml` 阶段把它当作占位符；
2. 把 `#{` 与反斜杠暂存到哨兵后面，等 `render` 的插值/反转义跑完再原样还原；
3. 需要时（`escape_html = true`）先做 HTML 转义。

因此下面这条**不会再执行命令**：

```lua
local evil = "<%= os.execute('touch /tmp/pwn') %>"
haml.render("%p= x", {}, { x = evil })
-- => "<p>&lt;%= os.execute('touch /tmp/pwn') %&gt;</p>"
```

注意边界：

- 只对**数据**生效。模板正文里字面写 `<%= ... %>` 仍是代码。
- 默认 `escape_html = false`，所以数据里的 `<script>` 仍会原样输出（XSS），
  见第 4 条。
- `compile` 的 `!=` / `&=` / `~` 仍执行模板代码，见第 1 条。

### 3. 两阶段模式：`lhaml`（别名 `lhtml`）

`options.lhaml = true`（`lhtml` 是同一开关的别名）时：

- `=` 与 `#{}` 输出 `<%= expr %>` 占位符，**不会**把 `locals` 的值拼进 Lua 源码；
- 第二阶段的执行环境由调用方决定；`locals` 不会自动可见。

```lua
haml.render("%p #{x}", { lhaml = true }, { x = "os.execute(...)" })
-- => "<p><%=x%></p>"      -- 占位符里是模板里的键名，不是 x 的值
```

两阶段模式必须由调用方提供受限的执行环境；CLI 不做沙箱。

### 4. `escape_html` 覆盖什么、不覆盖什么

默认 `false`。为 `true` 时，**0.4.3 起**覆盖：

- `=`（包括独立成行的 `=`，并使用 `locals`）
- `#{}` 插值
- 属性值中由 `locals` 替换出来的部分

不覆盖：

- `:plain` / `:lua` / `:preserve` / `:markdown` 等过滤器的内容
- `!=`
- 模板侧带引号的属性值（`title='#{u}'` 的引号与固定部分是模板代码；
  其中的 `#{}` 仍受第 2 条约束）
- `<script>` / `<style>` 上下文——HTML 实体转义不等于 JS/CSS 转义

若模板拼接不可信数据，建议同时开启 `escape_html` 并按输出上下文做二次处理，
不要把它当成全局开关。

### 5. `strict_eval`：让失败可见

`locals` 无法解析表达式时，默认行为是保留 `<%= %>` 占位符交给第二阶段；
第二阶段能看到完整 `_G`。这是为了兼容“模板里 `-` 定义变量”的用法，但也意味着
**收紧 `locals` 反而会把更多表达式推到全权限阶段**。

```lua
haml.render("%p= os.execute('id')", {}, {})
-- => "<p><%= os.execute('id') %></p>"   （第二阶段还会执行）

haml.render("%p= os.execute('id')", { strict_eval = true }, {})
-- => error: haml: embedded code failed: ...
```

`strict_eval` 只让失败显式化，不是沙箱。

### 6. `setfenv` 不是沙箱

`setfenv(f, locals)` 只改变全局查找。`locals` 未严格限制时，仍可通过
`getmetatable`、`string.rep`、`loadstring` 等路径逃逸。

若确实需要沙箱，应：

1. 在 `locals` 中**显式白名单**允许的函数与变量；
2. 移除或屏蔽 `loadstring` / `load` / `dofile` / `require` / `os` / `io`；
3. 考虑在独立进程或受限解释器中渲染；
4. 开启 `strict_eval`，避免失败后退回全权限阶段。

CLI（`luahaml.lua`）**不是沙箱**：模板代码与生成代码都在宿主进程里执行。

### 7. 深度限制

`compile` 与 `render` 拒绝超过 **200 层**的嵌套，抛
`haml: template nested too deeply`，而不是让 Lua 栈溢出。
`parse` 基于 LPeg，不递归，不受此限制（实测 20000 层可解析）。

### 8. `#{}` 插值不是表达式求值

`#{g}` 是 `locals` 的**单层键名查表**，不做求值（两阶段模式除外，见第 3 条）：

| 写法 | `locals` | 输出 | 说明 |
|---|---|---|---|
| `#{g}` | `{g="HI"}` | `HI` | ✅ 单键名有效 |
| `#{g.en}` | `{g={en="HI"}}` | `g.en` | ❌ 点号路径不支持 |
| `#{1+1}` | `{}` | `1+1` | ❌ 不求值 |
| `\#{g}` | `{g="HI"}` | `#{g}` | ✅ 反斜杠转义 |

未命中时回退为原文键名，可能泄露变量名。

### 9. 过滤器输出不转义

`:plain`、`:lua`、`:preserve`、`:markdown` 的输出不经过 HTML 转义；
这些内容里的 `#{}` 仍会被插值（按第 2 条中和数据），但模板正文中的
`<% ... %>` 会被第二阶段执行。`:markdown` 若接受原始 HTML，还会直接注入。

### 10. 属性值

- 默认（`escape_html = false`）**不转义**数据，只做第 2 条的中和；
- 开启 `escape_html` 后，由 `locals` 替换出的属性值会转义；
- 带引号的模板侧属性值（`title='<b>'`）按模板代码原样输出。

属性值与文本共用同一套求值逻辑（0.4.3 起内联属性也解析 `locals`）。

### 11. `lhtml` 本身的边界

- 文本片段的长括号级数按内容自适应，`!` / `@` 的 `include()` / `at()`
  参数同样处理；正文里出现 `]===]` 之类的序列不会再越界成代码。
- 不成对的 `<%` 现在按**文本**输出，不再静默截断后续页面。
- 直接调用 `lhtml` 时，输入里的 `<% ... %>` 仍会被当作代码；不要把未经中和的
  不可信文本直接喂给 `lhtml`。本库的 `render` 已经在数据侧做了这件事。

---

## 选项

选项通过 `haml.render(template, options, locals)` 或 `haml.compile(input, options, locals)`
的第二个参数传入。默认值定义于 `haml/init.lua` 的 `_options` 表。

### 生效的选项

| 选项 | 默认值 | 说明 |
|---|---|---|
| `format` | `"xhtml"` | 输出格式：`"xhtml"` / `"html4"` / `"html5"` |
| `escape_html` | `false` | 为 `true` 时 `=`、`#{}` 与 `locals` 替换出的属性值做 HTML 转义 |
| `auto_close` | `true` | 空元素自动闭合（**注意：不是 `autoclose`**） |
| `indent` | `"  "` | 缩进字符串（两个空格） |
| `newline` | `"\n"` | 换行符 |
| `preserve` | `{ pre = true, textarea = true }` | 需保留空白的标签 |
| `closed` | 10 个空元素表 | 视为空元素的标签集合，可自定义 |
| `html_escapes` | 5 项映射 | HTML 转义表 |
| `encoding` | `"utf-8"` | **仅写入 XML prolog，不做任何转码** |
| `lhaml` | `nil` | 为 `true` 时输出 lhtml 占位符而非直接求值；`lhtml` 是同一开关的别名 |
| `strict_eval` | `false` | 为 `true` 时无法求值的表达式直接报错，不保留占位符 |
| `markdown` | `nil` | 注入 `:markdown` 过滤器使用的函数 |

### ⚠️ 声明但**无效**的选项

以下选项在 `_options` 中存在，但**实测无任何效果**，请勿依赖：

| 选项 | 实测行为 |
|---|---|
| `suppress_eval` | 全代码库无引用，设置无效 |
| `ugly` | 源码注释 "provided for compatiblity; does nothing" |
| `tidy` | 实测无差异（输出相同） |
| `attribute_wrapper` | 实测无差异（属性仍用 `'`） |
| `adapter` | 仅作标识，无行为 |

### `closed` 默认值

```lua
closed = {
  area = true, base = true, br = true, col = true, hr = true,
  img = true, input = true, link = true, meta = true, param = true,
}
```

自定义示例（实测有效）：

```lua
haml.render("%foo", { format = "html5", closed = { foo = true } })
-- => "<foo>"
```

### `html_escapes` 默认值

```lua
html_escapes = {
  ["'"] = '&#039;',
  ['"'] = '&quot;',
  ['&'] = '&amp;',
  ['<'] = '&lt;',
  ['>'] = '&gt;',
}
```

### 关于 `encoding`

`encoding` 选项**仅**用于生成 XML prolog 中的 `encoding` 属性（实测验证）：

```lua
haml.render("!!! XML", { encoding = "gbk" })
-- => "<?xml version='1.0' encoding='gbk' ?>"
```

Lua Haml **不做任何字符集转换**。输入与输出的编码由 Lua 字符串本身决定。

### 选项合并规则

`haml.render` / `haml.compile` 使用 `merge_tables` 合并选项：
用户传入的选项**逐键覆盖**默认值（浅合并，不递归）。

```lua
-- 只覆盖 format，其余保持默认
haml.render(tpl, { format = "html5" })
```

> 注意：`preserve`、`closed`、`html_escapes` 是**整体替换**而非合并。
> 若需修改其中一项，必须提供完整表。

---

## 纯文本

HTML 文档的很大一部分是纯文本内容。任何未被识别为其他语法的 Haml 行，
都会作为纯文本原样输出（实测验证）。

```haml
%gee
  %whiz
    Wow this is cool!
```

编译为：

```html
<gee>
<whiz>
<three>Wow this is cool!</three>
</whiz>
</gee>
```

> 注意：默认（`tidy = false`）输出**不带缩进**。

HTML 标签也会原样传递。若有一段不想转换为 Haml 的 HTML，可直接嵌入：

```haml
%p
  <div id="blah">Blah!</div>
```

编译为：

```html
<p>
<div id="blah">Blah!</div>
</p>
```

### 转义：`\`

反斜杠转义行首的第一个字符，使原本会被解释的字符作为纯文本输出。

```haml
%title
  = title
  \= title
```

编译为（`title = "MyPage"` 时）：

```html
<title>
MyPage
= title
</title>
```

---

## HTML 元素

### 元素名：`%`

百分号置于行首，紧跟元素名，之后可选修饰符、空格和内容（实测验证）。

```haml
%one
  %two
    %three Hey there
```

编译为：

```html
<one>
<two>
<three>Hey there</three>
</two>
</one>
```

任何字符串都是合法的元素名，Haml 会自动生成开闭标签。

---

## 属性

> ⚠️ **重要**：Hash 风格属性使用 **Ruby 语法**（`=>` 或 `key:`），
> **不是** Lua 表构造器。写作 `{:class => 'foo'}` 或 `{class: 'foo'}`，
> 写 `{class = 'foo'}` 会**解析报错**。

属性有两种语法：**Hash 风格 `{}`** 和 **HTML 风格 `()`**。

> ⚠️ 属性值默认**不自动 HTML 转义**；开启 `escape_html` 后，
> 由 `locals` 替换出的值会转义，模板侧带引号的字面值仍按模板代码输出。
> 详见 [安全性说明](#安全性说明)。

### Hash 风格：`{}`

花括号内是 Ruby 风格的键值对，键前可加 `:`，值可为引号字符串或裸标识符。

```haml
%html{:xmlns => "http://www.w3.org/1999/xhtml", 'xml:lang' => "en", :lang => "en"}
```

编译为：

```html
<html lang='en' xml:lang='en' xmlns='http://www.w3.org/1999/xhtml'></html>
```

> ℹ️ **属性输出顺序已固定**（v0.4.1）：无论属性来自哪个来源，输出前均按名称**字母序**排序，结果可复现。

支持两种 Ruby 风格写法（实测均有效）：

```haml
%div{:class => 'foo'}
%div{class: 'foo'}
```

含特殊字符的键需加引号：

```haml
%html{'xml:lang' => 'en'}
```

> 注意：`{xml: 'en'}` 会被解析为键 `xml`（冒号被当作 Ruby 新语法分隔符），
> 而非 `xml:lang`。

#### 值的语义（实测）

| 写法 | 行为 |
|---|---|
| `{:href => 'u'}` | 输出 `href='u'`（字面值） |
| `{:href => href}` | 从 `locals` 解析变量，输出 `href='<locals 中的值>'` |
| `{:class => ['a','b']}` | 数组，用 `" "` 连接 → `class='a b'` |
| `{:id => ['a','b']}` | 数组，用 `"_"` 连接 → `id='a_b'` |
| `{:k => true}` | 输出 `k='k'`（xhtml）或裸 `k`（html4/html5） |
| `{:k => false}` | **省略该属性**（不输出） |
| `{:k => nil}` | **省略该属性**（不输出） |
| `{:k => 'false'}` | 引号值视为字符串，输出 `k='false'` |
| `{:k => v}`（`v` 为 Lua 布尔） | `true` → 裸 `k`；`false` → 省略 |
| `{:data => {:x => 1}}` | ❌ **解析报错**，嵌套表不支持 |

属性表可跨多行书写：

```haml
%script{:type => 'text/javascript',
  :src => 'a.js'}
```

编译为：

```html
<script src='a.js' type='text/javascript'></script>
```

> ⚠️ **缺陷**：多行属性的值**不支持 Lua 表达式拼接**。
> `{:src => 'script_' .. (2+7)}` 会解析失败。

### `:class` 与 `:id` 属性

`class` 与 `id` 可指定为数组，元素会被连接（实测验证）：

- `class` 数组用 `" "` 连接
- `id` 数组用 `"_"` 连接

```haml
%div{:id => ['a', 'b'], :class => ['x', 'y']}
```

编译为：

```html
<div class='x y' id='a_b'></div>
```

> ⚠️ **与 Ruby Haml 的差异**：Ruby 版会剔除数组中为 `false`/`nil` 的元素，
> Lua Haml **不做此剔除**。若需条件性 class，请在 Lua 代码中预先构造数组。

### HTML 风格：`()`

基于 HTML 属性语法的简洁形式，使用圆括号（实测验证）。

```haml
%html(xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en")
```

实现层面：属性值可以是带引号的字符串，或不带引号的裸名称。

| 写法 | 输出 |
|---|---|
| `%div(class='foo')` | `<div class='foo'></div>` |
| `%input(selected)` | `<input selected />`（裸布尔属性） |
| `%input(selected=true)` | `<input selected='true' />` |
| `%a(href=u) x` | `<a href=u>x</a>`（**不解析 locals，原样输出**） |

> ⚠️ **注意**：HTML 风格中不带引号的值是**原样透传**，不从 `locals` 解析。
> 这与 Hash 风格不同。若需变量解析，请用 Hash 风格。

两种语法可混用：

```haml
%a(title=t){:href => 'x'}
```

编译为：

```html
<a href='x' title='t'></a>
```

> ⚠️ **缺陷**：HTML 风格属性不支持 `#{}` 插值构造值
> （如 `%span(class="w_#{num}")` 不会被展开为变量拼接）。

### 布尔属性

> ✅ **v0.4.1 已修复**：`false` / `nil` 会省略属性，`true` 渲染为 `k='k'`（xhtml）。

| 写法 | xhtml（默认） | html5 |
|---|---|---|
| `%input(selected)` | `<input selected />` | `<input selected />` |
| `%input(selected=true)` | `<input selected='selected' />` | `<input selected>` |
| `%input{:selected => true}` | `<input selected='selected' />` | `<input selected>` |
| `%input{:selected => false}` | `<input />`（省略） | `<input>`（省略） |
| `%input{:selected => nil}` | `<input />`（省略） | `<input>`（省略） |
| `%input{:checked => 'true'}` | `<input checked='true' />` | 同左 |
| `%input{:checked => 'false'}` | `<input checked='false' />` | 同左 |

**规则**（`render.lua` 属性分支）：

- 值恰为未加引号的 `false` 或 `nil` → 属性被**整个省略**
- 值恰为未加引号的 `true` → xhtml 下为 `k='k'`，否则为裸 `k`
- 值带引号（如 `'false'`）→ 视为普通字符串，照原样输出
- Lua 布尔值（如 `%a(flag)` 产生的 `true`）→ 裸 `k`

> ⚠️ 注意：`%a(flag)` 这种「原子属性」在 **xhtml 下也输出裸 `flag`**（而非 `flag='flag'`），
> 这是保留的旧行为。若严格遵循 XHTML 规范，请改写为 `%a(flag=true)`。

### 前缀属性（`data-` / `aria-`）

> ⚠️ **完全不支持嵌套展开。** Ruby Haml 的 `%a{:data => {:author_id => 123}}`
> 在 Lua Haml 中会**解析报错**：`Could not parse attributes`。

若需 data 属性，请直接写完整属性名：

```haml
%a{:href => "/posts", 'data-author-id' => 123, 'data-category' => 7} Posts
```

编译为：

```html
<a data-author-id='123' data-category='7' href='/posts'>Posts</a>
```

> 注意：**没有**下划线自动转连字符功能，也没有 `:hyphenate_data_attrs` 选项。

---

## Class 与 ID

句点 `.` 和井号 `#` 借自 CSS，分别用于指定 `class` 和 `id` 属性（实测验证）。

```haml
%div#things
  %span#rice Chicken Fried
  %p.beans{:food => 'true'} The magical fruit
  %h1.class.otherclass#id La La La
```

编译为：

```html
<div id='things'>
<span id='rice'>Chicken Fried</span>
<p class='beans' food='true'>The magical fruit</p>
<h1 class='class otherclass' id='id'>La La La</h1>
</div>
```

### 隐式 div

由于 div 使用频繁，它是默认元素。若只定义 class 和/或 id，会自动使用 div。

```haml
#collection
  .item
    .description What a cool item!
```

编译为：

```html
<div id='collection'>
<div class='item'>
<div class='description'>What a cool item!</div>
</div>
</div>
```

### Class 合并与顺序

实测顺序为：**标签标识符 → Hash 风格数组 → HTML 风格属性**。

```haml
%div.foo.moo{:class => ['bar','alpha']}(class='baz')
```

实际输出：

```html
<div class='foo moo bar alpha baz'></div>
```

> ⚠️ **与 Ruby Haml 的差异**：Ruby 5.0 的输出是
> `class='foo moo baz bar alpha'`（HTML 风格在 Hash 之前）。
> Lua Haml 的顺序不同，且**不是字母序**。

### ⚠️ 缺陷：id 与 class 混合时的畸形输出

单独合并正常：

```haml
%div#a{:id => 'b'}      -- => id='a_b'      ✅
%div.a{:class => 'b'}   -- => class='a b'   ✅
```

但同时使用 class 简写 + id 简写 + Hash id 时会畸形：

```haml
%div#Article.article{:id => 'x'} Gabba
```

实际输出（**错误**，属性已按字母序排列）：

```html
<div class='article' id="'Article' 'x'">Gabba</div>
```

期望应为 `id="Article_x"`。**请避免这种组合**，改为在 Hash 中一次性写全。

---

## 空元素

行尾的正斜杠 `/` 使 Haml 将其视为空（void）元素（实测验证）。

```haml
%br/
%meta{'http-equiv' => 'Content-Type', :content => 'text/html'}/
```

`format = "html5"` 时：

```html
<br>
<meta content='text/html' http-equiv='Content-Type'>
```

`format = "xhtml"` 时：

```html
<br />
<meta content='text/html' http-equiv='Content-Type' />
```

某些标签在无内容时自动视为空元素（实测验证）：

```haml
%img            -- xhtml => "<img />"    html5 => "<img>"
```

默认列表：`meta`、`img`、`link`、`br`、`hr`、`input`、`area`、`param`、`col`、`base`。

该列表可通过 **`closed`** 选项自定义：

```lua
haml.render("%foo", { format = "html5", closed = { foo = true } })
-- => "<foo>"
```

---

## 空白移除

`>` 和 `<` 用于控制标签附近的空白：

- `>` 移除标签**外部**的所有空白
- `<` 移除标签**内部**的所有空白

可理解为鳄鱼吃空白：`>` 朝外吃外部空白，`<` 朝内吃内部空白。
它们置于标签定义末尾，在 class、id、属性之后，`/` 或 `=` 之前。

`>` 实测有效：

```haml
%img
%img>
%img
```

编译为：

```html
<img /><img /><img />
```

`<` 移除标签与首/尾子节点之间的空白（v0.4.1 起支持嵌套子元素）：

```haml
%div<
  hi
```

编译为：

```html
<div>hi</div>
```

嵌套子元素同样可用：

```haml
%blockquote<
  %div
    Foo!
```

编译为：

```html
<blockquote><div>Foo!</div></blockquote>
```

> 精确语义：`<` 只去掉**包裹标签与子内容之间**的换行，并向下递归；
> **同级子节点之间仍保留换行**。因此：
>
> ```haml
> %p<
>   hello
>   world
> ```
> → `<p>hello\nworld</p>`
>
> ```haml
> %ul<
>   %li a
>   %li b
> ```
> → `<ul><li>a</li>\n<li>b</li></ul>`

> ℹ️ 修饰符必须写在属性**之后**：`%div.a{:id => 'i'}<` 正确，
> `%div.a<{:id => 'i'}` 不会解析属性。

---

## Doctype

用 `!!!` 自动生成文档类型或 XML prolog（实测验证）。

```haml
!!! XML
!!!
%html
  %head
    %title Myspace
```

编译为（默认 `format = "xhtml"`）：

```html
<?xml version='1.0' encoding='utf-8' ?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html>
<head>
<title>Myspace</title>
</head>
</html>
```

### `format = "xhtml"` 时支持的 doctype（实测）

| 写法 | 结果 |
|---|---|
| `!!!` | XHTML 1.0 Transitional |
| `!!! Strict` | XHTML 1.0 Strict |
| `!!! Frameset` | XHTML 1.0 Frameset |
| `!!! 5` | `<!DOCTYPE html>` |
| `!!! 1.1` | XHTML 1.1 |
| `!!! Basic` | XHTML Basic 1.1 |
| `!!! Mobile` | XHTML Mobile 1.2 |
| `!!! RDFa` | ⚠️ 回退为 XHTML 1.0 Transitional（**不支持 RDFa**） |

### `format = "html4"` 时支持的 doctype（实测）

| 写法 | 结果 |
|---|---|
| `!!!` | HTML 4.01 Transitional |
| `!!! Strict` | HTML 4.01 Strict |
| `!!! Frameset` | HTML 4.01 Frameset |
| `!!! 5` | `<!DOCTYPE html>` |
| `!!! 1.1` | ⚠️ 输出 **XHTML 1.1**（跨格式泄漏，实现瑕疵） |
| `!!! Basic` / `Mobile` / `RDFa` | ⚠️ 回退为 HTML 4.01 Transitional |

### `format = "html5"` 时

`!!!` 及其任何变体**始终**为 `<!DOCTYPE html>`（实测全部变体一致）。

### XML prolog 编码

```haml
!!! XML iso-8859-1
```

编译为：

```html
<?xml version='1.0' encoding='iso-8859-1' ?>
```

> 注意：这**仅影响 prolog 文本**，Lua Haml 不做实际转码。

---

## 注释

Haml 支持两种注释：输出到 HTML 的，和不输出的（实测验证）。

### HTML 注释：`/`

```haml
/ hi
```

编译为：

```html
<!-- hi -->
```

正斜杠也可包裹缩进块：

```haml
/
  %p This doesn't render
```

编译为：

```html
<!--
<p>This doesn't render</p>
-->
```

### 条件注释：`/[]`

```haml
/[if IE]
  %a x
```

编译为：

```html
<!--[if IE]>
<a>x</a>
<![endif]-->
```

要生成「downlevel-revealed」条件注释，在方括号前加 `!`：`/![]`。

```haml
/![if !IE]
  You are not using IE.
```

编译为：

```html
<!--[if !IE]><!-->
You are not using IE.
<!--<![endif]-->
```

### Haml 注释：`-#`

连字符紧跟井号表示静默注释，其后内容完全不输出。

```haml
%p foo
-# This is a comment
%p bar
```

编译为：

```html
<p>foo</p>
<p>bar</p>
```

---

## Lua 求值

> ⚠️ 本节所有代码均为 **Lua**，不是 Ruby。
>
> ⚠️ 求值时机取决于选项：
>
> - `options.lhaml = true`（`lhtml` 别名同理）→ `=` 与 `#{}` 都输出
>   `<%= %>` 占位符（两阶段管道）
> - 默认 → **尝试立即求值**；依赖 `locals` 无法解析时回退为占位符
>
> 独立成行的 `&=` / `!=` / `~` 在 `compile.lua` 中总是**立即 `loadstring` 求值**
> （有 `pcall` 与可读错误，但不会变成沙箱）。
> 独立成行的 `=` 自 0.4.3 起由 `render` 使用 `locals` 求值。

### 插入 Lua：`=`

独立成行的 `=` 在 `render` 阶段求值（使用 `locals`，遵循 `escape_html`）：

```haml
= 1 + 1
```

编译为：

```html
2
```

`%tag= expr` 形式在 `locals` 可解析时直接内联（v0.4.1 修复）：

```lua
haml.render("%p= greeting", nil, { greeting = "hi" })
-- => "<p>hi</p>"

haml.render("%p= 1 + 1")
-- => "<p>2</p>"
```

`locals` 无法解析（如变量未定义）时，默认回退为占位符，交给 `lhtml` 阶段：

```lua
haml.render("%p= title")            -- title 未定义
-- => "<p><%= title %></p>"
```

若设置 `strict_eval = true`，这种情况会直接报错，不再把表达式推给第二阶段：

```lua
haml.render("%p= title", { strict_eval = true })
-- => error: haml: embedded code failed: ...
```

这正是 CLI / 两阶段管道的需要：模板里 `-` 定义的局部变量只能在同一 Lua chunk 内可见。
经 CLI 验证：

```haml
%h1= title
```

输出：

```html
<h1>Hi</h1>
```

若 `escape_html` 选项为 `true`，`=`、`#{}` 与 `locals` 替换出的属性值
都会转义 HTML 敏感字符（0.4.3 起；实测验证）：

```lua
haml.render("= '<b>x</b>'")                          -- => "<b>x</b>"
haml.render("= '<b>x</b>'", { escape_html = true })  -- => "&lt;b&gt;x&lt;/b&gt;"
```

> 注意：以 `=` 结尾的标签内**不允许**再嵌套代码。

### 执行 Lua：`-`

连字符后跟 Lua 代码，代码被求值但**不**插入文档。

> **不建议广泛使用**；几乎所有处理逻辑应放在 Lua 代码中，而非模板里。

> ⚠️ **缺陷（实测）**：裸 `-` 语句在 `haml.render` 中会**泄漏 `<% %>` 占位符到输出**：
>
> | 写法 | `haml.render` 直接输出 |
> |---|---|
> | `- foo = 1` | `<% foo = 1 %>` |
> | `- if true then` + 子节点 | `<% if true then %>\n<p>a</p>` |
>
> 只有走完整管道（CLI）才会正确消除占位符。

经 CLI 验证的有效用法：

```haml
- local title = "Hi"
%h1= title
```

### Lua 块

Lua 块与 HTML 标签一样，无需显式闭合，而是**根据缩进自动配对**
（`compile.lua` 的 `match_block`）。

```haml
- for i = 1, 3 do
  %li= "item " .. i
```

经 CLI 输出：

```html
<li>
item 1
</li>
<li>
item 2
</li>
<li>
item 3
</li>
```

条件分支：

```haml
- if x == 1 then
  = "1!"
- elseif x == 2 then
  = "2?"
- else
  = "3."
```

### 空白保留：`~`

`~` 与 `=` 类似，但会对输入执行空白保留（实测验证）。

```lua
haml.render("~ 'a\\nb'")
-- => "a\nb"                      ← pre 之外不生效

haml.render("~ '<pre>a\\nb</pre>'")
-- => "<pre>a&#x000A;b</pre>"     ← pre 内换行转为 &#x000A;
```

即：`~` 仅对 `preserve` 选项中的标签（默认 `pre`、`textarea`）生效。

参见 [空白保留](#空白保留)。

### 字符串插值：`#{}`

> ⚠️ **重要差异**：Lua 无原生字符串插值。Lua Haml 的 `#{}` 是
> **对 `locals` 表做单层查表**，不是表达式求值，**不支持点号路径**。
> 详见 [安全性说明第 5 条](#5--插值不是表达式求值)。

```lua
-- ✅ 单键名有效：locals 作为第 3 个参数传入
haml.render("%p This is #{g}!", nil, { g = "hi" })
-- => "<p>This is hi!</p>"

-- ❌ 点号路径无效
haml.render("%p #{g.en}", nil, { g = { en = "HI" } })
-- => "<p>g.en</p>"

-- ❌ 表达式不求值
haml.render("%p #{1+1}", nil, {})
-- => "<p>1+1</p>"
```

**使用要点**：

1. `#{}` 内只能是 `locals` 的**单层键名**
2. 必须在**调用时**把 `locals` 表作为第 3 个参数传入（实测）：

```lua
haml.render("%p #{hello}", nil, { hello = "hello world!" })
-- => "<p>hello world!</p>"
```

> ⚠️ 在模板内写 `- locals.g = 'hi'` **不能**创建可用插值变量，
> 该赋值只会落到全局表，`#{g}` 仍回退为字面量 `g`。

3. 反斜杠可转义 `#{}`（实测验证）：

```lua
haml.render("%p \\#{g}", nil, { g = "HI" })
-- => "<p>#{g}</p>"
```

插值也可用于[过滤器](#过滤器)中。

#### 注意事项

`#{}` 的匹配使用简单模式 `([\\]*)#{(.-)}`（`render.lua:159`），
而非完整 Lua 解析器。因此：

- 嵌套花括号可能匹配错误
- 含 `}` 的内容会被截断

**推荐做法**：复杂逻辑先在 Lua 中算好，存入 `locals`（用扁平键名），再插值。

### 转义 HTML：`&=`

`&=` 求值 Lua 代码，并对结果中的 HTML 敏感字符转义（实测验证）。

```lua
haml.render("&= '<b>x</b>'")
-- => "&lt;b&gt;x&lt;/b&gt;"
```

若 `escape_html` 选项为 `true`，`&=` 与 `=` 行为相同。

`&` 也可单独使用，使 `#{}` 插值被转义。

#### 行内 `&=`（v0.4.1 起支持）

```lua
haml.render("%p&= x", nil, { x = "<b>" })
-- => "<p>&lt;b&gt;</p>"
```

以前 `%p&= x` 会被当作纯文本输出 `<p>&= x</p>`。

> ⚠️ 行内 `&=` / `!=` 必须能由 `locals` 解析，否则输出空串。

### 不转义 HTML：`!=`

`!=` 求值 Lua 代码，且**永不**转义 HTML（实测验证）。

```lua
haml.render("!= '<b>x</b>'", { escape_html = true })
-- => "<b>x</b>"
```

默认情况下单个 `=` 也不转义。但若 `escape_html` 为 `true`，
`=` 会转义而 `!=` 不会。

`!` 也可单独使用，使 `#{}` 插值不被转义。

#### 行内 `!=`（v0.4.1 起支持）

```lua
haml.render("%p!= x", { escape_html = true }, { x = "<b>" })
-- => "<p><b></p>"
```

---

## 过滤器

冒号表示过滤器。它将缩进块作为输入传给过滤程序，结果加入输出。

```haml
%content
  :markdown
    # Greetings

    Hello, *World*
```

### 支持的过滤器（实测验证，共 8 个）

仅 `haml/filter.lua` 中 `_filters` 表登记以下 8 个：

| 过滤器 | 实测行为 | 依赖 |
|---|---|---|
| `:cdata` | 包裹 `<![CDATA[ ... ]]>` | — |
| `:css` | 包裹 `<style>`；`xhtml` 下另加 `/*<![CDATA[*/` | — |
| `:escaped` | HTML 转义后输出 | — |
| `:javascript` | 包裹 `<script>`；`xhtml` 下另加 `//<![CDATA[` | — |
| `:lua` | 原样输出（**不执行**） | — |
| `:markdown` | Markdown 转 HTML | `markdown` 模块或 `options.markdown` |
| `:plain` | 原样输出，不解析 | — |
| `:preserve` | 保留空白（`\n`→`&#x000A;`，`\r`→`&#x000D;`） | — |

#### `:cdata`（实测）

```lua
haml.render(":cdata\n  x<y")
-- => "<![CDATA[\n  x<y\n]]>"     ← 保留原始缩进
```

#### `:css`（实测）

```lua
-- html5：不加 CDATA（保留原始缩进）
haml.render(":css\n  body{color:red}", { format = "html5" })
-- => "<style>\n  body{color:red}\n</style>"

-- xhtml（默认格式）：加 CDATA
haml.render(":css\n  a{}")
-- => "<style type='text/css'>\n/*<![CDATA[*/\n  a{}\n/*]]>*/\n</style>"
```

> ⚠️ **差异**：Ruby 版有 `:cdata` 选项控制何时加 CDATA。
> Lua Haml 无此选项，仅按 `format == "xhtml"` 硬编码。

#### `:escaped`（实测）

```lua
haml.render(":escaped\n  x<y")
-- => "x&lt;y"
```

#### `:javascript`（实测）

```lua
-- xhtml（默认格式）：加 CDATA
haml.render(":javascript\n  alert(1);")
-- => "<script type='text/javascript'>\n//<![CDATA[\n  alert(1);\n//]]>\n</script>"

-- html5：不加 CDATA
haml.render(":javascript\n  alert(1);", { format = "html5" })
-- => "<script>\nalert(1);\n</script>"
```

#### `:lua`（实测）

原样输出内容，**不执行** Lua（`code_filter` 直接返回 `node.content`）。

```lua
haml.render(":lua\n  x<y")
-- => "  x<y"     ← 保留缩进（与 :plain 不同，后者会去缩进）
```

> 这是 Lua Haml 特有的过滤器名。Ruby 版的 `:ruby` 会执行代码，此处不会。

#### `:markdown`（实测）

```lua
haml.render(":markdown\n  # hi")
-- => "\n<p>  # hi</p>\n"     ← 需正确的 markdown 模块；无模块时行为退化
```

推荐注入：

```lua
local html = haml.render(tpl, { markdown = require("markdown") })
```

> ⚠️ **安全提示**：`:markdown` 的输出**不经过 HTML 转义**。

#### `:plain`（实测）

```lua
haml.render(":plain\n  x<y")
-- => "x<y"
```

#### `:preserve`（实测）

```lua
haml.render(":preserve\n  a\n  b")
-- => "a&#x000A;b"
```

### 未实现的过滤器

以下 Ruby Haml 过滤器**不存在**，使用会抛错 `No such filter "xxx"`（实测全部确认）：

`:sass`、`:scss`、`:erb`、`:ruby`、`:coffee`、`:less`、`:textile`、`:maruku`

### 自定义过滤器

> ⚠️ **与 Ruby Haml 的差异**：Ruby 5.x 提供 `Haml::Filters::Base` 基类
> 与 `Haml::Filters.registered` 注册表，可返回 Temple 表达式。
> **Lua Haml 无过滤器注册机制**——`_filters` 是 `haml/filter.lua` 内的局部表，
> 未对外暴露。

若需扩展，只能修改 `haml/filter.lua` 源码，在 `_filters` 表中添加：

```lua
-- haml/filter.lua
local function my_filter(node, options, parent)
  return node.content  -- 返回字符串，或修改 node 后返回
end

local _filters = {
  -- ... 现有过滤器
  myfilter = my_filter,
}
```

过滤器函数签名：`func(node, options, parent)`

- `node.content`：过滤块的原始文本
- `node.space`：缩进字符串
- `options`：当前选项表
- `parent`：父节点（可能为 nil）

---

## 多行

管道符 `|` 表示多行字符串。置于行尾，表示所有以 `|` 结尾的后续行
会被当作同一行处理（v0.4.1 已修复，之前续行会丢失）。

```haml
%p= 1 + |
  2 |
```

编译为：

```html
<p>3</p>
```

**规则**：

- 首行必须以 `|` 结尾，否则 `|` 视为普通字符
- 每条**续行也必须以 `|` 结尾**（包括最后一行）
- 续行必须缩进（至少一个空格）
- 拼接时 `|` 及其两侧空白被替换为单个空格，行尾空白被去掉
- 支持：行首 `=` / `-` 等脚本、`%tag= expr`、以及普通行内文本

示例：

```haml
%p= table.concat({ |
  'a', |
  'b', |
}, '-') |
```

编译为：

```html
<p>a-b</p>
```

```haml
%p a |
  b |
```

编译为：

```html
<p>a b</p>
```

> ✅ **行中 `|` 不再丢内容**：`%p a | b` 输出 `<p>a | b</p>`。
> 只有「行尾 `|`」才被当作续行标记。

> ⚠️ 若首行以 `|` 结尾但续行**忘了**写 `|`，整个多行规则会回退，
> 续行内容会丢失且不报错。请确保每行都带 `|`。

---

## 空白保留

有时不希望 Haml 缩进文本。`pre` 和 `textarea` 是空白敏感的。

Haml 的处理方式是「保留」换行——在放入文档前将其转换为
HTML 空白转义码 `&#x000A;`。

> ⚠️ **实测限制**：该转换**仅对 `preserve` 选项中的标签生效**
> （默认 `pre`、`textarea`）。

```lua
-- 在 pre 内：换行被转换
haml.render("~ '<pre>a\\nb</pre>'")
-- => "<pre>a&#x000A;b</pre>"

-- 在 pre 外：不做转换
haml.render("~ 'a\\nb'")
-- => "a\nb"
```

字面 `pre` / `textarea` 内的换行**不会**自动转换（实测）：

```lua
haml.render("%textarea\n  = 'a\\nb'", { format = "html5" })
-- => "<textarea>a\nb</textarea>"     ← 未转换
```

字面文本块可用 `:preserve` 过滤器保留（实测有效）：

```haml
%textarea
  :preserve
    line 1
    line 2
```

> ⚠️ **与 Ruby Haml 的差异**：Ruby 版提供 `find_and_preserve` helper，
> **Lua Haml 无此函数**。请用 `~`（配合 `pre`/`textarea`）或 `:preserve` 过滤器。

---

## 已知缺陷与限制

本节汇总**实测确认**的问题。使用前请务必了解。

> v0.4.1 已修复：行内 `=` 求值、行内 `&=`/`!=`、`false`/`nil` 属性省略、`true` 布尔属性、
> 多行 `|` 续行、`<` 嵌套崩溃、属性输出顺序不稳定，以及 `%p= x` + `escape_html` 的崩溃。
>
> v0.4.3 已修复：数据中的 `<%` / `#{}` 越界、`#{}` 与属性不转义、`lhtml` 长括号越界、
> 不成对 `<%` 静默截断、两阶段模式把值拼成代码、编译期求值独立 `=`、解析错误被吞、
> 深嵌套栈溢出，以及内联属性不解析 `locals` 的不一致。

### 影响正确性的缺陷

| # | 问题 | 影响 | 规避方式 |
|---|---|---|---|
| 1 | `%tag= expr` 依赖 `-` 局部变量时仍输出占位符 | 单靠 `haml.render` 拿不到结果 | 走完整管道 / 用 CLI |
| 2 | `- code` 仍以 `<% %>` 占位符输出 | 单靠 `haml.render` 时输出含标记 | 走完整管道 / 用 CLI |
| 3 | 嵌套 `data`/`aria` 表解析报错 | 无法生成 `data-*` 系列 | 手写完整属性名 |
| 4 | `#{}` 不支持点号路径与表达式 | `#{g.en}` 输出字面量 | 扁平化 `locals` 键名 |
| 5 | 属性值默认不转义 | XSS 风险（`escape_html` 可覆盖 `locals` 值） | 开启 `escape_html` 或手动转义 |
| 6 | `<script>` / `<style>` 内的 `#{}` 不做 JS/CSS 转义 | 数据可闭合字符串注入 JS | 不要把不可信数据插进脚本；按上下文转义 |
| 7 | 多行属性值不支持 `..` 拼接 | 解析报错 | 先在 Lua 侧算好 |
| 8 | `%a(flag)` 原子属性在 xhtml 下也输出裸 `flag` | 不严格符合 XHTML | 改写为 `%a(flag=true)` |
| 9 | 多行 `\|` 漏写结尾 `\|` 时续行静默丢失 | 内容丢失且无报错 | 确保每行都带 `\|` |

### 无效选项

| 选项 | 说明 |
|---|---|
| `suppress_eval` | 全代码库无引用，设置无效（**不能当安全开关**） |
| `ugly` | 实测无差异 |
| `tidy` | 实测无差异（输出均不带缩进） |
| `attribute_wrapper` | 实测无差异（始终用 `'`） |

### 与 Ruby Haml 的行为差异汇总

| 项目 | Ruby Haml | Lua Haml（实测） |
|---|---|---|
| Hash 属性语法 | `{:k => v}` | `{:k => v}` 或 `{k: v}`（**非** `{k = v}`） |
| 布尔 `true` | `k='k'`（xhtml） | 一致 |
| 布尔 `false` | 省略属性 | 一致 |
| class 顺序 | 标识符→HTML→Hash | 标识符→Hash→HTML |
| `data` 嵌套展开 | 支持（递归） | ❌ 解析报错 |
| `!!! RDFa` | XHTML+RDFa | 回退 Transitional |
| `#{}` 点号路径 | 支持（Ruby 求值） | ❌ 不支持 |
| 多行 `\|` | 支持 | ✅ 支持（每行需带 `\|`） |
| `<` 空白移除 | 递归压紧子节点 | 只去包裹换行，同级子节点保留换行 |
| `find_and_preserve` | 有 | ❌ 无 |
| 属性方法 / 对象引用 | 有 | ❌ 无 |
| 自定义过滤器注册 | 有 | ❌ 无 |

### 调试技巧

```sh
# 查看解析后的 AST
lua luahaml.lua -p -i '%p Hello'

# 查看编译后的 AST
lua luahaml.lua -c -i '%p Hello'
```

```lua
-- 编程式查看 AST
haml.print_r(haml.parse("%p Hello"))
```

---

## 附录：与 Ruby Haml 文档的对应关系

| 本文档章节 | Ruby Haml 原章节 | 状态 |
|---|---|---|
| [纯文本](#纯文本) | Plain Text | ✅ 一致 |
| [HTML 元素](#html-元素) | HTML Elements | ✅ 一致 |
| [属性](#属性) | Attributes | ⚠️ 语法为 Ruby 风格；无 `data` 嵌套 |
| [Class 与 ID](#class-与-id) | Class and ID | ⚠️ 顺序不同；混合场景有缺陷 |
| [空元素](#空元素) | Empty (void) Tags | ✅ 基本一致 |
| [空白移除](#空白移除) | Whitespace Removal | ✅ 支持（`<` 只去包裹换行） |
| — | Object Reference `[]` | ❌ 不支持 |
| [Doctype](#doctype) | Doctype | ⚠️ 无 RDFa |
| [注释](#注释) | Comments | ✅ 一致 |
| [Lua 求值](#lua-求值) | Ruby Evaluation | ⚠️ 语言改为 Lua；两阶段求值 |
| [过滤器](#过滤器) | Filters | ⚠️ 仅 8 个；无注册机制 |
| — | Helper Methods | ❌ 不支持 |
| [多行](#多行) | Multiline | ✅ 支持（每行需带 `\|`） |
| [空白保留](#空白保留) | Whitespace Preservation | ⚠️ 无 `find_and_preserve` |
| — | Helpers | ❌ 不支持 |
| — | Rails XSS Protection | ❌ 不适用 |
| — | Encodings | ❌ 不支持 |
| — | Turbo | ❌ 不适用 |

---

## 许可

MIT License。详见 [README.md](README.md)。
