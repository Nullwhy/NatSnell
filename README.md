[中文](README.md) 

# Snell 一键脚本

bash <(curl -fsSL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh)

### ShadowTLS 说明

在脚本中为 Snell 配置 ShadowTLS 后，脚本会把 Snell 后端改为仅监听 `127.0.0.1:Snell端口`，客户端只连接 ShadowTLS 对外端口。这样可以避免原始 Snell 端口继续暴露在公网。


| 标签 | 版本 | 说明 |
|------|------|------|
| `latest` | Snell v5.0.1 | 固定指向 v5，不指向 v6 |
| `v4` | Snell v4.1.1 | v4 当前推荐版本 |
| `v5` | Snell v5.0.1 | v5 当前推荐版本 |
| `v6` | Snell v6.0.0b4 | v6 当前 Beta 版本 |
| `v4.0.0` / `v4.0.1` / `v4.1.0` / `v4.1.1` | Snell v4 | 固定版本标签 |
| `v5.0.0` / `v5.0.1` | Snell v5 | 固定版本标签 |
| `v6.0.0b1` / `v6.0.0b2` / `v6.0.0b3` / `v6.0.0b4` | Snell v6 beta | 固定版本标签 |

架构支持：
- v4 / v5: `linux/amd64`、`linux/arm64`、`linux/arm/v7`
- v6: `linux/amd64`、`linux/arm64`


客户端填写：

| 项目 | 填写内容 |
|------|----------|
| 服务器 | VPS 公网 IP 或域名 |
| 端口 | ShadowTLS 对外端口，示例为 `8443` |
| Snell 版本 | `5` |
| Snell PSK | `./snell-config/snell-server.conf` 里的 `psk` |
| ShadowTLS 密码 | `./snell-config/shadowtls-password` 的内容，或手动传入的 `SHADOWTLS_PASSWORD` |
| ShadowTLS SNI | `SHADOWTLS_SNI`，默认 `www.microsoft.com` |
| ShadowTLS 版本 | `3` |

### Snell 协议

Snell 协议是由 Surge 团队设计的一种轻量级、高效的加密代理协议，专注于提供安全、快速的网络传输服务。该协议通过简洁的设计和加密技术，满足用户对隐私保护和高性能传输的需求。

### Snell v4 vs v5 对比

| 特性 | Snell v4 | Snell v5 |
|------|----------|----------|
| 状态 | 稳定版 | 最新版 |
| 安全性 | 支持 | 支持 |
| QUIC Proxy | 不支持 | 支持 |
| Dynamic Record Sizing | 不支持 | 支持 |
| 出口控制 | 不支持 | 支持 |

### ShadowTLS

ShadowTLS 是一个轻量级的 TLS 伪装工具，可以模拟正常 HTTPS 流量，用于提升连接隐蔽性和稳定性。

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
