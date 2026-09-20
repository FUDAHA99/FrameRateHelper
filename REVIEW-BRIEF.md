# 独立复核交接说明

写给**第一次接触这个仓库的复核者**（人或 AI agent）。目的只有一个：让你把精力花在
真正没人看过的地方，而不是重走已经走过三遍的路。

本文不是使用说明（那是 `README.md`），也不是手工验证清单（那是 `TESTING.md`）。

---

## 0. 仓库现在是什么状态

- `FUDAHA99/FrameRateHelper`，分支 `fork/main`，已发布 **v1.0.0.0**。
- 它是 [Leonard8818/-Delta-Force-Graphics-Optimizer](https://github.com/Leonard8818/-Delta-Force-Graphics-Optimizer)（MIT）的分支，**绝大部分代码出自上游**。
- 本分支相对上游的改动清单见 `NOTICE.md`；安全设计与已知局限见 `SECURITY.md`。
- `tests\` 下 21 个文件，当前全部通过。

**技术栈的硬约束**：Windows PowerShell **5.1**（Desktop）+ 内联 C#/WPF。不是 PowerShell 7。
脚本头部 `$ErrorActionPreference = 'Stop'`，顶层任何失败都会在 `ShowDialog()` 之前杀掉界面。

---

## 1. 最值得你花时间的一件事：审计测试套件本身

**这是本仓库最大的系统性风险，不是某个功能的 bug。**

开发过程中反复出现同一种失效：写下一条形如 `Assert-True ($raw.Contains('某字符串'))` 的断言，
它看起来在守某个行为，实际上匹配到的是

- 断言作者**自己写的注释**（注释里恰好提到了那个词），或
- 同一份文档**别处**出现的同名词。

结果是：把被测的东西整块删掉，断言照样是绿的。这种情况在本项目里出现过**十次以上**，
最近一次是许可断言 —— `Contains('Leonard8818')` 匹配到了版权行上方的项目链接，
于是把整条版权行删掉测试仍然通过。

**所以 21/21 全绿这件事的可信度，完全取决于这些断言是不是真的会红。**

建议做法：对每一条断言做**变异测试** —— 把它声称在守的东西改坏，确认它确实转红。
存活的断言就是假绿，比没有断言更危险（它给人已经覆盖了的错觉）。

已知的好写法（仓库里有现成例子，可参考）：
- 用 **AST** 查结构关系，而不是搜文本（见 `tests/gui-startup-tests.ps1` 里对
  `Import-ProtectedLegacyState`、事件接线、`$ui` 注册的检查）
- 直接**跑产品代码本身**（`Invoke-Expression $fn.Extent.Text` 取出真函数，只桩掉落盘与 ACL）
- 断言**不变量**而不是具体值（例：`data/streamer-settings.json` 里不得出现任何带
  `name`/`url`/`platform` 的第三方人物条目；外链白名单必须恰好是那几个厂商域名）

---

## 2. 其次：这几块只在测试里验过，从没在真机上跑过

**HMAC 写前备份链与还原记账**，安全敏感度最高：

```
Read-ValidatedBackup -> Assert-BackupDocument -> Assert-BackupOperation
```

配套的还有签名消费回执、备份 schema v1/v2/v3 兼容。相关测试：
`restore-accounting-tests.ps1`、`restore-resilience-tests.ps1`、`selective-restore-tests.ps1`。

**UAC 边界与 IPC**：asInvoker 的 `启动优化工具.exe` → requireAdministrator 的 `EngineHost.exe`，
中间走受保护的请求/结果 JSON，带精确属性 schema 校验。相关：`engine-security-tests.ps1`、
`engine-request-transport-tests.ps1`、`engine-host-session-tests.ps1`。

这两块一旦有洞，后果是用户的系统改不回去，或者低权限端能让高权限端执行任意操作。

---

## 3. 作者自己最没把握的地方

`TESTING.md` §3 有完整版，摘要：

1. **脚本作用域的 `trap { ...; break }`** —— 影响面是全局的，是否有原本能正常走完的流程被它提前中断？
2. **`Save-AppUiPreferences` 的第三个参数**（窗口宽度）默认「读回磁盘当前值」。
   切主题、关窗会不会意外抹掉用户拉好的宽度？
3. **`startup-logs` 的 ACL** —— 唯一一个 `$UsersRead = $true` 的受保护子目录，普通用户应只读不可写。
4. **非中文区域设置** —— 上游有过「非中文 locale 上软件完全无法启动」的事故（`367fd75`），
   本分支新增代码含中文字符串，英文/日文 Windows 上需复验。

---

## 4. 已经查过的，不用重做

这些刚做完一轮 42 agent 的发布前审计 + 一轮 10 维度的所有权审计，结论已落地：

- 上游遥测、匿名上报、通知轮询、诊断上传 —— **代码层面已全部删除**，不是加开关
- 内置 LibreHardwareMonitor（MPL-2.0）与 PawnIO（GPL-2.0）内核驱动 —— 已移除，且**已从 Git 历史彻底清除**
- 第三方实名主播的个人资料 —— 已从随包数据与历史中移除
- 上游的遥测后端域名与官网域名 —— 已从代码、文档与全部历史中移除
- 旧版数据迁移遇到清单外文件会整批中止且静默 —— 已改为跳过并写日志
- 日志谎称「已匿名上报」 —— 已改
- `mouse-accel-off` 写完注册表其实不生效（只写注册表不广播 `SPI_SETMOUSE`），界面却写「立即生效」—— 已标 `Reboot`

---

## 5. 怎么跑测试（几个必踩的坑）

```powershell
# 先出测试包，否则 installer 那两个用例必定失败
powershell -NoProfile -ExecutionPolicy Bypass -File build\make-installer.ps1 -TestBuild

Get-ChildItem tests\*.ps1 | Sort-Object Name | ForEach-Object {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName 2>&1 | Out-Null
  '{0,-34} {1}' -f $_.Name, $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
}
```

1. **软件必须关闭。** 它占着两个全局互斥体，开着跑会红两个用例，跟你的改动无关。
   判断方法见 `TESTING.md` 开头。
2. **每改一次源码都要重出测试包**，不只第一次。`installer-security-tests` 与
   `installer-drive-picker-tests` 读的是**构建产物**。
3. **PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解**，中文源码会报出看起来像括号不匹配的语法错误。
   新建 `.ps1` 必须带 UTF-8 BOM。（`tests/ui-preferences-tests.ps1` 是例外：它没有 BOM，
   所以里面的断言消息必须保持纯 ASCII。）
4. **子进程里的注册表写入会被沙箱静默重定向**，读回来还是原值。要验真实注册表行为，
   别用 `& powershell.exe -File` 另起进程。

### PowerShell 5.1 / WPF 的已知陷阱

- `@($null).Count` 是 **1**，不是 0
- `-like` 会把 `[0]` 当字符类
- 双引号字符串里 `\$x` 仍然会插值（反斜杠不是转义符），写正则用单引号
- **脚本块转成委托后写不了 `ref` 参数** —— `HwndSourceHook` 的 `$handled` 到手是普通 `[bool]`，
  赋值直接抛异常。所以 PowerShell 挂的窗口钩子永远无法把消息标记为已处理
- 横向 `StackPanel` 永不压缩子元素，且以无限宽度测量
- `Button` 的静态构造器设了 `KeyboardNavigation.AcceptsReturn = True`，
  焦点落在任何按钮上都会让 `IsDefault` 按钮失去默认态
- `DesiredSize` 含元素自身的 `Margin`

### 绝对不能改名的标识符

改了会破坏已安装用户的状态目录与安装身份：

```
DeltaForceBooster                        ProgramData 根目录 / AssemblyProduct / InstallProductId
DeltaForceBooster 开源项目                AssemblyCompany，setup-wizard.cs 里按 Ordinal 精确比对
DeltaForceBooster-PowerPlanLock          全局互斥体
DeltaForceBooster-RestorePowerOverride   全局互斥体
三角洲优化 · 卓越性能                      电源方案名
backup.key                               HMAC 密钥文件名
```

---

## 6. 明确不在代码审查范围内

**`TESTING.md` §2.15 的真机端到端验证（执行优化 → 还原 → 残留检查）至今一次都没跑过。**

它需要真实的 Windows 机器、过 UAC 提权框、两次重启，以及独显。纯代码审查覆盖不到，
沙箱里也做不了。**不要把代码审查通过当成这条已经被覆盖。**

备份链、HMAC 记账、还原路径、残留反查这四件事，到目前为止**只有测试替身验过**。
