# FIXME：安全审计记录

> 审计日期：针对 `0.4.2`（commit `60ae51f`）之后的工作树。
> **每一条都经过实测复现**，命令与真实输出直接附在条目内，未复现的推测一律标注「未验证」。
> 未实现修复的条目保持打开，修完后请把结论移到 `Changelog.md` 并在此条目标记 `已修复 @<commit>`。

## 威胁模型（先读这一节）

当前实现的安全边界是**单一假设**：模板完全可信。

`REFERENCE.md#安全性说明` 已经写明「模板必须视为可信代码」。本文件记录的是**这条假设之外的漏洞**，以及**打破这条假设后的实际可利用性**。

按此假设，风险分为两档：

| 档 | 前提 | 条目 |
|---|---|---|
| **A. 假设被打破即 RCE** | 模板文本或任一变量含不可信内容 | S1、S2、S5 |
| **B. 即使模板可信也会出事** | 仅需一个不可信变量进入 `#{}` 或属性 | S1（数据侧）、S3、S4 |
| **C. 可用性问题** | 与信任无关 | S6、S7、S8、S9 |

**关键结论：S1 属于 B 档。** 也就是说「模板可信即可」这条现有边界是**不充分的**——只要有一个用户变量进入 `#{}` 或属性值，即可获得 RCE，而不只是 XSS。这一点 `REFERENCE.md` 目前没有覆盖，需要在修复前更新文档。

---

## 修复状态（0.4.3）

复核后按本文顺序修复，细节见 `Changelog.md#043`。下表是当前状态；
每条的原始复现与根因保留在下面，不再删除。

| 条目 | 状态 | 说明 |
|---|---|---|
| S1 定长括号 | 已修复 | `lhtml` 文本 / `!` / `@` 与 `luahaml` 的 `io.write` 都按内容自适应级数 |
| S2 受限 locals 回退 | 已修复（opt-in） | 新增 `strict_eval`；默认行为保持兼容，文档已写明回退语义 |
| S3 `#{}` 不转义 | 已修复 | `escape_html = true` 时 `#{}` 走同一转义 |
| S4 属性不转义 | 已修复 | `escape_html = true` 时 `locals` 替换出的属性值转义 |
| S5 compile 期执行 | 部分修复 | `=` 移出 compile 阶段；`!=` / `&=` / `~` 按语义仍在编译期执行，已加 `pcall` 与文档声明 |
| S6 深嵌套 | 已修复 | `compile` / `render` 上限 200 层，抛明确错误 |
| S7 CLI 全局可读 | 已修复（语义澄清） | 移除假 `_ENV`；CLI 明确声明为**非沙箱** |
| S8 table 值 concat | 已修复 | `#{}` 值统一 `tostring` |
| S9 属性行为不一致 | 已修复 | 内联属性改为在 `render` 阶段解析 `locals` |
| N1 数据里的 `<% %>` | 已修复 | 数据侧把 `<%` 编码为 `&lt;%` |
| N2 `=`/属性值二次插值 | 已修复 | 数据里的 `#{` 暂存到哨兵，插值后还原 |
| N3 `lhtml` 选项拼代码 | 已修复 | 两阶段模式只输出 `<%= match %>`；`lhaml` / `lhtml` 互为别名 |
| N4 `lhtml` 静默截断 | 已修复 | 不成对的 `<%` 按文本输出 |
| N5 `!`/`@` 零级括号 | 已修复 | 与 S1 共用自适应级数；数据侧已无法伪造 `<%` |
| N6 parse 吞错 | 已修复 | 解析错误上抛；CLI 返回非零退出码 |
| N7 其余 | 部分修复 | `= 1+1` + `escape_html`、属性布尔值、反斜杠保留已修；`:escaped` / `:javascript` 内插值的上下文转义仍是已知限制（见 `REFERENCE.md#已知缺陷与限制`） |

修复后的回归：`test.lua` 137 例、`test_lhtml.lua` 37 条断言、
`test_security.lua` 12 条断言。

---

## S1（严重 / B 档）定长括号，正文可突破为 Lua 代码

### 位置

- `lhtml.lua:20` — `print([===['..code..']===])`（三级）
- `luahaml.lua:87` — `io.write([====[%s]====])`（四级）
- `luahaml.lua:75` — `']====]) io.write(' .. slashes .. match .. ') io.write([====['`（四级，用于代码内插值）

### 根因

`lhtml` 把**模板正文**和**生成的 Lua 代码**拼进同一个字符串，靠固定级数的长括号分隔。级数是硬编码的，正文里只要出现对应的终止符，就从「数据」越界成「代码」。没有任何转义层——这是 SQL 字符串拼接注入的同构问题。

注意同一管线内级数还不统一（三级 / 四级），说明这是逐处手写的，没有统一封装。

### 复现 A：恶意模板文本，走真实 CLI

```bash
printf "%%p ]====]) os.execute('touch /tmp/pwn6') print([====[\n" > /tmp/evil.haml
cat /tmp/evil.haml
luajit luahaml.lua /tmp/evil.haml
ls -l /tmp/pwn6
```

实测输出：

```
%p ]====]) os.execute('touch /tmp/pwn6') print([====[
<p></p>

>>> /tmp/pwn6 已创建：CLI 端到端命令执行成功，退出码 0
```

渲染结果看起来完全正常（`<p></p>`），命令已执行，**没有任何报错**。模板作者无法察觉。

### 复现 B：不可信数据经 `#{}` 注入（模板可信也不够）

```lua
local haml  = require "haml/init"
local lhtml = require "lhtml"

local evil = "]===]) os.execute('touch /tmp/pwn5') print([===["   -- 攻击者提供的数据
local mid  = haml.render("%p " .. evil, {}, {})                     -- 模板本身是可信的
local code = table.concat(assert(lhtml(mid)), "")
```

实测：

```
中间态:    <p>]===]) os.execute('touch /tmp/pwn5') print([===["</p>       ← 数据原样进入正文
生成代码:  print([===[<p>]===]) os.execute('touch /tmp/pwn5') print([===[</p>]===])
loadstring: 通过（语法合法！）
/tmp/pwn5 被创建? true
```

`#{}` 不做 HTML 转义（见 S3），所以攻击者数据原样落进正文，直接决定生成代码的语法结构。

同理 `:plain` 过滤器：

```bash
printf ':plain\n  ]====]) os.execute("touch /tmp/f3") print([====[\n' > /tmp/pf.haml
luajit luahaml.lua /tmp/pf.haml      # → /tmp/f3 已创建
```

### 影响

任意命令执行（RCE），且**无报错、输出正常**。这是本文件中最严重的一条。

### 修复方案

长括号级数按正文内容自适应：扫描正文中最长的 `]=*]` 连续序列，级数取 `N + 1`。

- 改动局限在 `_totable`（`lhtml.lua` 与 `luahaml.lua` 各一处）
- 无行为变更风险，纯收敛
- 建议抽成一个函数 `long_bracket(s) -> level` 供两处共用，顺便消掉三级 / 四级不统一

---

## S2（严重 / A 档）受限 `locals` 的失败回退把表达式推给全权限第二阶段

### 位置

- `haml/render.lua:27-40` — `try_code` 失败时 `return nil, false`
- `haml/render.lua:84` 起 — 调用方据此**保留 `<%= %>` 占位符**而非报错
- `luahaml.lua:154-155` — `local _ENV = {}; setmetatable(_ENV, { __index = _G })`

### 根因

`try_code` 用 `setfenv(f, locals)` 在受限环境里试求值。失败时**不报错**，而是把表达式原样留成占位符，交给 lhtml 第二阶段执行。而第二阶段的 `_ENV` 通过 `__index = _G` 读取全部全局。

于是出现方向性错误：**`locals` 给得越严格，被挡下的表达式越多，被推去全权限执行的就越多。**

### 复现

```lua
local haml  = require "haml/init"
local lhtml = require "lhtml"

-- 第一阶段：locals 传空表（最严格）
local mid = haml.render("%p= os.execute('touch /tmp/pwn2')", {}, {})
--> "<p><%= os.execute('touch /tmp/pwn2') %></p>"     ← 被挡住，文件未创建

-- 第二阶段：照原样执行
local code = table.concat(assert(lhtml(mid)), "")
--> print([===[<p>]===])print(tostring( os.execute('touch /tmp/pwn2') ))print([===[</p>]===])
-- 执行后 /tmp/pwn2 存在 → true
```

CLI 环境中的可达全局实测：

```
luajit luahaml.lua -i '%p= tostring(_G ~= nil)\n%p= type(os)\n%p= type(debug)\n%p= tostring(os.getenv("HOME"))'
→ true / table / table / /Users/zhaozg
```

`_G`、`os`、`io`、`debug` 全部可达。

### 影响

- `REFERENCE.md#3.-setfenv-不是沙箱` 给出的建议「在 `locals` 中显式白名单允许的函数与变量」**在完整管道下无效**——白名单只会把代码推后执行。该建议仅在只用 `haml.render` 而不接 lhtml 时成立。
- 任何试图通过收紧 `locals` 做隔离的努力都会反向削弱安全性。

### 修复方案

加 opt-in 选项 `strict_eval`：置 `true` 时 `try_code` 失败即抛错（含行号），不保留占位符。

- 默认保持 `false`，不破坏现有 99 个上游用例
- 这是给使用者的**逃生阀**，同时为将来默认收紧留出路径
- 文档需明确：完整管道下 `strict_eval = false` 时 `locals` 不具备隔离意义

---

## S3（中 / B 档）`escape_html = true` 不覆盖 `#{}` 插值

### 位置

`haml/render.lua:236-240`

```lua
local val = locals and locals[match] or match
if options.lhtml then
  return '<%=' .. val .. '%>'
end
return slashes .. val          -- 第 240 行：直接拼接，全程未调用 escape_html
```

### 复现

```lua
local p = "<script>alert(1)</script>"
haml.render("%p= x",         {escape_html = true}, {x = p})
--> <p>&lt;script&gt;alert(1)&lt;/script&gt;</p>        ✅ 已转义

haml.render("%p Hello #{x}", {escape_html = true}, {x = p})
--> <p>Hello <script>alert(1)</script></p>              ❌ 未转义
```

`=` 走 `try_code` 分支（`render.lua:84` 附近，有 `escape_html` 调用），`#{}` 走尾部的 `gsub`，是**两套独立求值机制**，转义只在前一套里。

### 影响

`REFERENCE.md#4.-escape_html-默认关闭` 写着「若模板中拼接了不可信数据，必须显式开启 `escape_html`」。实测表明该建议**不充分**：开启后 `#{}` 仍然裸输出，形成 XSS。叠加 S1 后升级为 RCE。

同时这里也是 S1 复现 B 的数据入口。

### 修复方案

第 240 行改为经 `escape_html(val, options.html_escapes)` 输出。

- 会改变现有输出 → 需同步 `REFERENCE.md` 并补回归用例
- 注意 `options.lhtml` 分支（第 238 行）同样未转义，需一并处理
- `#{g}` 语义（单层键名查表）保持不变，只加转义

---

## S4（中 / B 档）属性值从不转义

### 位置

`haml/render.lua` 属性拼装处（`A[#A + 1] = format('%s=%s', k, v)` 一带），无 `html_escapes` 处理。

### 复现

四种属性写法全部可注入，且 `escape_html = true` **无效**：

```lua
local u = "INJ' onclick='x"
haml.render("%div(title=u)",              {escape_html=true}, {u=u})
haml.render("%div(title='#{u}')",         {escape_html=true}, {u=u})
haml.render("%div{:title => u}",          {escape_html=true}, {u=u})
haml.render("%div{:title => \"#{u}\"}",   {escape_html=true}, {u=u})
```

实测输出全部为：

```
<div title='INJ' onclick='x'></div>
```

`REFERENCE.md#7.-属性值不自动转义` 已记录「不转义」，但**未说明 `escape_html` 也管不住属性**，容易被误读为开启总开关即可。

### 修复方案

- 在属性值拼接前统一走 `escape_html`
- 或提供 `escape_attributes` 独立选项（默认 `false` 保持兼容）
- 需处理布尔属性分支，勿破坏 `%a(flag)` 的既有行为（`AGENT.md` 陷阱 #7 已锁定该行为）

---

## S5（中 / A 档）`compile` 阶段即执行模板代码，无 `setfenv`、无 `pcall`

### 位置

- `haml/compile.lua:186` — `local code = tostring(loadstring('return ' .. node.code)())`
- `haml/compile.lua:208` — `node[1] = filter.escape_html(loadstring('return ' .. node.code)(), ...)`

两处都是**裸 `loadstring(...)()`**：没有 `setfenv`，没有 `pcall`。

### 实测精确边界

`haml.compile()` **单独调用**（不经 render、不经 lhtml）就会执行：

| 模板写法 | 触发位置 | 需要选项 | 实测 |
|---|---|---|---|
| `!= expr` | `compile.lua:186` | 无 | 执行 ✅ |
| `&= expr` | `compile.lua:186` | 无 | 执行 ✅ |
| `~ expr` | `compile.lua:186` | 无 | 执行 ✅ |
| `= expr` | `compile.lua:208` | `escape_html = true` | 执行 ✅ |
| `%p= expr` | — | — | **不执行** |

```lua
haml.compile(haml.parse("!= os.execute('touch /tmp/h2')"), {})                 -- 文件被创建
haml.compile(haml.parse("= os.execute('touch /tmp/k1')"), {escape_html=true})  -- 文件被创建
```

### 影响

- 「只调用 `compile` 不执行渲染」**不是安全边界**。任何做静态预编译、模板校验、CI 中 lint 模板的流程都会中招。
- 这两处表达式非法时抛裸错（无 `pcall`），也是 `AGENT.md` 陷阱 #4 记录的健壮性问题。

### 顺带修正文档错误

`REFERENCE.md#1.-模板即代码：生成并执行-lua` 称 `handle_node`（`compile.lua:208`）负责
「`escape_html = true` 时的 `=` 求值」，暗示涵盖 `%p=`。实测 `%p=` 的 inline 脚本存在
`inline_code` 而非 `node.code`，该分支的 `and node.code` 守卫恒假，**对 `%p=` 是死代码**。
该条只在**独立 `=` 行** + `escape_html=true` 时触发。文档需更正。

### 修复方案

- 两处改成 `pcall` + 带行号的错误
- 无法避免编译期求值（语义需要），但**必须在文档里显式声明 `compile` 会执行代码**
- 与 S2 的 `strict_eval` 合并设计：`strict_eval = true` 时编译期也不得求值，改为留占位符并标记，由调用方决策

---

## S6（低 / C 档）深嵌套导致栈溢出，CLI 无保护

### 位置

`haml/render.lua:64`（render 递归）、`haml/compile.lua:271`（compile 递归）

### 复现

```bash
python3 -c "print('\n'.join('  '*i+'%div' for i in range(2850)))" > /tmp/deep.haml
luajit luahaml.lua /tmp/deep.haml
```

实测阈值（二分）：**2800 层通过，2850 层崩溃**。

```
luajit: ./haml/render.lua:64: stack overflow
stack traceback:
	./haml/render.lua:64: in function '_recurse'
退出码=1
```

注：崩溃位置随深度和调用路径变化。2850 层先进 `_recurse`（`render.lua:64`）；
8000 层时 `compile` 在 `compile.lua:271` 溢出。

`parse` 本身是 LPeg 匹配，**不递归**——实测 20000 层仍正常返回 AST。所以深度守卫只需加在
`compile` 与 `render` 两处。

CLI 未包 `pcall`，直接把 traceback 打到 stderr。库调用方可自行 `pcall` 兜住。

### 影响

可用性 / DoS。若模板长度可控（SaaS、CMS），可稳定触发。

### 修复方案

`compile` / `render` 两处递归加深度计数器，超过 200 层抛带行号的明确错误。200 层对真实模板足够（`sample.haml` 仅数层）。`parse` 不递归，无需改动。

---

## S7（低 / A 档）CLI 环境中主机全局可读

### 位置

`luahaml.lua:154-155`

```lua
local _ENV = {}
setmetatable(_ENV, { __index = _G })
```

名为 `_ENV`，实际读全部 `_G`——**不是沙箱，起不到任何限制作用**。

### 复现

```bash
luajit luahaml.lua -i '%p= tostring(MY_SECRET)'
```

```lua
MY_SECRET = "s3cr3t-token-abc"
-- haml.render("%p= tostring(MY_SECRET)", {}, setmetatable({}, {__index=_G}))
--> <p>s3cr3t-token-abc</p>
```

### 影响

与 S2 同一放行路径。信息泄露（读取宿主进程任意全局）。

### 修复方案

与 S2 合并处理。注意：**不要**简单去掉 `__index = _G`，否则大量依赖全局函数的模板会静默失败，且失败后按 S2 的机制反而被推去全权限执行——会**变得更不安全**。必须先修 S2 的回退逻辑，再收紧 `_ENV`。

---

## S8（低 / C 档）`#{}` 值为 table 时抛裸 concat 错误

### 位置

`haml/render.lua:240` — `return slashes .. val`

### 复现

```lua
haml.render("%p v=#{t}", {}, {t = {1,2}})
--> 报错: ./haml/render.lua:240: attempt to concatenate local 'val' (a table value)
```

### 修复方案

`tostring(val)`，与 `=` 分支行为对齐。

---

## S9（低 / C 档）属性求值行为随「是否有内联内容」变化

### 复现

```lua
haml.render("%div(title=u)",       {}, {u="INJ"})   --> <div title='INJ'></div>     ← 求值
haml.render("%div(title=u) hi",    {}, {u="INJ"})   --> <div title=u>hi</div>       ← 不求值
```

同一个属性表达式，仅因为标签后有内联文本就变成字面量 `u`。

### 影响

正确性 bug（非安全，反而少了一条注入路径）。但会让 S4 的修复难度增加——两条路径都要覆盖。`AGENT.md#7.-常见任务落点` 已提示「检查两条路径都覆盖」。

### 修复方案

先补一个用例锁定当前行为，再统一。需确认哪种是 Haml 规范要求（对照 `spec/`）。

---

## 已排查、确认非问题

记录在此避免重复调查：

| 疑点 | 实测结论 |
|---|---|
| `:lua` 过滤器执行代码 | **不执行**。`haml/filter.lua:72-74` 的 `code_filter` 只 `return node.content`，内容作为文本输出。仍可被 S1 突破，但本身不是执行通道 |
| CLI 里 `#{1+1}` 被当 Lua 求值 | **不会**。`haml.render` 先把它替换成字面量 `1+1`，`_totable` 拿不到 `#{}`。`REFERENCE.md#5` 的「不求值」结论正确 |
| `luahaml.lua:76` 的两级括号 `io.write([[` 可被 `]]` 突破 | **不可达**。该分支要求代码含 `#{}`，而 `#{}` 在上游已被消费。实测 `%p= "x#{]]..os.execute(...)..[[}"` 未突破。**但若将来改动 `#{}` 的消费时机，这条会变成真实缺口，届时需重新评估** |
| `#{v}` 值含 `%` 是否被 `gsub` 二次解释 | **不会**。`haml.render("%p #{v}", {}, {v="100%"})` → `<p>100%</p>`。替换走函数形式，返回值不再被扫描 |

---

## 建议的修复顺序

按「风险下降 / 改动风险」比排序：

1. **S1** — 自适应长括号级数。低风险、纯收敛，直接消掉 B 档 RCE。
2. **S3 + S4** — `#{}` 与属性值转义。需要改输出行为，需同步文档与用例。
3. **S2 + S7** — `strict_eval` 逃生阀。**必须先做，才能安全地做 S7 的收紧**。
4. **S5** — 编译期 `pcall` + 文档声明 `compile` 会执行代码。
5. **S6** — 深度上限。
6. **S8、S9** — 顺手修。

## 修复时的验证要求

- 每条修复都要**先写出能在当前代码上失败的用例**（`AGENT.md#6` 要求），放入 `tests_patch.json`
- S1 的回归用例至少覆盖：`lhtml.lua` 与 `luahaml.lua` 两条路径、`:plain` 过滤器、`#{}` 数据注入
- 改动涉及 `lhtml.lua` → 必须跑 `luajit test_lhtml.lua`
- 输出行为有变 → 同步 `REFERENCE.md`，示例需实测
- **注意**：`luahaml.lua sample.haml` 的输出顺序天然不稳定（`AGENT.md` 陷阱 #9），验证 S3/S4 时不要用 `cmp`/`md5` 直接比，要比较排序后的行
