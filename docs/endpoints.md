# 内置 IP 查询接口清单

内置接口分两组：**境内**（服务器在中国大陆，通常命中直连规则）和**境外**（通常命中代理规则）。

> **验证状态：** 2026-11 在一台 Mac 上用 `scripts/check-endpoints.sh` 实测过一轮 IPv4。那次测试中所有接口返回的都是同一个出口（北京移动），说明当时没有经过代理分流，所以只验证了**接口可用性和返回格式**，没有验证分流。IPv6 接口全部未验证通过。免费接口随时可能变化，发布前应再跑一次脚本。

## 境内

| ID | 地址 | 实测 | 返回字段 | 备注 |
| --- | --- | --- | --- | --- |
| `ipip` | `https://myip.ipip.net/json` | ✅ 0.4s | `data.ip`；`data.location` 为数组：`[国家, 省, 市, 区, 运营商]`，全中文 | 最快；无国家码，需中文名→国家码映射 |
| `ip9` | `https://ip9.com.cn/get` | ✅ 2.2s | `data.ip`、`data.country_code`（**小写** `cn`）、`data.prov`、`data.city`、`data.isp` | 字段最全，有国家码；偏慢；官网称每 IP 60 次 / 分钟 |
| `pconline` | `https://whois.pconline.com.cn/ipJson.jsp?json=true` | ✅ 0.8s | `ip`、`pro`、`city`、`addr`（含运营商简称） | 响应前有多行空白需先 trim；**无国家字段**；按 GBK 转码 |
| ~~`baidu-qifu`~~ | `qifu-api.baidubce.com/...` | ❌ 404 | | 已下线，移除 |
| ~~`speedtest-cn`~~ | `forge.speedtest.cn/...` | ❌ 404 | | 已下线，移除 |
| ~~`3322`~~ | `https://ip.3322.net` | ❌ 证书过期 | | 移除 |
| ~~`ipw-v4` / `ipw-v6`~~ | `4.ipw.cn` / `6.ipw.cn` | ❌ 域名无法解析 | | 移除 |

**默认**：主 `ipip`，备用 `ip9`，再备用 `pconline`。

## 境外

| ID | 地址 | 实测 | 返回字段 | 备注 |
| --- | --- | --- | --- | --- |
| `cloudflare` | `https://www.cloudflare.com/cdn-cgi/trace` | ✅ 1.1s | `key=value` 文本：`ip`、`loc`（国家码） | 无配额压力，适合高频；只有国家码 |
| `ip-sb` | `https://api.ip.sb/geoip` | ✅ 1.9s | `ip`、`country_code`、`region`、`city`、`isp`、`organization`、`asn`（数字） | 运营商 / ASN 齐全 |
| `ipwhois` | `https://ipwho.is/` | ✅ 0.9s | `ip`、`success`、`country_code`、`region`、`city`，运营商在 `connection` 对象内 | `connection` 字段在本次输出截断处之后，**未亲见**，实现时需复核 |
| `ipinfo` | `https://ipinfo.io/json` | ✅ 1.6s | `ip`、`country`、`region`、`city`、`org`（形如 `AS56048 China Mobile ...`） | 无 Token 约 1000 次 / 天，按出口 IP 共享；最小间隔设 120 秒 |
| `ip-api` | `http://ip-api.com/json` | ✅ 0.4s | `query`（即 IP）、`countryCode`、`regionName`、`city`、`isp`、`org`、`as`；`status` 为 `success` 才有效 | 仅 HTTP，需 ATS 例外，默认不启用；45 次 / 分钟 |
| ~~`ipapi-co`~~ | `https://ipapi.co/json` | ❌ 403 | | 被 Cloudflare 人机验证拦截，移除 |
| ~~`ipify-v4`~~ | `https://api.ipify.org` | ❌ 连接失败 | | 在测试网络下不可达，移除 |

**默认**：主 `cloudflare`；规则用到运营商 / ASN 时改为主 `ip-sb`、备用 `ipwhois`、再备用 `ipinfo`。

## IPv6（待验证）

上一轮的两个 IPv6 接口都无法解析。`api6.ipify.org` 解析失败也可能是测试机没有 IPv6 地址。新的候选已加入脚本，需在**有 IPv6 的网络**下重测：

| ID | 地址 | 组 |
| --- | --- | --- |
| `ident-v6` | `https://v6.ident.me` | 境外 |
| `icanhazip-v6` | `https://ipv6.icanhazip.com` | 境外 |
| `ipify-v64` | `https://api64.ipify.org` | 境外（双栈，优先 v6） |

测试机执行 `curl -6 https://v6.ident.me` 先后出现两种失败：

1. “无法解析域名”：DNS 没有返回 IPv6 记录（如代理工具的 DNS 关闭了 IPv6）
2. 域名能解析，但 5 ms 内连接失败：系统没有 IPv6 路由，请求没发出本机就被拒绝

两次结论相同：**测试机当前没有可用的 IPv6 出口**。IPv6 接口只能等有 IPv6 的网络再测。

境内暂无可用的 IPv6 候选。IPv6 检测点 MVP 先只提供境外接口。

## 解析要点

以下差异需要在“响应格式 → 统一结果”的解析层处理：

| 问题 | 处理 |
| --- | --- |
| 国家码大小写不一（`ip9` 为小写） | 统一转大写 |
| `ipip` 只有中文国家名，`pconline` 连国家都没有 | 中文国家名 → 国家码映射；`pconline` 若省份字段非空则视为 `CN` |
| IP 字段名不一（`ip` / `query` / `data.ip`） | 每个内置接口声明自己的字段路径 |
| 成功标志不一（`ret` / `status` / `success`） | 每个接口声明成功条件，不满足判“检测失败” |
| 运营商字段格式不一（`org` 带 `AS` 前缀、`asn` 为纯数字） | 统一拆成 `asn`（数字）与 `org`（名称） |
| `cloudflare` 是 `key=value` 文本 | 单独的文本解析器 |
| `pconline` 前导空白、GBK 编码 | 先转码再 trim |

## 分流提醒

“境内 / 境外”只描述服务器位置，**实际走哪条出口由用户的分流规则决定**。例如规则按域名后缀判断时，`ip9.com.cn` 与 `myip.ipip.net` 可能命中不同规则。建检测点时的“测试一次”和详情里显示的请求域名，就是用来核对这一点的。

## 资料来源

- [IPinfo：免费计划的用量限制](https://support.ipinfo.io/hc/en-us/articles/30792535492626-What-Is-the-Usage-Limit-for-the-Free-Plan)
- [IPinfo：无账号公共接口与免费计划的区别](https://support.ipinfo.io/hc/en-us/articles/30792479436562-What-Is-the-Difference-Between-Using-the-Authenticated-Free-Plan-and-the-Public-API-With-No-Account)
- [IP9.COM.CN](https://www.ip9.com.cn/)
- [ihmily/ip-info-api：免费 IP 接口汇总](https://github.com/ihmily/ip-info-api)
