
# 脚本仅供学习交流，严禁非法用途！造成一切后果与作者无关！

# 只适用于在 Linux 终端（LXC / NAT VPS）中运行

# NatSnell 一键脚本

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh)
```

### Snell 协议

Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和加密技术，满足用户对隐私保护和高性能传输的需求。

### ShadowTLS

ShadowTLS 是一个轻量级的 TLS 伪装工具，可以模拟正常 HTTPS 流量，用于提升连接隐蔽性和稳定性。

### ShadowTLS 说明

在脚本中为 Snell 配置 ShadowTLS 后，脚本会把 Snell 后端改为仅监听 `127.0.0.1:Snell端口`，客户端只连接 ShadowTLS 对外端口。这样可以避免原始 Snell 端口继续暴露在公网。

### Snell v4 配置
```
=== 配置信息 ===
当前安装版本: Snell v4
# 原始 Snell 配置
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, ::1, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
```

### Snell v5 配置
```
=== 配置信息 ===
当前安装版本: Snell v5
# Snell v5 配置（支持 v4 和 v5 客户端）
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true
HK = snell, 1.2.3.4, 57891, psk = xxxxxxxxxxxx, version = 5, reuse = true, tfo = true
```

### Snell + ShadowTLS 配置
```
=== 配置信息 ===
# 带 ShadowTLS 的配置
HK = snell, 1.2.3.4, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
HK = snell, ::1, 8989, psk = xxxxxxxxxxxx, version = 4, reuse = true, tfo = true, shadow-tls-password = yyyyyyyyyyyy, shadow-tls-sni = www.microsoft.com, shadow-tls-version = 3
```
</details>
