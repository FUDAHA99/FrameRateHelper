## 本版更新

- 修复：勾选「不再提醒此版本」后，软件启动时和运行中仍会自动弹出这个版本的更新提示。
- 修复：启动日志会记下完整的会话标记，现在只记前 8 位。
- 修复：备份写入失败时的结果说明与实际不符，例如什么都没写却说「其余已写入」「已抢救出部分备份」。
- 更正：安装完成页关于管理员确认（UAC）的说明，以及升级后「重要提醒」里的按钮名称。

从 v1.0.0.0 升级：v1.0.0.0 本身有「不再提醒此版本」不生效的问题，所以在升级之前，这一版的更新提示每次启动都会出现。

## 下载与校验

| 文件 | 说明 |
|---|---|
| `DeltaForceBooster-Setup.exe` | 安装包。**文件名不带版本号**是有意的：软件内置更新按这个名字拼地址 |
| `update-manifest.json` | 更新清单。内置更新会读它，并强制校验下面的 SHA256 与文件大小 |

```
SHA256  2c4848f10d6eb0361bfc75563a0af7452cdcf256dd28276cdf69d7bb1a9e2464
大小    985600 字节
```

Windows 下核对：

```powershell
Get-FileHash .\DeltaForceBooster-Setup.exe -Algorithm SHA256
```

## 装之前请知道

- **非官方个人项目，与腾讯公司及《三角洲行动》官方无任何关系。**
- 本工具会修改注册表、电源计划、系统服务等**系统级设置**。可还原的改动都会先写受保护备份，
  软件内「还原设置」可逐项回退；纯检测项和明确标注不可还原的操作不生成备份。
- **没有代码签名证书**，SmartScreen 会提示「未知发布者」，部分杀毒软件可能误报 —— 这是必然结果，
  不是被篡改的迹象。请核对上面的 SHA256。
- **不收集、不上报任何使用数据。** 唯一的联网行为是向 GitHub 检查更新；诊断报告只写到你自己的桌面。
- 首次启动有免责声明门控，请读完再同意。完整条款见 [DISCLAIMER.md](DISCLAIMER.md)。

## 许可与署名

MIT。本项目是 [Leonard8818/-Delta-Force-Graphics-Optimizer](https://github.com/Leonard8818/-Delta-Force-Graphics-Optimizer)（MIT）的**分支**，绝大部分代码出自上游。
Copyright (c) 2026 Leonard8818（上游项目）、FUDAHA99（本分支的修改）。
**上游作者不对本分支负责**，本分支的问题请提到本仓库。

帧率采样使用 Intel / GameTechDev 的 [PresentMon](https://github.com/GameTechDev/PresentMon)（MIT），许可证原文随附于 `tools/PresentMon-LICENSE.txt`。

改动清单见 [NOTICE.md](NOTICE.md)，安全设计与已知局限见 [SECURITY.md](SECURITY.md)。
