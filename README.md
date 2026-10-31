# sing-box-boom 🚀

> 全面复刻并超越 **233boy/sing-box** 的全协议多节点现代管理套件。
> 支持 **VLESS-Reality / Hysteria 2 / TUIC v5 / Shadowsocks 2022** 多协议一机共存。
> 搭载 **全球高校独立源站动态优选引擎**（已彻底清退 Cloudflare），杜绝被借道白嫖流量。

---

## 🌟 协议支持矩阵

| 协议 | 传输层 / 特性 | 推荐应用场景 |
| :--- | :--- | :--- |
| **VLESS-Reality** | TCP + Vision 流控 + 高校动态优选防白嫖 | 最稳日常主力翻墙、防 GFW 主动嗅探 |
| **Hysteria 2** | UDP 暴力加速 / 极速抗丢包 / 自签 ECDSA | 晚高峰、跨洲长距离高丢包网络、游戏加速 |
| **TUIC v5** | QUIC 0-RTT 握手 / 内置 BBR 算法 | 移动网络、弱网环境下极速低延迟开屏 |
| **Shadowsocks 2022** | 现代抗重放加密 (`2022-blake3-aes-128-gcm`) | 路由器轻量客户端、纯净低功耗设备 |
| **多节点共存** | 支持一机同时开 4 个甚至更多不同协议端口 | 多客户端灵活分流、好友互不干扰 |
| **系统 BBR** | Linux 原生 BBR + FQ 算法一键开启 | 显著提升 VPS 的 TCP/UDP 传输速率与稳定性 |

---

## 🚀 一键安装与管理命令

在你的 Linux VPS 上直接执行（GitHub 原生直链，秒级同步）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh)
```

> **国内备用加速源**（如遇 GFW 阻断可使用）：
> `bash <(curl -fsSL https://cdn.jsdelivr.net/gh/shangusl/sing-box-boom@main/install.sh)`
> 或 `bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh)`

---

## 🛠 命令行快捷指令体系 (与 233boy 完全对标)

安装后，在终端随时直接敲快捷命令：

```bash
sb               # 呼出交互式管理总控制台
sb add           # 快速添加一个新协议节点 (Reality / Hy2 / TUIC / SS)
sb del           # 快速删除指定的节点
sb info          # 查看所有节点的配置信息、连接串与终端二维码
sb bbr           # 一键开启系统内核原生 BBR 加速
sb start         # 启动 sing-box 服务
sb stop          # 停止 sing-box 服务
sb restart       # 重启 sing-box 服务
sb status        # 查看服务运行状态
sb log           # 实时查看运行日志 (tail -f)
```

---

## 📄 开源许可
MIT License.
