# 内置 IP 查询接口候选清单

内置接口分两组：**境内**（服务器在中国大陆，通常命中直连规则）和**境外**（通常命中代理规则）。

> **验证状态：全部未实测。** 本清单整理自各服务的公开资料与第三方文章，编写环境无法访问这些站点。字段路径与限额在写入代码前必须用 `scripts/check-endpoints.sh` 在目标 Mac 上逐个核对；免费接口随时可能改格式、加限流或下线。

## 境内

| ID | 地址 | 返回 | 归属信息 | 限额 / 备注 |
| --- | --- | --- | --- | --- |
| `ipip` | `https://myip.ipip.net/json` | JSON | 国家、省、市、运营商（中文，数组形式） | 未公布限额 |
| `baidu-qifu` | `https://qifu-api.baidubce.com/ip/local/geo/v1/district` | JSON | 国家、省、市、区、运营商（中文） | 未公布限额；非正式公开接口，稳定性存疑 |
| `speedtest-cn` | `https://forge.speedtest.cn/api/location/info` | JSON | 国家、省、市、运营商（中文） | 未公布限额；属站点自用接口 |
| `ip9` | `https://ip9.com.cn/get` | JSON | 国家、省、市、区、运营商 | 官网称每 IP 60 次 / 分钟 |
| `pconline` | `https://whois.pconline.com.cn/ipJson.jsp?json=true` | JSON（**GBK 编码**） | 省、市、地址描述 | 需转码；无国家码 |
| `ipw-v4` / `ipw-v6` | `https://4.ipw.cn`、`https://6.ipw.cn` | 纯文本 IP | 无 | 分别强制 IPv4 / IPv6 |
| `3322` | `https://ip.3322.net` | 纯文本 IP | 无 | 仅 IPv4 |

**建议默认**：主 `ipip`，备用 `ip9`；IPv6 用 `ipw-v6`。

## 境外

| ID | 地址 | 返回 | 归属信息 | 限额 / 备注 |
| --- | --- | --- | --- | --- |
| `cloudflare` | `https://www.cloudflare.com/cdn-cgi/trace` | `key=value` 文本 | 仅国家码（`loc`） | 无公开限额；无运营商信息 |
| `ipinfo` | `https://ipinfo.io/json` | JSON | 国家码、地区、城市、`org`（含 ASN） | 无 Token 时约 1000 次 / 天，且**按出口 IP 共享**——共享代理节点上容易被别人用完 |
| `ipinfo-lite` | `https://api.ipinfo.io/lite/me?token=…` | JSON | 国家码、ASN、组织（无城市） | 需免费 Token；官方称不限次数 |
| `ip-api` | `http://ip-api.com/json` | JSON | 国家码、地区、城市、ISP、组织、ASN | 45 次 / 分钟；免费版**仅 HTTP**、限非商业用途 |
| `ipapi-co` | `https://ipapi.co/json` | JSON | 国家码、地区、城市、组织、ASN | 第三方资料称约 1000 次 / 天 |
| `ip-sb` | `https://api.ip.sb/geoip` | JSON | 国家码、组织、ISP、ASN | 未公布限额 |
| `ipwhois` | `https://ipwho.is/` | JSON | 国家码、地区、城市、ISP、组织、ASN | 未公布确切限额 |
| `ipify-v4` / `ipify-v6` | `https://api.ipify.org`、`https://api6.ipify.org` | 纯文本 IP | 无 | 分别强制 IPv4 / IPv6 |

**建议默认**：主 `cloudflare`（无配额压力，适合高频），需要运营商 / ASN 时配 `ip-sb` 或 `ipwhois`；IPv6 用 `ipify-v6`。

## 对设计的三点影响

**1. 每日配额与默认间隔冲突。** 60 秒间隔 = 每个检测点每天 1440 次，超过 `ipinfo`（无 Token）和 `ipapi-co` 的约 1000 次 / 天。处理方式：

- 每个内置接口带一个“最小间隔”属性，检测点间隔不得低于它（上述两个设为 120 秒）
- 默认主接口只选没有每日配额压力的（`ipip`、`cloudflare`）

**2. 境内接口返回中文且没有国家码。** 规则里的“国家码属于 `CN`”无法直接匹配“中国”。两种做法，建议 MVP 用前者：

- 内置一张常见国家中文名 → 二位码的映射表，匹配不上时国家码留空，仍可用关键字规则匹配原始响应
- 只取 IP，再统一交给归属地解析（在线服务或 M2 的离线库）

**3. `ip-api` 只有 HTTP。** macOS 默认拦截明文 HTTP，需为该域名单独加传输安全例外；且明文响应可被中间人篡改，不适合作为默认接口，仅作可选项。

## 分流提醒

“境内 / 境外”只描述服务器位置，**实际走哪条出口由用户的分流规则决定**。例如规则按域名后缀判断时，`ip9.com.cn` 与 `myip.ipip.net` 可能命中不同规则。建检测点时的“测试一次”和详情里显示的请求域名，就是用来核对这一点的。

## 资料来源

- [IPinfo：免费计划的用量限制](https://support.ipinfo.io/hc/en-us/articles/30792535492626-What-Is-the-Usage-Limit-for-the-Free-Plan)
- [IPinfo：无账号公共接口与免费计划的区别](https://support.ipinfo.io/hc/en-us/articles/30792479436562-What-Is-the-Difference-Between-Using-the-Authenticated-Free-Plan-and-the-Public-API-With-No-Account)
- [IPinfo Lite 介绍](https://ipinfo.io/blog/ipinfo-lite-free-accurate-unlimited-ip-data)
- [Free IP Geolocation APIs Compared (2026)](https://geo.kamero.ai/blog/free-ip-geolocation-api-comparison-2026)
- [IP9.COM.CN](https://www.ip9.com.cn/)
- [ihmily/ip-info-api：免费 IP 接口汇总](https://github.com/ihmily/ip-info-api)
