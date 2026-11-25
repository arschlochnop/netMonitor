#!/usr/bin/env bash
# 逐个请求候选 IP 查询接口，打印状态码、耗时和响应开头，用于核对 docs/endpoints.md。
# 用法：scripts/check-endpoints.sh            （跟随当前 shell 的代理环境变量）
# 结果取决于运行时的网络与分流规则，请在实际要监控的那台 Mac 上运行。
set -u

ENDPOINTS=(
  "cn|ipip|https://myip.ipip.net/json"
  "cn|ip9|https://ip9.com.cn/get"
  "cn|pconline|https://whois.pconline.com.cn/ipJson.jsp?json=true"
  "global|cloudflare|https://www.cloudflare.com/cdn-cgi/trace"
  "global|ip-sb|https://api.ip.sb/geoip"
  "global|ipwhois|https://ipwho.is/"
  "global|ipinfo|https://ipinfo.io/json"
  "global|ip-api|http://ip-api.com/json"
  "v6|ident-v6|https://v6.ident.me"
  "v6|icanhazip-v6|https://ipv6.icanhazip.com"
  "v6|ipify-v64|https://api64.ipify.org"
)

for entry in "${ENDPOINTS[@]}"; do
  IFS='|' read -r group id url <<<"$entry"
  body_file=$(mktemp)
  meta=$(curl -sS -m 10 -A "NetMonitor-check/0.1" -o "$body_file" \
    -w '%{http_code} %{time_total}s' "$url" 2>&1)
  printf '\n=== [%s] %s  %s\n    %s\n' "$group" "$id" "$url" "$meta"
  # pconline 返回 GBK，其余为 UTF-8
  if [ "$id" = "pconline" ]; then
    iconv -f gbk -t utf-8 -c "$body_file" | head -c 1500
  else
    head -c 1500 "$body_file"
  fi
  echo
  rm -f "$body_file"
done
