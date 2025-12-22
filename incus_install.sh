#!/bin/bash

# Incus 安装脚本（含自动初始化配置）
# 支持 Ubuntu/Debian 系统

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        log_info "检测到系统: $OS $VER"
    else
        log_error "无法检测系统类型"
        exit 1
    fi
}

# 安装 Incus (Ubuntu/Debian)
install_incus_debian() {
    log_info "开始在 Debian/Ubuntu 系统上安装 Incus..."
    
    # 更新包列表
    log_info "更新软件包列表..."
    apt-get update
    
    # 安装依赖
    log_info "安装必要的依赖包..."
    apt-get install -y curl gnupg2 software-properties-common
    
    # 添加 Zabbly 仓库（Incus 官方推荐）
    log_info "添加 Incus 官方仓库..."
    mkdir -p /etc/apt/keyrings/
    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
    
    # 根据系统版本添加仓库
    if [ "$OS" = "ubuntu" ]; then
        echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/zabbly-incus-stable.list
    elif [ "$OS" = "debian" ]; then
        echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/zabbly-incus-stable.list
    fi
    
    # 更新包列表
    log_info "更新软件包列表..."
    apt-get update
    
    # 安装 Incus
    log_info "安装 Incus..."
    apt-get install -y incus
    
    log_info "Incus 安装完成！"
}

# 配置系统参数
configure_system() {
    log_info "配置系统参数..."
    
    # 启用网络转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    
    sysctl -p
    
    log_info "系统参数配置完成"
}

# 启动 Incus 服务
start_incus() {
    log_info "启动 Incus 服务..."
    systemctl enable incus
    systemctl start incus
    
    # 等待服务启动
    sleep 3
    
    if systemctl is-active --quiet incus; then
        log_info "Incus 服务已成功启动"
    else
        log_error "Incus 服务启动失败"
        exit 1
    fi
}

# 将当前用户添加到 incus-admin 组
add_user_to_group() {
    if [ -n "$SUDO_USER" ]; then
        log_info "将用户 $SUDO_USER 添加到 incus-admin 组..."
        usermod -aG incus-admin $SUDO_USER
        log_warn "请注销并重新登录以使组权限生效，或运行: newgrp incus-admin"
    fi
}

# 初始化 Incus
init_incus() {
    log_info "初始化 Incus..."
    
    read -p "是否现在进行 Incus 初始化配置? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "跳过初始化，您可以稍后运行 'incus admin init' 来配置"
        return
    fi
    
    # 询问存储目录
    log_info "配置存储池..."
    read -p "请输入存储数据的目录路径 [默认: /var/lib/incus/storage-pools/default]: " storage_path
    
    # 如果用户没有输入，使用默认路径
    if [ -z "$storage_path" ]; then
        storage_path="/var/lib/incus/storage-pools/default"
    fi
    
    # 检查目录是否存在
    if [ -d "$storage_path" ]; then
        # 检查目录是否为空
        if [ "$(ls -A $storage_path 2>/dev/null)" ]; then
            log_warn "目录 $storage_path 不为空"
            read -p "是否在此目录下创建子目录 'incus' 用于存储? (y/n): " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                storage_path="$storage_path/incus"
                mkdir -p "$storage_path"
                log_info "已创建目录: $storage_path"
            else
                log_error "存储目录必须为空，初始化取消"
                return 1
            fi
        fi
    else
        # 目录不存在，创建它
        log_info "创建目录: $storage_path"
        mkdir -p "$storage_path"
    fi
    
    # 使用 preseed 方式自动初始化
    log_info "正在配置 Incus（使用默认设置）..."
    
    cat <<EOF | incus admin init --preseed
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: auto
  description: ""
  name: incusbr0
  type: bridge
storage_pools:
- config:
    source: $storage_path
  description: ""
  name: default
  driver: dir
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
cluster: null
EOF
    
    if [ $? -eq 0 ]; then
        log_info "Incus 初始化完成！"
        log_info "存储池: default"
        log_info "存储路径: $storage_path"
        log_info "网络桥接: incusbr0 (自动配置 IPv4/IPv6)"
    else
        log_error "Incus 初始化失败"
        return 1
    fi
}

# 显示版本信息
show_version() {
    log_info "安装的 Incus 版本:"
    incus version
}

# 显示使用示例
show_examples() {
    log_info ""
    log_info "=== 快速入门示例 ==="
    log_info ""
    log_info "1. 创建 Ubuntu 22.04 容器:"
    log_info "   incus launch images:ubuntu/22.04 my-container"
    log_info ""
    log_info "2. 查看容器列表:"
    log_info "   incus list"
    log_info ""
    log_info "3. 进入容器:"
    log_info "   incus exec my-container -- bash"
    log_info ""
    log_info "4. 停止容器:"
    log_info "   incus stop my-container"
    log_info ""
    log_info "5. 删除容器:"
    log_info "   incus delete my-container"
    log_info ""
    log_info "更多信息请访问: https://linuxcontainers.org/incus/"
}

# 主函数
main() {
    log_info "=== Incus 安装脚本 ==="
    
    check_root
    detect_os
    
    case $OS in
        ubuntu|debian)
            install_incus_debian
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            log_warn "此脚本目前仅支持 Ubuntu 和 Debian"
            exit 1
            ;;
    esac
    
    configure_system
    start_incus
    add_user_to_group
    show_version
    
    log_info ""
    log_info "=== 基础安装完成 ==="
    
    init_incus
    
    log_info ""
    log_info "=== 安装和配置全部完成 ==="
    
    if [ -n "$SUDO_USER" ]; then
        log_info ""
        log_info "重要提示:"
        log_info "1. 请重新登录或运行以下命令使组权限生效:"
        log_info "   newgrp incus-admin"
        log_info ""
    fi
    
    show_examples
}

# 运行主函数
main