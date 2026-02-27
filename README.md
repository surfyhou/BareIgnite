# BareIgnite

**离线裸金属服务器批量部署系统** — Offline Bare Metal Server Provisioning System

> 在完全离线的数据中心环境中，通过 PXE 网络启动自动化部署操作系统并完成后置配置。

```
┌─────────────────────────────────────┐     ┌──────────────────────────────────┐
│  联网环境 - BareIgnite Forge        │     │  离线环境 - BareIgnite Deploy     │
│  (Docker 常驻服务)                   │     │  (Live USB / 控制节点)            │
│                                     │     │                                  │
│  Web UI + CLI                       │     │  bareignite.sh CLI               │
│  ├── 镜像缓存管理                    │ USB │  ├── validate / generate / start  │
│  ├── 组件更新检查                    │────>│  ├── dnsmasq + nginx + samba      │
│  ├── 智能打包 (USB/DVD)              │ DVD │  ├── PXE 引导 → OS 安装           │
│  └── 输出可启动介质                   │     │  └── Ansible 后置配置             │
└─────────────────────────────────────┘     └──────────────────────────────────┘
```

## 特性

- **全离线部署** — 所有资源打包到 USB/DVD，无需互联网
- **多 OS 支持** — RHEL/Rocky/CentOS、Ubuntu、ESXi、Windows Server、麒麟/统信
- **多架构** — x86_64 BIOS/UEFI + ARM64 (aarch64) UEFI
- **声明式配置** — 一个 YAML/JSON 规格文件定义整个数据中心
- **角色化分区** — 按服务器角色 (数据库/应用/虚拟化/存储) 自动分区
- **IP 三阶段管理** — PXE 安装 → DHCP 临时 → Ansible 最终 IP
- **Forge 打包服务** — Docker 化的镜像管理 + 智能介质打包 (Web UI + CLI)

## 支持的操作系统

| OS | 版本 | 安装方式 | 架构 |
|----|------|----------|------|
| Rocky Linux | 8, 9 | Kickstart | x86_64, aarch64 |
| RHEL | 7, 8, 9 | Kickstart | x86_64, aarch64 |
| CentOS | 7 | Kickstart | x86_64 |
| Ubuntu | 20.04, 22.04, 24.04 | Autoinstall | x86_64 |
| VMware ESXi | 7, 8 | ESXi Kickstart | x86_64 (UEFI only) |
| Windows Server | 2019, 2022 | WinPE + Autounattend | x86_64 |
| 银河麒麟 Kylin | V10 | Kickstart | x86_64, aarch64 |
| 中标麒麟 NeoKylin | — | Kickstart | x86_64 |
| 统信 UOS | — | Kickstart | x86_64, aarch64 |

## 快速开始

### 前提条件

控制节点需要安装：

```bash
# 必需
yq jq ansible dnsmasq nginx socat curl

# Windows 部署需要
samba

# Live USB 构建需要
xorriso syslinux grub2-efi-x64 shim-x64
```

### 1. 编写规格文件

```bash
cp projects/example/spec.yaml projects/myproject/spec.yaml
vim projects/myproject/spec.yaml
```

### 2. 验证规格文件

```bash
./bareignite.sh validate myproject
```

### 3. 生成配置

```bash
./bareignite.sh generate myproject
```

生成的文件包括：dnsmasq 配置、per-host DHCP 绑定、nginx 配置、每台服务器的 Kickstart/Autoinstall 应答文件、PXE/GRUB 启动菜单、Ansible inventory。

### 4. 启动服务

```bash
sudo ./bareignite.sh start myproject
```

启动 dnsmasq (DHCP+TFTP+DNS)、nginx (HTTP)、samba (Windows SMB)、回调服务器。

### 5. 监控部署

```bash
./bareignite.sh monitor myproject -w
```

实时查看每台服务器的安装状态。

### 6. 后置 IP 配置

```bash
./bareignite.sh reconfig-ip myproject
```

通过 Ansible 将数据网络重配为最终 IP。

## CLI 参考

```
Usage: bareignite.sh <command> [options] <project>

Commands:
  validate      验证 spec 文件
  generate      生成 PXE / kickstart / 服务配置
  start         启动所有部署服务
  stop          停止所有服务
  status        查看服务和部署状态
  monitor       实时部署监控 (-w 持续刷新)
  reconfig-ip   通过 Ansible 重配数据网络 IP

Options:
  -h, --help    帮助信息
  -v, --version 版本号
  --debug       调试输出
```

`<project>` 可以是 `projects/` 下的项目名，也可以是包含 `spec.yaml` 的目录路径。

## 规格文件 (Spec)

支持 YAML 和 JSON 格式。核心结构：

```yaml
project:
  name: my-datacenter
  description: "生产环境部署"

network:
  ipmi:
    subnet: 10.0.1.0/24
    gateway: 10.0.1.1
    dhcp_range: "10.0.1.100,10.0.1.200"
    dns: 10.0.1.1
  data:
    - name: management
      subnet: 10.0.2.0/24
      gateway: 10.0.2.1
      vlan: 100

defaults:
  root_password: "$6$..."        # SHA-512 hash
  timezone: Asia/Shanghai
  locale: en_US.UTF-8
  partition_scheme: generic       # generic|database|appserver|hypervisor|storage
  boot_mode: uefi
  ssh_keys:
    - "ssh-rsa AAAA..."

os_catalog:
  - id: rocky9
    family: rhel
    method: kickstart
    iso_path: images/rocky/Rocky-9-x86_64-dvd.iso

servers:
  - name: db-server-01
    role: database
    os: rocky9
    arch: x86_64
    boot_mode: uefi
    mac_addresses:
      pxe_boot: "aa:bb:cc:dd:ee:01"
      ipmi: "aa:bb:cc:dd:ee:02"
    ipmi:
      ip: 10.0.1.101
    networks:
      - name: management
        ip: 10.0.2.101
```

完整示例参见 [`projects/example/spec.yaml`](projects/example/spec.yaml)。

## PXE 启动流程

```
服务器开机
  → NIC 发送 DHCP 请求 (含 Option 93 架构信息)
  → dnsmasq 匹配 MAC 返回 IP + bootloader 路径
      BIOS:  pxelinux.0
      UEFI:  shimx64.efi → grubx64.efi
      ARM64: shimaa64.efi → grubaa64.efi
  → 加载 per-MAC 配置文件
  → HTTP 下载 kernel + initrd + 应答文件
  → 自动安装 OS
  → %post 回调通知控制节点
  → 重启
```

## 分区方案

| 角色 | 说明 |
|------|------|
| `generic` | autopart LVM，自动分配 |
| `database` | / 50G, /var 20G, /var/lib/pgsql 100G+, /tmp 10G, swap 16G |
| `appserver` | / 50G, /opt 50G+, /var/log 20G, /tmp 10G, swap 16G |
| `hypervisor` | / 50G+, swap 8G (最小化) |
| `storage` | / 30G, /data 50G+, swap 8G |

## Ansible 后置配置

安装完成后通过 Ansible 执行后置配置：

```bash
cd ansible/
ansible-playbook site.yml                    # 全部
ansible-playbook site.yml --tags network     # 仅网络重配
ansible-playbook site.yml --tags security    # 仅安全加固
```

### 内置角色

| 角色 | 功能 |
|------|------|
| `base` | 主机名、/etc/hosts、时区、基础包、sysctl |
| `network` | 数据网卡 IP、bonding、VLAN (ifcfg/netplan) |
| `users` | 管理员用户、SSH 密钥、sudo |
| `ntp` | Chrony 时间同步 |
| `security` | SSH 加固、防火墙、SELinux/AppArmor、审计 |
| `database` | 内核调优、ulimits、数据目录、I/O 调度器、禁 THP |
| `appserver` | 应用目录、网络 sysctl 调优、可选 Java/Python |
| `hypervisor` | KVM/libvirt、嵌套虚拟化、网桥 |

## BareIgnite Forge (联网打包服务)

Forge 是 Docker 化的常驻服务，在联网环境中管理 OS 镜像缓存并打包输出到存储介质。

### 启动 Forge

```bash
cd forge/
docker-compose up -d
```

访问 Web UI：`http://localhost:8000`

### Forge CLI

```bash
# 镜像管理
forge-cli images list
forge-cli images pull rocky9 x86_64
forge-cli images import /path/to/rhel9.iso
forge-cli images check-updates

# 构建打包
forge-cli build --os rocky9,ubuntu2204 --arch x86_64 --media usb --size 64G
forge-cli build --os rocky9 --media dvd
forge-cli build list
forge-cli build status <build-id>

# 组件更新
forge-cli update check
forge-cli update apply
```

### 输出介质类型

| 类型 | 说明 |
|------|------|
| **USB** | 单一可启动镜像 (Live 系统 + 全部数据)，`dd` 写入 |
| **DVD** | 多盘拆分 (Disc 1 可启动 + Disc 2+ 数据)，4.7GB/张 |
| **Data** | 仅数据目录/ISO (控制节点已有 OS 时) |

### Forge API

| 端点 | 说明 |
|------|------|
| `GET /health` | 健康检查 |
| `GET /api/status` | 系统状态 |
| `GET /api/images` | 镜像列表 |
| `POST /api/images/pull` | 下载镜像 |
| `POST /api/images/import` | 导入本地 ISO |
| `POST /api/builds` | 创建构建任务 |
| `GET /api/builds/{id}` | 构建状态 |
| `GET /api/components` | 组件版本 |
| `POST /api/components/check` | 检查更新 |
| `GET /api/media/devices` | 检测存储设备 |

## 项目结构

```
BareIgnite/
├── bareignite.sh                 # 主 CLI 入口
├── VERSION
├── conf/                         # 服务配置模板
│   ├── bareignite.conf
│   ├── dnsmasq.conf.j2
│   └── nginx.conf.j2
├── projects/                     # 每次部署一个项目
│   └── example/
│       └── spec.yaml
├── scripts/                      # 核心脚本
│   ├── lib/                      # 共享库 (common, spec-parser, mac-utils, ...)
│   ├── generators/               # 应答文件生成器 (kickstart, autoinstall, esxi, winpe)
│   ├── callbacks/                # 安装完成回调
│   ├── generate-configs.sh
│   ├── init-services.sh
│   ├── stop-services.sh
│   ├── monitor.sh
│   └── assign-ips.sh
├── templates/                    # Jinja2 模板
│   ├── kickstart/                # RHEL/Rocky/CentOS/麒麟/统信
│   ├── autoinstall/              # Ubuntu
│   ├── esxi/                     # ESXi
│   ├── windows/                  # Windows autounattend.xml
│   ├── pxe/                      # PXE/GRUB 启动菜单
│   └── partitions/               # 按角色分区方案
├── ansible/                      # 后置配置
│   ├── site.yml
│   ├── playbooks/
│   ├── roles/                    # 8 个角色
│   └── group_vars/
├── forge/                        # Forge 打包服务
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── app/                      # FastAPI 后端 + Vue.js 前端
│   ├── cli/forge-cli.sh
│   └── data/                     # OS/组件注册表
├── liveusb/                      # Live USB 构建器
│   ├── build.sh
│   ├── kickstart/liveusb.ks
│   └── overlay/
├── images/                       # OS 镜像 (git-ignored)
├── pxe/                          # PXE 引导文件 (git-ignored)
└── tools/                        # 捆绑工具 (git-ignored)
```

## 配置说明

默认配置在 `conf/bareignite.conf`：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `CONTROL_IP` | 自动检测 | 控制节点 IP |
| `IPMI_INTERFACE` | eth0 | IPMI 网络接口 |
| `HTTP_PORT` | 8080 | HTTP 服务端口 |
| `CALLBACK_PORT` | 8888 | 安装完成回调端口 |
| `DHCP_LEASE_TIME` | 1h | DHCP 租约时间 |
| `LOG_LEVEL` | info | 日志级别 |

## 工作流总览

```
1. [联网] Forge 下载/缓存 OS 镜像 → 打包到 USB/DVD
2. [运输] 携带介质到离线现场
3. [离线] Live USB 启动控制节点
4. [离线] 编辑 spec.yaml 定义服务器
5. [离线] bareignite.sh validate → generate → start
6. [离线] 目标服务器 PXE 启动 → 自动安装 OS
7. [离线] monitor 监控进度 → 全部完成
8. [离线] reconfig-ip → Ansible 配置最终网络
```

## License

MIT
