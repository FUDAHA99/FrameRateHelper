# 测试交接

本文档面向接手测试的人/agent。前置上下文为零，按本文操作即可。

被测对象：`fork/main` 上的两个提交（`2796dc7`、`935950f`），基线是上游 `9fab79d`。

```bash
git log --oneline 9fab79d..HEAD
git diff 9fab79d..HEAD --stat
```

---

## 0. 环境要求（不满足会得到误导性的失败）

| 依赖 | 要求 | 检查 |
|---|---|---|
| PowerShell | **Windows PowerShell 5.1**，不是 pwsh 7 | `$PSVersionTable.PSVersion` / `$PSVersionTable.PSEdition` 必须是 `Desktop` |
| csc.exe | .NET Framework v4.0.30319 | `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe` |
| WPF | PresentationFramework 在 GAC | 构建安装器需要 |

pwsh 7 跑构建脚本会炸：它解析出的压缩程序集是 .NET Core 版路径，喂给 Framework csc 不兼容。

---

## 1. 自动化测试

```powershell
Get-ChildItem tests\*.ps1 | Sort-Object Name | ForEach-Object {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName 2>&1 | Out-Null
  '{0,-34} {1}' -f $_.Name, $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
}
```

**期望：18 个文件里 15 个通过。**

以下 3 个失败是**上游基线就有的，不是本次改动引入**（在未修改的 `9fab79d` 上复现同样结果，可自行 checkout 验证）：

| 文件 | 原因 |
|---|---|
| `installer-security-tests` | 需要先 `build\make-installer.ps1 -TestBuild` 产出测试包 |
| `installer-drive-picker-tests` | 同上 |
| `notification-feature-tests` | 上游既有失败，未排查 |

新增的 `startup-bootstrap-tests.ps1` 必须通过。

---

## 2. 需要真机验证的部分（自动化测不到）

GUI 脚本**不能直接运行** —— `gui/DeltaForceBooster-GUI.ps1` 开头有硬闸门，要求 7 个环境变量、父进程 PID 等于 EngineHost、`%TEMP%` 精确匹配会话目录。要看效果必须走完整构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\make-installer.ps1
```

> 注意：`-TestBuild` 会在仓库根留下带 `DFB_TESTING` 编译开关的启动器（认 `DFB_TEST_SKIP_ACL=1` 旁路）。
> 验证完请重跑一次**不带** `-TestBuild` 的构建。

### 2.1 匿名统计开关（提交 2796dc7）

1. 装好后打开软件 → 「运行日志」页底部应有 **「发送匿名使用统计」** 复选框，**默认不勾选**
2. 勾上 → 运行日志应出现「已开启匿名使用统计。」
3. 关闭软件重开 → 勾选状态应保持
4. 取消勾选 → 日志出现「已关闭匿名使用统计，本机不再上报任何数据。」
5. **抓包验证**（关键）：未勾选状态下全程操作（检测、执行优化、还原），
   应观察不到任何到 `upstream-host.invalid/report/telemetry` 的请求
6. 把 `%ProgramData%\DeltaForceBooster\users\<SID>\config\ui-preferences.json`
   删掉或改成非法 JSON → 重开软件，开关必须回到**未勾选**（fail-closed，不是重新开启）

> ⚠️ **不要在真机上长时间开启第 5 步之外的上报**：域名仍是上游作者的 `upstream-host.invalid`，
> 开启等于把数据发给上游。这是已知遗留项，换域名前不要发布。

### 2.2 启动引导日志（提交 935950f）

1. 正常启动一次 → `%ProgramData%\DeltaForceBooster\startup-logs\` 下应出现
   `startup-<时间戳>-<pid>.log`，内容含 PS 版本、CLR、系统版本、区域设置、环境变量
2. 该文件应为 **UTF-8 with BOM**，中文不乱码
3. 会话标记应显示为 `SESSION=xxxxxxxx…`（**只有前 8 位**，不是完整 32 位十六进制）
4. **制造失败**：直接用 `powershell -File gui\DeltaForceBooster-GUI.ps1` 运行（绕过启动器）。
   期望：弹窗给出**可行动的建议**（「这通常是直接双击了 .ps1 脚本…请改用启动优化工具.exe」），
   并显示日志路径；同时日志里有 `!! 启动被拒：` 那一行
5. 目录应对普通用户**可读**（非管理员账户能打开）

**最该重点验的一条回归**：在一台**从未装过**本软件的干净机器（或先删掉
`%ProgramData%\DeltaForceBooster`）上安装并首次启动。必须能正常打开。

> 背景：本层第一版会在最顶端创建那个受保护根目录，导致它继承
> `Owner=当前用户` + `BUILTIN\Users:Write`，随后 `New-ProtectedDirectory`
> 抛「已拒绝接管」，**全新安装的机器每次都打不开**。已修复并加了断言，
> 但这是本次改动里唯一能造成灾难性后果的地方，值得真机确认。

### 2.3 独立诊断导出器（提交 935950f）

```
双击安装目录下的  导出诊断信息.cmd
```

1. **以普通用户身份**运行（不要右键管理员）—— 必须能跑完
2. 桌面应生成 `帧率优化助手-诊断-<时间戳>.txt`
3. 内容应包含：运行环境、安装状态、受保护数据目录（含 ACL）、启动日志、
   相关进程、安全软件、系统事件日志七节
4. 故意破坏：把安装目录改名，再跑一次 —— 应照常生成报告并在「安装状态」里标出缺失文件，
   **不应抛异常**
5. 确认报告里**没有**账号密码、注册表内容、游戏路径

---

## 3. 我最不确定的地方（请重点打）

1. **`trap` 的副作用**。我在脚本作用域加了 `trap { ...; break }`。理论上它只接
   没被 try/catch 接住的终止性错误，且 `break` 保持原有「出错即终止」语义。
   但这个改动影响面是全局的，请确认没有任何原本能正常走完的流程被它提前中断。

2. **`Save-AppUiPreferences` 的第三个参数默认值**。它默认「读回当前磁盘值」。
   关窗保存（`gui:9348`）和 `Save-AppTheme` 都只传两个参数。
   请确认切换主题、调整窗口大小、关窗这些操作**不会**意外改动统计开关。

3. **`startup-logs` 的 ACL**。它是唯一一个 `$UsersRead = $true` 的受保护子目录。
   请确认普通用户只能**读**、不能写（不能往里面塞文件或改现有日志）。

4. **非中文区域设置**。上游有个提交是
   `367fd75 fix: 非中文区域设置的机器上软件完全无法启动`。
   我新增的代码含中文字符串。请在英文/日文区域设置的 Windows 上验一遍启动与日志。

---

## 4. 明确不在本次范围内

- 「回退到上一个可用版本」按钮：**决定不做**。安装器已在「新版启动失败」时自动回滚
  （`setup-wizard.cs:263-277`），而回滚副本在切换成功后即被删除（`:2743`），
  做用户可点的回退需要改安装事务模型，风险收益比不划算。
- 域名仍是 `upstream-host.invalid`（上游作者的服务器）。
- 第三方传感器栈与 PawnIO 内核驱动已移除；剩余第三方件只有 Intel MIT 的 PresentMon。
- 产品改名未执行：代码里仍是 `DeltaForceBooster`。
