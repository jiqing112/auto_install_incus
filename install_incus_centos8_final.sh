#!/bin/bash

#######################################
# Incus 一键安装脚本 for CentOS 8 (最终完善版)
# 版本: 3.0
# 作者: Claude
# 日期: 2026-02-11
# 
# 改进内容:
# - 库文件永久安装到系统目录，编译目录可删除
# - 自动安装所有运行时依赖（iptables, dnsmasq等）
# - 自动配置 UID/GID 映射
# - 自动安装最新版 Go
# - 完善的错误处理和验证
#######################################

set -e

# ============= 配置变量 =============
INCUS_BUILD_DIR="/tmp/incus-build-$$"
DEPS_DIR="${HOME}/go/deps"
INSTALL_PREFIX="/usr/local"
LIB_DIR="${INSTALL_PREFIX}/lib"
BIN_DIR="${INSTALL_PREFIX}/bin"

# ============= 颜色定义 =============
if [ -t 1 ]; then
    RED=$(printf '\033[0;31m')
    GREEN=$(printf '\033[0;32m')
    YELLOW=$(printf '\033[1;33m')
    BLUE=$(printf '\033[0;34m')
    NC=$(printf '\033[0m')
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ============= 日志函数 =============
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

# ============= 检查函数 =============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        echo "请使用: sudo $0"
        exit 1
    fi
}

check_system() {
    log_step "检查系统兼容性"
    if [[ ! -f /etc/centos-release ]] && [[ ! -f /etc/redhat-release ]]; then
        log_error "此脚本仅支持 CentOS/RHEL 系统"
        exit 1
    fi
    log_success "系统检查通过"
}

check_network() {
    log_step "检查网络连接"
    if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        log_warn "网络连接可能有问题"
        read -p "是否继续？(y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    log_success "网络连接正常"
}

# ============= 安装步骤 =============

# 步骤 1: 安装基础依赖
install_base_dependencies() {
    log_step "步骤 1/10: 安装基础依赖包"
    
    log_info "更新软件包缓存..."
    dnf makecache --refresh || log_warn "缓存更新失败"
    
    log_info "安装编译工具..."
    dnf install -y git make gcc autoconf automake libtool pkg-config
    
    log_info "安装开发库..."
    dnf install -y libuv-devel sqlite-devel libacl-devel libcap-devel libudev-devel
    
    log_info "安装运行时工具..."
    dnf install -y attr patchelf wget curl
    
    log_info "尝试安装 LXC..."
    dnf install -y lxc lxc-libs lxc-devel 2>/dev/null || log_warn "LXC 开发包不可用"
    
    # 验证关键工具
    local missing=()
    for tool in git make gcc pkg-config patchelf setfattr wget; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "工具安装失败: ${missing[*]}"
        exit 1
    fi
    
    log_success "基础依赖安装完成"
}

# 步骤 2: 安装运行时依赖（Incus 运行必需）
install_runtime_dependencies() {
    log_step "步骤 2/10: 安装 Incus 运行时依赖"
    
    log_info "安装网络和防火墙工具..."
    dnf install -y \
        iptables \
        iptables-services \
        dnsmasq \
        ebtables \
        iproute \
        ipset
    
    log_info "启用 iptables 服务..."
    systemctl enable iptables 2>/dev/null || true
    
    log_success "运行时依赖安装完成"
}

# 步骤 3: 配置 UID/GID 映射
configure_uid_gid_mapping() {
    log_step "步骤 3/10: 配置 UID/GID 映射"
    
    # 确保文件存在
    touch /etc/subuid /etc/subgid
    
    # 删除旧的 root 配置
    sed -i '/^root:/d' /etc/subuid
    sed -i '/^root:/d' /etc/subgid
    
    # 添加新配置（为 root 分配 65536 个映射 ID，从 100000 开始）
    echo "root:100000:65536" >> /etc/subuid
    echo "root:100000:65536" >> /etc/subgid
    
    log_info "配置内容:"
    log_info "  /etc/subuid: $(grep root /etc/subuid)"
    log_info "  /etc/subgid: $(grep root /etc/subgid)"
    
    log_success "UID/GID 映射配置完成"
}

# 步骤 4: 安装最新版 Go
install_latest_go() {
    log_step "步骤 4/10: 安装最新版 Go"
    
    # 检测系统架构
    local arch=$(uname -m)
    case $arch in
        x86_64) GO_ARCH="amd64" ;;
        aarch64|arm64) GO_ARCH="arm64" ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac
    
    # 获取最新版本
    log_info "获取 Go 最新版本..."
    GO_VERSION=$(curl -sL https://golang.org/VERSION?m=text 2>/dev/null | head -1)
    if [ -z "$GO_VERSION" ]; then
        GO_VERSION=$(curl -sL https://go.dev/VERSION?m=text 2>/dev/null | head -1)
    fi
    [ -z "$GO_VERSION" ] && GO_VERSION="go1.23.4"
    
    GO_VERSION=${GO_VERSION#go}
    log_info "目标版本: Go $GO_VERSION"
    
    # 检查是否已安装
    if command -v go &>/dev/null; then
        local current_version=$(go version | awk '{print $3}' | sed 's/go//')
        if [[ "$current_version" == "$GO_VERSION" ]]; then
            log_success "Go $GO_VERSION 已安装"
            export GOPATH="${HOME}/go"
            mkdir -p "$GOPATH"
            return
        fi
    fi
    
    # 备份旧版本
    if [ -d "/usr/local/go" ]; then
        local backup="/usr/local/go.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "备份旧版本到: $backup"
        mv /usr/local/go "$backup"
    fi
    
    # 下载 Go
    local filename="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    log_info "下载 $filename..."
    
    # 多镜像源
    local mirrors=(
        "https://go.dev/dl"
        "https://golang.google.cn/dl"
        "https://mirrors.aliyun.com/golang"
    )
    
    local downloaded=false
    for mirror in "${mirrors[@]}"; do
        local url="${mirror}/${filename}"
        log_info "尝试: $mirror"
        
        if wget -q --show-progress --timeout=30 -O "/tmp/$filename" "$url" 2>/dev/null; then
            downloaded=true
            break
        fi
    done
    
    if [[ "$downloaded" != "true" ]]; then
        log_error "Go 下载失败"
        exit 1
    fi
    
    # 安装
    log_info "安装 Go..."
    tar -C /usr/local -xzf "/tmp/$filename"
    rm -f "/tmp/$filename"
    
    # 配置环境
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH="${HOME}/go"
    mkdir -p "$GOPATH"
    
    # 配置系统环境
    cat > /etc/profile.d/go.sh << 'EOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GOBIN=$GOPATH/bin
export PATH=$PATH:$GOROOT/bin:$GOBIN
export GOPROXY=https://goproxy.cn,direct
export GO111MODULE=on
EOF
    chmod 644 /etc/profile.d/go.sh
    
    # 验证
    if /usr/local/go/bin/go version &>/dev/null; then
        log_success "Go $(/usr/local/go/bin/go version | awk '{print $3}') 安装成功"
    else
        log_error "Go 安装验证失败"
        exit 1
    fi
}

# 步骤 5: 下载 Incus 源码
download_incus() {
    log_step "步骤 5/10: 下载 Incus 源码"
    
    [[ -d "$INCUS_BUILD_DIR" ]] && rm -rf "$INCUS_BUILD_DIR"
    mkdir -p "$INCUS_BUILD_DIR"
    cd "$INCUS_BUILD_DIR"
    
    # 克隆（带重试）
    local retry=0
    while [[ $retry -lt 3 ]]; do
        if git clone --depth 1 https://github.com/lxc/incus; then
            break
        fi
        retry=$((retry + 1))
        log_warn "克隆失败，重试 $retry/3..."
        sleep 2
        rm -rf incus
    done
    
    [[ ! -d "$INCUS_BUILD_DIR/incus" ]] && { log_error "源码下载失败"; exit 1; }
    
    cd incus
    log_success "源码下载完成"
}

# 步骤 6: 编译依赖库
build_dependencies() {
    log_step "步骤 6/10: 编译依赖库 (raft & cowsql)"
    
    cd "$INCUS_BUILD_DIR/incus"
    log_info "编译中，请等待几分钟..."
    make deps
    
    # 验证
    [[ ! -f "${DEPS_DIR}/raft/.libs/libraft.so" ]] && { log_error "raft 编译失败"; exit 1; }
    [[ ! -f "${DEPS_DIR}/cowsql/.libs/libcowsql.so" ]] && { log_error "cowsql 编译失败"; exit 1; }
    
    # 设置编译环境变量
    export CGO_CFLAGS="-I${DEPS_DIR}/raft/include/ -I${DEPS_DIR}/cowsql/include/"
    export CGO_LDFLAGS="-L${DEPS_DIR}/raft/.libs -L${DEPS_DIR}/cowsql/.libs/"
    export LD_LIBRARY_PATH="${DEPS_DIR}/raft/.libs/:${DEPS_DIR}/cowsql/.libs/"
    export CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"
    
    log_success "依赖库编译完成"
}

# 步骤 7: 配置编译环境变量
setup_build_environment() {
    log_step "步骤 7/10: 配置编译环境变量"
    
    local bashrc="${HOME}/.bashrc"
    
    if ! grep -q "# Incus build environment" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" << ENVEOF

# Incus build environment (仅用于重新编译)
export CGO_CFLAGS="-I${DEPS_DIR}/raft/include/ -I${DEPS_DIR}/cowsql/include/"
export CGO_LDFLAGS="-L${DEPS_DIR}/raft/.libs -L${DEPS_DIR}/cowsql/.libs/"
export LD_LIBRARY_PATH="${DEPS_DIR}/raft/.libs/:${DEPS_DIR}/cowsql/.libs/"
export CGO_LDFLAGS_ALLOW="(-Wl,-wrap,pthread_create)|(-Wl,-z,now)"
ENVEOF
        log_info "环境变量已添加到 $bashrc"
    fi
    
    log_success "环境变量配置完成"
}

# 步骤 8: 编译 Incus
build_incus() {
    log_step "步骤 8/10: 编译 Incus"
    
    cd "$INCUS_BUILD_DIR/incus"
    log_info "编译中，请等待几分钟..."
    
    make || { log_error "编译失败"; exit 1; }
    
    [[ ! -f "${GOPATH}/bin/incusd" ]] && { log_error "incusd 未生成"; exit 1; }
    
    log_success "Incus 编译完成"
}

# 步骤 9: 安装到系统（关键：库文件永久复制）
install_incus_to_system() {
    log_step "步骤 9/10: 安装 Incus 到系统"
    
    # 1. 安装二进制文件
    log_info "安装二进制文件到 ${BIN_DIR}..."
    cp -v "${GOPATH}"/bin/incus* "${BIN_DIR}/" 2>/dev/null || true
    cp -v "${GOPATH}"/bin/lxc-to-incus "${BIN_DIR}/" 2>/dev/null || true
    cp -v "${GOPATH}"/bin/lxd-to-incus "${BIN_DIR}/" 2>/dev/null || true
    
    [[ ! -f "${BIN_DIR}/incusd" ]] && { log_error "incusd 安装失败"; exit 1; }
    chmod +x "${BIN_DIR}"/incus*
    
    # 2. 安装库文件到系统目录（永久安装，删除编译目录也不影响）
    log_info "安装依赖库到 ${LIB_DIR}..."
    cp -v "${DEPS_DIR}"/raft/.libs/libraft.so* "${LIB_DIR}/"
    cp -v "${DEPS_DIR}"/cowsql/.libs/libcowsql.so* "${LIB_DIR}/"
    
    # 创建符号链接（如果需要）
    cd "${LIB_DIR}"
    for lib in libraft libcowsql; do
        local full=$(ls ${lib}.so.*.*.* 2>/dev/null | head -1)
        if [[ -n "$full" ]]; then
            local major=$(echo "$full" | sed 's/.*\.so\.\([0-9]*\).*/\1/')
            ln -sf "$full" "${lib}.so.${major}" 2>/dev/null || true
            ln -sf "$full" "${lib}.so" 2>/dev/null || true
        fi
    done
    
    # 3. 配置系统库搜索路径（持久化，重启后有效）
    log_info "配置系统库搜索路径..."
    echo "${LIB_DIR}" > /etc/ld.so.conf.d/incus.conf
    ldconfig
    
    # 验证库加载
    if ! ldconfig -p | grep -q libcowsql; then
        log_error "库未正确加载到系统"
        exit 1
    fi
    log_success "库已加载到系统缓存"
    
    # 4. 修复 RPATH（确保二进制文件使用系统库）
    log_info "修复二进制文件库路径..."
    patchelf --remove-rpath "${BIN_DIR}/incusd" 2>/dev/null || true
    patchelf --force-rpath --set-rpath "${LIB_DIR}" "${BIN_DIR}/incusd"
    
    # 修复 libcowsql 的 RPATH
    local cowsql_lib=$(ls "${LIB_DIR}"/libcowsql.so.* 2>/dev/null | head -1)
    if [[ -n "$cowsql_lib" ]]; then
        patchelf --remove-rpath "$cowsql_lib" 2>/dev/null || true
        patchelf --force-rpath --set-rpath "${LIB_DIR}" "$cowsql_lib"
    fi
    
    # 5. 验证库依赖
    log_info "验证库依赖..."
    if ldd "${BIN_DIR}/incusd" | grep -q "${LIB_DIR}/libcowsql"; then
        log_success "✓ incusd 正确链接到系统库"
    else
        log_warn "警告: 库链接可能有问题"
    fi
    
    # 6. 创建运行时目录
    mkdir -p /var/lib/incus /var/log/incus /etc/incus
    
    # 7. 创建组
    getent group incus-admin >/dev/null || {
        groupadd --system incus-admin
        log_info "已创建 incus-admin 组"
    }
    
    log_success "Incus 已完整安装到系统"
    log_info "提示: 现在可以安全删除编译目录 ${DEPS_DIR}"
}

# 步骤 10: 创建 systemd 服务
create_systemd_service() {
    log_step "步骤 10/10: 创建 systemd 服务"
    
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
    
    log_success "systemd 服务已创建并启用"
}

# 启动服务
start_incus_service() {
    log_step "启动 Incus 服务"
    
    systemctl start incus
    sleep 5
    
    if systemctl is-active --quiet incus; then
        log_success "Incus 服务启动成功"
    else
        log_error "服务启动失败"
        log_info "查看日志: journalctl -u incus -n 50"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    log_step "验证安装"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Incus 版本: $("${BIN_DIR}/incusd" --version)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "服务状态:"
    systemctl status incus --no-pager -l | head -15
    
    echo ""
    log_info "库依赖检查:"
    ldd "${BIN_DIR}/incusd" | grep -E "cowsql|raft" || true
    
    echo ""
    log_success "安装验证完成"
}

# 清理构建目录
cleanup_build_directory() {
    log_step "清理构建文件"
    
    echo ""
    log_info "构建目录: $INCUS_BUILD_DIR"
    log_info "依赖目录: $DEPS_DIR"
    echo ""
    
    read -p "是否删除构建目录以节省空间？删除后不影响 Incus 运行 (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "删除构建目录..."
        rm -rf "$INCUS_BUILD_DIR"
        log_success "构建目录已删除"
        
        echo ""
        read -p "是否也删除依赖源码目录？删除后需重新编译才能重新构建 Incus (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$DEPS_DIR"
            log_success "依赖目录已删除"
            log_warn "注意: 若需重新编译 Incus，需重新运行此脚本"
        else
            log_info "保留依赖目录，可用于将来重新编译"
        fi
    else
        log_info "保留所有构建文件"
    fi
}

# 显示使用说明
show_usage_guide() {
    cat << 'EOF'

╔═══════════════════════════════════════════════════════════╗
║                  🎉 Incus 安装成功！                      ║
╚═══════════════════════════════════════════════════════════╝

📦 安装信息:
  ├─ 二进制文件: /usr/local/bin/incusd
  ├─ 依赖库:     /usr/local/lib/libraft.so, libcowsql.so
  ├─ 数据目录:   /var/lib/incus
  └─ 日志目录:   /var/log/incus

✅ 重要特性:
  ├─ 库文件已永久安装到系统目录
  ├─ 编译目录可以安全删除
  ├─ 重启后自动启动
  └─ UID/GID 映射已配置

🚀 快速开始:

1. 添加用户到管理组:
   usermod -aG incus-admin $USER
   newgrp incus-admin

2. 初始化 Incus (选择默认选项):
   incus admin init

3. 创建第一个容器:
   incus launch images:ubuntu/22.04 mycontainer
   incus exec mycontainer -- bash

4. 验证运行:
   incus version
   incus list

📋 常用命令:
  ├─ systemctl status incus    # 查看服务状态
  ├─ journalctl -u incus -f     # 查看实时日志
  ├─ systemctl restart incus    # 重启服务
  ├─ incus list                 # 列出容器
  ├─ incus info <name>          # 查看容器信息
  └─ incus delete <name> --force # 删除容器

⚙️  已安装的运行时依赖:
  ├─ iptables, iptables-services
  ├─ dnsmasq
  ├─ ebtables
  └─ iproute, ipset

🔧 配置文件位置:
  ├─ 服务: /etc/systemd/system/incus.service
  ├─ 库路径: /etc/ld.so.conf.d/incus.conf
  ├─ UID/GID: /etc/subuid, /etc/subgid
  └─ Go环境: /etc/profile.d/go.sh

💡 故障排查:
  如果服务启动失败:
  1. journalctl -u incus -n 100
  2. ldd /usr/local/bin/incusd
  3. ldconfig -p | grep cowsql

  如果容器创建失败:
  1. 检查网络配置
  2. 检查 iptables 规则
  3. 查看 /var/log/incus/ 日志

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
}

# 错误清理
cleanup_on_error() {
    log_error "安装过程出错，正在清理..."
    systemctl stop incus 2>/dev/null || true
    systemctl disable incus 2>/dev/null || true
    rm -f /etc/systemd/system/incus.service
    systemctl daemon-reload
}

# ============= 主函数 =============
main() {
    clear
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════╗
║         Incus 一键安装脚本 v3.0 (最终完善版)             ║
║                  for CentOS 8                             ║
╚═══════════════════════════════════════════════════════════╝

特性:
  ✓ 库文件永久安装，编译目录可删除
  ✓ 自动安装所有运行时依赖
  ✓ 自动配置 UID/GID 映射
  ✓ 自动安装最新版 Go
  ✓ 重启后自动启动

EOF
    
    trap cleanup_on_error ERR
    
    check_root
    check_system
    check_network
    
    install_base_dependencies
    install_runtime_dependencies
    configure_uid_gid_mapping
    install_latest_go
    download_incus
    build_dependencies
    setup_build_environment
    build_incus
    install_incus_to_system
    create_systemd_service
    start_incus_service
    verify_installation
    cleanup_build_directory
    show_usage_guide
    
    echo ""
    log_success "✅ 安装完成！享受使用 Incus 吧！"
    echo ""
}

main "$@"
