# PlayCover ExStorage

[English](README.md) | [简体中文](README.zh-CN.md)

PlayCover ExStorage 是一款 macOS 工具，用于在本地存储和外置 APFS container 之间迁移 PlayCover App 及其 container 数据。外置 App Data 保存在独立的 APFS Volume 中，并直接挂载到 App 原本的 `Data` 路径，因此 App 仍然使用标准 container 路径。

> PlayCover ExStorage 会执行需要管理员权限的磁盘和文件系统操作。请先备份重要数据，并优先使用不重要的 App 测试。

## 系统要求

- macOS 13 Ventura 或更高版本
- 包含 APFS container 的外置硬盘
- 允许安装并运行内置的 privileged helper
- 从源码构建时需要 Apple Development 或 Developer ID 签名团队

应用只接受外置 APFS container。内部磁盘和不支持的文件系统会被 privileged helper 拒绝。

## 1.2.0 更新内容

- 支持单独迁移 App、单独迁移 Data，以及同时迁移 App 和 Data；支持本地与外置 container 之间以及两个外置 container 之间直接迁移。
- 新增串行迁移队列、持久化检查点、复制校验、中断恢复，以及 App & Data 事务回滚。
- 每个 APFS container 使用一个 `ExStorage` 管理 Volume 保存 App 和 AppInfo，并使用 UUID 定位每个 App 的独立 Data Volume。
- App 操作状态按 Bundle ID 独立保存，连接或断开其他 App 不会覆盖正在迁移 App 的状态和进度。
- 新增 **Connect & Open**、本地 Data 冲突处理，以及打开未被管理的其他 Volume。
- 改进删除选项、迁移校验、状态显示和临时挂载清理。
- 加入经过签名验证的 Sparkle 更新支持，用于 1.2.0 之后的版本。

## 下载测试版本

GitHub Releases 提供同时支持 Apple Silicon 和 Intel Mac 的 Universal 构建。当前测试版本使用 Apple Development 证书签名，但未经 Apple 公证。

1. 从 [GitHub Releases](https://github.com/hurrymomo/PlayCover-ExStorage/releases) 下载 `.dmg`。
2. 将 **PlayCover ExStorage** 拖入 **Applications**。
3. 尝试打开一次。如果 macOS 阻止启动，请前往 **系统设置 → 隐私与安全性**，选择 **仍要打开**。
4. 系统要求时，请在 **系统设置 → 通用 → 登录项** 中允许 PlayCover ExStorage。
5. 如果 macOS 阻止将 Volume 挂载到 App container 的 `Data` 目录，请授予完全磁盘访问权限。

请只安装从本仓库下载的构建。

## 主要功能

- 将一个或多个 `.app` 拖入 Library，并选择是否跨启动保留记录。
- 在本地存储和外置 APFS container 之间迁移 App、Data 或两者。
- 在两个外置 container 之间直接迁移受管理的 App 和 Data。
- 多个迁移进入队列后一次执行一个。
- 提交迁移前校验复制结果，并为正在执行的迁移保存中断恢复状态。
- 将断开的 Data Volume 连接到 `~/Library/Containers/<bundle-id>/Data`，随后打开 App。
- 将受管理的内容迁回本地；恢复 App 时会优先使用最后一次验证过的本地路径。
- 可以分别删除 App、Data 或两者。

## 外置存储结构

每个受管理的 APFS container 都有一个名为 `ExStorage` 的管理 Volume：

```text
ExStorage/
├── Applications/          # 受管理的 .app
└── AppInfo/               # 每个 App 的元数据
```

每个受管理的 App 还有一个独立 Data Volume。AppInfo 保存其 UUID，Volume 名称为 App 的 Bundle ID。连接后，该 Volume 会挂载到：

```text
~/Library/Containers/<bundle-id>/Data
```

AppInfo 保存 Bundle ID、Data Volume UUID、schema 版本和最后一次验证过的本地 App 路径 hint。使用 hint 前仍会验证路径与 Bundle ID。

## 迁移安全

- App 会先复制到目标位置的隐藏 staging 目录，校验通过后才正式切换。
- Data 使用可恢复的 `rsync` 复制，对比源与目标 manifest，并清除目标中多余的文件。
- App & Data 被视为一个事务；如果第二部分失败，会在能够安全回滚时把已完成的部分迁回原处。
- 只有正在执行的迁移会留下本地恢复记录，排队任务只属于当前运行会话。
- 迁移期间不要断开外置硬盘，也不要启动正在迁移的 App。

连接外置 Data Volume 时，如果本地已有非空 Data，可以选择删除它，或让它保留并暂时隐藏在挂载点下方。隐藏的数据仍占用本地空间，断开外置 Volume 后会重新出现。

## 本地记录与日志

选择 **Keep in Library** 的 App 记录保存在以下 plist 的 `ManagedApps` 键中：

```text
~/Library/Preferences/momo.PlayCover-ExStorage.plist
```

正在迁移任务的恢复记录保存在：

```text
~/Library/Application Support/PlayCover ExStorage/Migrations/
```

操作日志保存在：

```text
~/Library/Logs/PlayCover ExStorage/
```

## 从源码构建

1. 克隆仓库。
2. 使用 Xcode 打开 `PlayCover ExStorage.xcodeproj`。
3. 为 **PlayCover ExStorage** 和 **PrivilegedHelper** target 设置相同的 Development Team。
4. 构建并运行 **PlayCover ExStorage** scheme。
5. 系统要求时，在 **系统设置 → 通用 → 登录项** 中允许 Helper。

主 App 和 Helper 会验证预期的 Bundle ID 与相同的 Team ID。Helper 使用 `SMAppService`，只开放受限制的 APFS 与文件系统操作，不会调用 `sudo`。

## 更新与发布

1.2.0 是第一个支持 Sparkle 的版本，其中包含更新 feed 地址以及验证后续更新包所需的 EdDSA 公钥。私钥不会进入仓库，只保存在发布维护者的 macOS 钥匙串中。

正式公开分发时，应使用 Developer ID Application 证书 Archive，启用 Hardened Runtime，提交 Apple 公证，并分发签名后的 `.dmg` 或 `.zip`。构建产物和签名凭据不能提交到仓库。

## 许可证

项目目前尚未选择许可证。在添加许可证文件之前，适用通常的版权限制。
