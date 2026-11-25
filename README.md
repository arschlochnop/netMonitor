# NetMonitor

macOS 菜单栏工具：同时向多个境内、境外的 IP 查询接口发请求，检查每条出口的公网 IP 是否符合预期地区或关键字，不符合时通知或弹窗提醒。

适合开着代理 / 分流规则的场景：访问不同国家的网站会走不同出口，任何一条出口漂移、掉线回落直连、IPv6 泄漏都能及时发现。

## 功能

- **检测点**：一个检测点 = 一个查询接口 + 一组预期规则。查询接口决定请求走哪条出口，主接口失败时按顺序回退到备用接口。
- **内置接口**：境内（IPIP.net、IP9、太平洋 IP 库）、境外（Cloudflare trace、IP.SB、ipwho.is、ipinfo.io）、IPv6（ident.me、icanhazip）。也可添加自定义接口（JSON 字段路径 / key=value / 纯文本）。
- **规则**：国家码属于 / 不属于，地区、城市、运营商、ASN、IP、原始响应的包含 / 不包含 / 等于 / 正则；按“全部满足”或“任一满足”组合。
- **防误报**：连续 N 次不符合才提醒；只在状态变化时通知；恢复时通知；持续异常可重复提醒；“检测失败”与“不符合”分开处理。
- **提醒方式**：菜单栏图标变化、系统通知、置顶强提醒弹窗（不受专注模式影响）、提示音。
- **触发**：定时检测、手动检测、网络变化（切换 Wi‑Fi、VPN 上下线）与唤醒后自动补测。
- **历史记录**：记录不符合、恢复、检测失败和 IP 变化，可导出 CSV。

设计文档见 [docs/requirements.md](docs/requirements.md)，接口清单与实测记录见 [docs/endpoints.md](docs/endpoints.md)。

## 安装

需要 macOS 13 或更高版本。

1. 从 GitHub Actions 的构建产物或 Releases 下载 `NetMonitor-*.zip`，解压得到 `NetMonitor.app`，拖到“应用程序”。
2. 构建产物只做了临时签名，没有经过 Apple 公证，首次打开会被拦截。在终端执行一次：

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetMonitor.app
   ```

   或者在“系统设置 › 隐私与安全性”里点“仍要打开”。
3. 首次运行会请求通知权限。拒绝的话，不符合时改用置顶弹窗提醒。

## 从源码构建

需要 Xcode 15 或更高版本的命令行工具。

```bash
swift test
```

```bash
scripts/build-app.sh 0.1.0
```

产物在 `build/NetMonitor.app`。也可以 `swift run NetMonitor` 直接运行调试，但这种方式没有 Bundle ID，系统通知和开机启动不可用。

## 配置与数据

- 配置：`~/Library/Application Support/NetMonitor/config.json`，可在设置中导入 / 导出。
- 历史：`~/Library/Application Support/NetMonitor/history.jsonl`，默认保留 30 天。

所有数据只存在本机。程序只向你配置的查询接口发请求，没有遥测。

## 验证接口

`scripts/check-endpoints.sh` 会逐个请求内置接口并打印响应，用于在你的网络环境下确认接口可用、分流是否符合预期。

## 许可证

[MIT](LICENSE)
