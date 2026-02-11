#!/bin/bash

#######################################
# Incus 一键安装脚本 for CentOS 8 (改进版)
# 版本: 2.0
# 作者: Claude
# 日期: 2026-02-11
# 
# 改进内容:
# - 解决重启后服务失效问题
# - 添加网络检查和重试机制
# - 更好的错误处理和日志
# - 使用变量而非硬编码路径
# - 完整的清理功能
#######################################

set -e  # 遇到错误立即退出

# ============= 配置变量 =============
INCUS_BUILD_DIR="/tmp/incus-build"
DEPS_DIR="${HOME}/go/deps"
INSTALL_PREFIX="/usr/local"
LIB_DIR="${INSTALL_PREFIX}/lib"
BIN_DIR="${INSTALL_PREFIX}/bin"

# ============= 颜色定义 =============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============= 日志函数 =============
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ============= 检查函数 =============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

check_system() {
    log_step "检查系统兼容性..."
    if [[ ! -f /etc/centos-release ]] && [[ ! -f /etc/redhat-release ]]; then
        log_error "此脚本仅支持 CentOS/RHEL 系统"
        exit 1
    fi
    log_info "系统检查通过"
}

check_network() {
    log_step "检查网络连接..."
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        log_warn "网络连接可能有问题"
        read -p "是否继续？(y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    log_info "网络连接正常"
}

# ============= 安装步骤 =============
install_dependencies() {
    log_step "步骤 1/9: 安装基础依赖包..."
    
    log_info "更新软件包缓存..."
    dnf makecache --refresh || log_warn "缓存更新失败"
    
    log_info "安装编译工具..."
    dnf install -y git make gcc autoconf automake libtool pkg-config
    
    log_info "安装开发库..."
    dnf install -y libuv-devel sqlite-devel libacl-devel libcap-devel libudev-devel
    
    log_info "安装运行时依赖..."
    dnf install -y attr patchelf
    
    log_info "尝试安装 LXC..."
    dnf install -y lxc lxc-libs lxc-devel 2>/dev/null || log_warn "LXC 开发包不可用"
    
    # 验证关键工具
    local missing=()
    for tool in git make gcc pkg-config patchelf setfattr; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "工具安装失败: ${missing[*]}"
        exit 1
    fi
    
    log_info "所有依赖安装完成 ✓"
}

install_go() {
    log_step "步骤 2/9: 安装 Go..."
    
    if ! command -v go &>/dev/null; then
        log_info "安装系统 Go..."
        dnf install -y golang
    fi
    
    local go_ver=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || echo "0")
    log_info "当前 Go 版本: $go_ver"
    
    if [[ $(echo -e "$go_ver\n1.21" | sort -V | head -n1) != "1.21" ]]; then
        log_warn "升级 Go 到 1.22.0..."
        
        local go_tar="/tmp/go.tar.gz"
        local go_url="https://go.dev/dl/go1.22.0.linux-amd64.tar.gz"
        
        # 下载（带重试）
        local retry=0
        while [[ $retry -lt 3 ]]; do
            wget -q --show-progress -O "$go_tar" "$go_url" && break
            retry=$((retry + 1))
            log_warn "下载失败，重试 $retry/3..."
            sleep 2
        done
        
        [[ ! -f "$go_tar" ]] && { log_error "Go 下载失败"; exit 1; }
        
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "$go_tar"
        rm -f "$go_tar"
        
        export PATH=$PATH:/usr/local/go/bin
        log_info "Go 已升级到 $(go version)"
    fi
    
    export GOPATH="${HOME}/go"
    mkdir -p "$GOPATH"
    log_info "Go 安装完成 ✓"
}

download_incus() {
    log_step "步骤 3/9: 下载 Incus 源码..."
    
    [[ -d "$INCUS_BUILD_DIR" ]] && rm -rf "$INCUS_BUILD_DIR"
    mkdir -p "$INCUS_BUILD_DIR"
    cd "$INCUS_BUILD_DIR"
    
    # 克隆（带重试）
    local retry=0
    while [[ $retry -lt 3 ]]; do
        git clone --depth 1 https://github.com/lxc/incus && break
        retry=$((retry + 1))
        log_warn "克隆失败，重试 $retry/3..."
        sleep 2
        rm -rf incus
    done
    
    [[ ! -d "$INCUS_BUILD_DIR/incus" ]] && { log_error "源码下载失败"; exit 1; }
    
    cd incus
    log_info "源码下载完成 ✓"
}

build_dependencies() {
    log_step "步骤 4/9: 编译依赖库..."
    
    cd "$INCUS_BUILD_DIR/incus"
    log_info "编译 raft 和 cowsql（需要几分钟）..."
    make deps
    
    # 验证
    [[ ! -f "${DEPS_DIR}/raft/.libs/libraft.so" ]] && { log_error "raft 编译失败"; exit 1; }
    [[ ! -f "${DEPS_DIR}/cowsql/.libs/libcowsql.so" ]] && { log_error "cowsql 编译失败"; exit 1; }
    
    # 设置环境变量
    export CGO_CFLAGS="-I${DEPS_DIR}/raft/include/ -I${DEPS_DIR}/cowsql/include/"
    export CGO_LDFLAGS="-L${DEPS_DIR}/raft/.libs -L${DEPS_DIR}/cowsql/.libs/"
    export LD_LIBRARY_PATH="${DEPS_DIR}/raft/.libs/:${DEPS_DIR}/cowsql/.libs/"
    export CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"
    
    log_info "依赖库编译完成 ✓"
}

setup_environment_variables() {
    log_step "步骤 5/9: 配置环境变量..."
    
    local bashrc="${HOME}/.bashrc"
    
    if ! grep -q "# Incus build environment" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" << ENVEOF

# Incus build environment
export CGO_CFLAGS="-I${DEPS_DIR}/raft/include/ -I${DEPS_DIR}/cowsql/include/"
export CGO_LDFLAGS="-L${DEPS_DIR}/raft/.libs -L${DEPS_DIR}/cowsql/.libs/"
export LD_LIBRARY_PATH="${DEPS_DIR}/raft/.libs/:${DEPS_DIR}/cowsql/.libs/"
export CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"
ENVEOF
        log_info "环境变量已添加"
    fi
    
    if [[ -d "/usr/local/go/bin" ]] && ! grep -q "/usr/local/go/bin" "$bashrc" 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> "$bashrc"
    fi
    
    log_info "环境变量配置完成 ✓"
}

build_incus() {
    log_step "步骤 6/9: 编译 Incus..."
    
    cd "$INCUS_BUILD_DIR/incus"
    log_info "开始编译（需要几分钟）..."
    
    make || { log_error "编译失败"; exit 1; }
    
    [[ ! -f "${GOPATH}/bin/incusd" ]] && { log_error "incusd 未生成"; exit 1; }
    
    log_info "Incus 编译完成 ✓"
}

install_incus() {
    log_step "步骤 7/9: 安装 Incus..."
    
    # 复制二进制
    log_info "安装二进制文件..."
    cp -v "${GOPATH}"/bin/incus* "${BIN_DIR}/" 2>/dev/null || true
    cp -v "${GOPATH}"/bin/lxc-to-incus "${BIN_DIR}/" 2>/dev/null || true
    cp -v "${GOPATH}"/bin/lxd-to-incus "${BIN_DIR}/" 2>/dev/null || true
    
    [[ ! -f "${BIN_DIR}/incusd" ]] && { log_error "incusd 安装失败"; exit 1; }
    
    # 复制库文件到系统目录（重要：确保重启后可用）
    log_info "安装依赖库..."
    cp -v "${DEPS_DIR}"/raft/.libs/*.so* "${LIB_DIR}/"
    cp -v "${DEPS_DIR}"/cowsql/.libs/*.so* "${LIB_DIR}/"
    
    # 配置系统库路径（持久化配置）
    log_info "配置系统库路径..."
    echo "${LIB_DIR}" > /etc/ld.so.conf.d/incus.conf
    ldconfig
    
    # 验证库加载
    ldconfig -p | grep -q libcowsql || { log_error "库未正确加载"; exit 1; }
    
    # 修复 RPATH（确保重启后找得到库）
    log_info "修复库路径..."
    patchelf --remove-rpath "${BIN_DIR}/incusd" 2>/dev/null || true
    patchelf --force-rpath --set-rpath "${LIB_DIR}" "${BIN_DIR}/incusd"
    
    if [[ -f "${LIB_DIR}/libcowsql.so.0" ]]; then
        patchelf --remove-rpath "${LIB_DIR}/libcowsql.so.0" 2>/dev/null || true
        patchelf --force-rpath --set-rpath "${LIB_DIR}" "${LIB_DIR}/libcowsql.so.0"
    fi
    
    # 验证链接
    if ! ldd "${BIN_DIR}/incusd" | grep -q "${LIB_DIR}/libcowsql"; then
        log_warn "库链接可能有问题，但继续安装..."
    fi
    
    # 创建目录
    mkdir -p /var/lib/incus /var/log/incus /etc/incus
    
    # 创建组
    getent group incus-admin >/dev/null || {
        groupadd --system incus-admin
        log_info "已创建 incus-admin 组"
    }
    
    log_info "Incus 安装完成 ✓"
}

create_systemd_service() {
    log_step "步骤 8/9: 创建 systemd 服务..."
    
    cat > /etc/systemd/system/incus.service << 'EOF'
[Unit]
Description=Incus - Container and virtual machine manager
Documentation=https://linuxcontainers.org/incus
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/incusd --group incus-admin
Restart=on-failure
RestartSec=5s
TimeoutStartSec=600s
TimeoutStopSec=30s
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable incus
    
    log_info "systemd 服务已创建 ✓"
}

start_incus() {
    log_step "步骤 9/9: 启动 Incus 服务..."
    
    systemctl start incus
    sleep 5
    
    if systemctl is-active --quiet incus; then
        log_info "Incus 服务启动成功 ✓"
    else
        log_error "服务启动失败"
        log_info "查看日志: journalctl -u incus -n 50"
        exit 1
    fi
}

verify_installation() {
    log_info "验证安装..."
    echo ""
    echo "========================================="
    echo "Incus 版本: $("${BIN_DIR}/incusd" --version)"
    echo "========================================="
    echo ""
    systemctl status incus --no-pager -l || true
}

cleanup_build_dir() {
    log_info "清理构建文件..."
    read -p "是否删除构建目录以节省空间？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INCUS_BUILD_DIR"
        log_info "构建目录已删除"
    fi
}

show_next_steps() {
    cat << 'EOF'

=========================================
 🎉 安装完成！后续步骤：
=========================================

1. 添加用户到 incus-admin 组:
   usermod -aG incus-admin $USER
   newgrp incus-admin

2. 初始化 Incus:
   incus admin init

3. 测试:
   incus version
   incus list

4. 创建容器:
   incus launch images:ubuntu/22.04 test
   incus exec test -- bash

=========================================
 常用命令
=========================================
  服务状态: systemctl status incus
  查看日志: journalctl -u incus -f
  重启服务: systemctl restart incus

=========================================
 重启后自动启动
=========================================
✓ systemd 服务已配置为开机自启
✓ 库路径已写入 /etc/ld.so.conf.d/incus.conf
✓ 二进制文件 RPATH 已修复
✓ 重启系统后 Incus 将自动启动

=========================================
编译环境变量已添加到 ~/.bashrc
如需重新编译，运行: source ~/.bashrc
=========================================

EOF
}

cleanup_on_error() {
    log_error "安装失败，正在清理..."
    systemctl stop incus 2>/dev/null || true
    systemctl disable incus 2>/dev/null || true
    rm -f /etc/systemd/system/incus.service
    systemctl daemon-reload
}

# ============= 主函数 =============
main() {
    clear
    cat << 'EOF'
╔═══════════════════════════════════════╗
║  Incus 一键安装脚本 v2.0             ║
║  for CentOS 8                         ║
╚═══════════════════════════════════════╝
EOF
    echo ""
    
    trap cleanup_on_error ERR
    
    check_root
    check_system
    check_network
    install_dependencies
    install_go
    download_incus
    build_dependencies
    setup_environment_variables
    build_incus
    install_incus
    create_systemd_service
    start_incus
    verify_installation
    cleanup_build_dir
    show_next_steps
    
    log_info "✅ 全部完成！"
}

main "$@"
