# 声明与出处

## 与游戏官方的关系

本项目是**个人开发的非官方工具**，与腾讯公司、Team Jade 及《三角洲行动》/《Delta Force》官方**没有任何关联**，未获得其认可、授权或赞助。

「三角洲行动」「Delta Force」及相关标识为其各自权利人所有。本项目**仅在描述工具用途所必需的范围内**使用这些名称（说明工具是为该游戏做系统优化），不主张任何商标权利，也不以官方名义提供任何服务。

如权利人认为本项目的命名或表述不当，请通过 GitHub Issue 告知，我会配合调整。

## 本项目不做什么

- 不修改游戏安装目录内的任何文件
- 不注入游戏进程、不读写游戏内存
- 不与反作弊系统交互、不规避任何游戏机制
- 不提供任何游戏内的功能性优势

本项目修改的全部是 **Windows 系统层设置**（注册表、电源计划、系统服务、启动配置），这些设置对所有程序一视同仁。

## 优化手法的出处

本工具实现的优化项，其手法来自公开的技术资料与社区教程，包括微软官方文档（电源管理、MMCSS、Interrupt Affinity Policy 等）、显卡厂商的公开建议，以及国内视频平台上多位硬件/电竞内容创作者分享的调试经验。

这些手法本身是公开知识，本项目做的是**整理、自动化与可还原化**：把散落在各处的手动步骤变成可批量执行、改动前自动备份、随时可一键回退的形式。

工具内每一项优化都标注了它实际改动的注册表路径或系统命令，便于使用者自行核对与判断。

## 第三方内容

- `tools/DeltaForce-Recommended.nip` 是本项目生成的配置文件，采用 NVIDIA Profile Inspector 的导入格式（该格式的 schema 与设置项 ID 参考自 [nvidiaProfileInspector](https://github.com/Orbmu2k/nvidiaProfileInspector) 开源项目）。本项目**不分发** Profile Inspector 程序本身，使用者需自行获取。
- `tools/PresentMon.exe` 来自 Intel / GameTechDev 的 [PresentMon](https://github.com/GameTechDev/PresentMon) 官方发布，用于通过 Windows ETW 采样游戏帧呈现数据；本项目不注入游戏进程。其许可证原文随附于 `tools/PresentMon-LICENSE.txt`。
- 本项目**不分发任何硬件传感器组件，也不安装任何内核驱动**。CPU / GPU 温度由 nvidia-smi（随显卡驱动安装）或用户自行安装的 LibreHardwareMonitor / OpenHardwareMonitor 通过其 WMI 命名空间提供，读不到时界面如实显示「未检测到温度来源」并给出自助方法。
  上游版本曾内置 LibreHardwareMonitor（MPL-2.0）及其六个运行依赖，并静默安装 PawnIO（GPL-2.0）内核驱动。本分支已全部移除：那一整套只产出一个数字（CPU 封装温度），而静默安装内核驱动会显著放大杀毒软件误报，「软件打不开」才是本工具最高频的故障。
- 本项目自己的安装包、启动器和管理员宿主仍由 Windows 自带的 .NET 编译器现场构建。

## 游戏内设置参考数据

`data/streamer-settings.json` 中收录的主播游戏内画质设置，整理自各主播公开发布的视频内容，每条均标注来源链接。这些数据**仅供参考**，本工具不会也无法修改游戏内设置。

如相关内容创作者不希望其设置被收录，请提 Issue 告知，我会移除。
