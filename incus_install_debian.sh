#!/bin/bash

# Incus 一键安装脚本
# 支持 Ubuntu/Debian 系统

set -e

# 颜色定义
# 检测终端是否支持颜色
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ $(tput colors) -ge 8 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    # 终端不支持颜色，使用空字符串
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

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

log_step() {
    echo -e "${BLUE}[步骤]${NC} $1"
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
    else
        log_error "无法检测系统类型"
        exit 1
    fi
}

# 在脚本开始时收集所有配置
collect_config() {
    echo ""
    echo "========================================"
    echo "    Incus 安装配置向导"
    echo "========================================"
    echo ""
    
    # 检测系统
    detect_os
    log_info "检测到系统: $OS $VER"
    echo ""
    
    # 询问是否进行安装
    read -p "是否继续安装 Incus? [Y/n]: " -r
    REPLY=${REPLY:-Y}  # 如果为空，默认为 Y
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "安装已取消"
        exit 0
    fi
    echo ""
    
    # 询问是否进行初始化配置
    read -p "是否在安装后自动初始化 Incus? [Y/n]: " -r
    REPLY=${REPLY:-Y}  # 如果为空，默认为 Y
    DO_INIT=$REPLY
    echo ""
    
    # 如果选择初始化，询问存储目录
    if [[ $DO_INIT =~ ^[Yy]$ ]]; then
        log_info "配置存储池..."
        read -p "请输入存储数据的目录路径 [默认: /var/lib/incus/storage-pools/default]: " STORAGE_PATH
        
        # 如果用户没有输入，使用默认路径
        if [ -z "$STORAGE_PATH" ]; then
            STORAGE_PATH="/var/lib/incus/storage-pools/default"
        fi
        
        log_info "存储路径设置为: $STORAGE_PATH"
        echo ""
    fi
    
    # 显示配置摘要
    echo "========================================"
    echo "    配置摘要"
    echo "========================================"
    echo "系统: $OS $VER"
    echo "安装 Incus: 是"
    if [[ $DO_INIT =~ ^[Yy]$ ]]; then
        echo "自动初始化: 是"
        echo "存储路径: $STORAGE_PATH"
    else
        echo "自动初始化: 否"
    fi
    echo "========================================"
    echo ""
    
    read -p "确认以上配置并开始安装? [Y/n]: " -r
    REPLY=${REPLY:-Y}  # 如果为空，默认为 Y
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "安装已取消"
        exit 0
    fi
    
    echo ""
    log_info "开始安装，请稍候..."
    echo ""
    sleep 2
}

# 安装 Incus (Ubuntu/Debian)
install_incus_debian() {
    log_step "1/6 安装 Incus 软件包"
    
    # 更新包列表
    log_info "更新软件包列表..."
    apt-get update -qq
    
    # 安装依赖
    log_info "安装必要的依赖包..."
    apt-get install -y -qq curl gnupg2 software-properties-common > /dev/null 2>&1
    
    # 添加 Zabbly 仓库（Incus 官方推荐）
    log_info "添加 Incus 官方仓库..."
    mkdir -p /etc/apt/keyrings/
    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg 2>/dev/null
    
    # 根据系统版本添加仓库
    if [ "$OS" = "ubuntu" ]; then
        echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/zabbly-incus-stable.list > /dev/null
    elif [ "$OS" = "debian" ]; then
        echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/zabbly-incus-stable.list > /dev/null
    fi
    
    # 更新包列表
    log_info "更新软件包列表..."
    apt-get update -qq
    
    # 安装 Incus
    log_info "安装 Incus..."
    apt-get install -y incus > /dev/null 2>&1
    
    log_info "✓ Incus 安装完成"
    echo ""
}

# 配置系统参数
configure_system() {
    log_step "2/6 配置系统参数"
    
    # 启用网络转发
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    
    sysctl -p > /dev/null 2>&1
    
    log_info "✓ 系统参数配置完成"
    echo ""
}

# 启动 Incus 服务
start_incus() {
    log_step "3/6 启动 Incus 服务"
    
    systemctl enable incus > /dev/null 2>&1
    systemctl start incus
    
    # 等待服务启动
    sleep 3
    
    if systemctl is-active --quiet incus; then
        log_info "✓ Incus 服务已成功启动"
    else
        log_error "Incus 服务启动失败"
        exit 1
    fi
    echo ""
}

# 将当前用户添加到 incus-admin 组
add_user_to_group() {
    log_step "4/6 配置用户权限"
    
    if [ -n "$SUDO_USER" ]; then
        log_info "将用户 $SUDO_USER 添加到 incus-admin 组..."
        usermod -aG incus-admin $SUDO_USER
        log_info "✓ 用户权限配置完成"
    else
        log_info "✓ 跳过用户权限配置（非 sudo 执行）"
    fi
    echo ""
}

# 显示版本信息
show_version() {
    log_step "5/6 验证安装"
    
    log_info "Incus 版本:"
    incus version
    echo ""
}

# 初始化 Incus
init_incus() {
    log_step "6/6 初始化 Incus"
    
    if [[ ! $DO_INIT =~ ^[Yy]$ ]]; then
        log_info "✓ 跳过自动初始化"
        return
    fi
    
    # 处理存储目录
    if [ -d "$STORAGE_PATH" ]; then
        # 检查目录是否为空
        if [ "$(ls -A $STORAGE_PATH 2>/dev/null)" ]; then
            log_warn "目录 $STORAGE_PATH 不为空，将在其下创建 incus 子目录"
            STORAGE_PATH="$STORAGE_PATH/incus"
            mkdir -p "$STORAGE_PATH"
            log_info "已创建目录: $STORAGE_PATH"
        fi
    else
        # 目录不存在，创建它
        log_info "创建目录: $STORAGE_PATH"
        mkdir -p "$STORAGE_PATH"
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
    source: $STORAGE_PATH
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
        log_info "✓ Incus 初始化完成"
        log_info "  存储池: default"
        log_info "  存储路径: $STORAGE_PATH"
        log_info "  网络桥接: incusbr0 (自动配置 IPv4/IPv6)"
    else
        log_error "Incus 初始化失败"
        return 1
    fi
    echo ""
}

# 显示完成信息
show_completion() {
    echo ""
    echo "========================================"
    echo "    安装完成！"
    echo "========================================"
    echo ""
    
    if [ -n "$SUDO_USER" ]; then
        log_info "重要提示:"
        echo -e "  请重新登录或运行以下命令使组权限生效:"
        echo -e "  ${GREEN}newgrp incus-admin${NC}"
        echo ""
    fi
    
    log_info "快速入门:"
    echo ""
    echo "  1. 创建 Ubuntu 22.04 容器:"
    echo -e "     ${BLUE}incus launch images:ubuntu/22.04 my-container${NC}"
    echo ""
    echo "  2. 查看容器列表:"
    echo -e "     ${BLUE}incus list${NC}"
    echo ""
    echo "  3. 进入容器:"
    echo -e "     ${BLUE}incus exec my-container -- bash${NC}"
    echo ""
    echo "  4. 停止容器:"
    echo -e "     ${BLUE}incus stop my-container${NC}"
    echo ""
    echo "  5. 删除容器:"
    echo -e "     ${BLUE}incus delete my-container${NC}"
    echo ""
    log_info "更多信息: https://linuxcontainers.org/incus/"
    echo ""
    echo "========================================"
}

# 主函数
main() {
    check_root
    
    # 首先收集所有配置
    collect_config
    
    # 然后一键执行安装
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
    init_incus
    show_completion
}

# 运行主函数
main
