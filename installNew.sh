#!/bin/bash

#====================================================
#	System Request:Debian 9+/Ubuntu 18.04+/Centos 7+
#	Author:	wulabing (Optimized by AI Assistant)
#	Dscription: V2ray ws+tls onekey Management (Smart & Safe Version)
#	Version: 2.1.0
#	email:admin@wulabing.com
#	Official document: www.v2ray.com
#====================================================


#==========================================
# 主要流程梳理
# 检查 root 权限。
# 识别系统类型（CentOS/Debian/Ubuntu），初始化包管理器。
# 安装 dbus、基础依赖、chrony、cron/crond、haveged 等。
# 系统优化：文件句柄、SELinux 关闭。
# 域名解析检查、端口占用检查。
# 安装 V2Ray 核心。
# Nginx 检查/安装。
# 生成临时 ACME 验证配置并启动 Nginx。
# 申请证书、生成最终 Nginx 配置。
# 启动 Nginx/V2Ray，设置开机自启。
# 更新证书自动续期 Cron。
#========================================================

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

cd "$(
    cd "$(dirname "$0")" || exit
    pwd
)" || exit

# 字体颜色定义
Green="\033[32m"
Red="\033[31m"
GreenBG="\033[42;37m"
RedBG="\033[41;37m"
Font="\033[0m"

# 提示信息
OK="${Green}[OK]${Font}"
Error="${Red}[错误]${Font}"
Warning="${Red}[警告]${Font}"

# 版本信息
shell_version="2.1.0"
shell_mode="None"
github_branch="master"
version_cmp="/tmp/version_cmp.tmp"

# 路径定义 (适配包管理安装的标准路径)
v2ray_conf_dir="/etc/v2ray"
nginx_conf_dir="/etc/nginx/conf.d" # 标准包管理路径
v2ray_conf="${v2ray_conf_dir}/config.json"
nginx_conf="${nginx_conf_dir}/v2ray.conf"
nginx_dir="/etc/nginx"
web_dir="/home/wwwroot"
v2ray_bin_dir_old="/usr/bin/v2ray"
v2ray_bin_dir="/usr/local/bin/v2ray"
v2ctl_bin_dir="/usr/local/bin/v2ctl"
v2ray_info_file="$HOME/v2ray_info.inf"
v2ray_qr_config_file="/usr/local/vmess_qr.json"
v2ray_access_log="/var/log/v2ray/access.log"
v2ray_error_log="/var/log/v2ray/error.log"
amce_sh_file="/root/.acme.sh/acme.sh"
ssl_update_file="/usr/bin/ssl_update.sh"

old_config_status="off"
install_marker="/tmp/v2ray_ws_tls_install_in_progress"

cleanup_partial_installation() {
    if [[ ! -f ${install_marker} ]]; then
        return 0
    fi

    echo -e "${Warning} ${RedBG} 检测到安装异常退出，正在清理残留文件... ${Font}"
    systemctl stop nginx v2ray 2>/dev/null || true
    rm -f "${nginx_conf_dir}/v2ray.conf"
    rm -f /data/v2ray.crt /data/v2ray.key
    rm -rf /home/wwwroot
    rm -f "${install_marker}"
}

error_exit() {
    echo -e "${Error} ${RedBG} $1 ${Font}"
    cleanup_partial_installation
    exit 1
}

# 移动旧版本配置信息，兼容小于 1.1.0 的版本
[[ -f "/etc/v2ray/vmess_qr.json" ]] && mv /etc/v2ray/vmess_qr.json $v2ray_qr_config_file

# 生成简易随机数用于伪装路径
random_num=$((RANDOM%12+4))
camouflage="/$(head -n 10 /dev/urandom | md5sum | head -c ${random_num})/"

THREAD=$(nproc)

source '/etc/os-release'

# 从 VERSION 中提取发行版系统的英文名称
VERSION=$(echo "${VERSION}" | awk -F "[()]" '{print $2}')

# 检查系统版本
check_system() {
    if [[ "${ID}" == "centos" && ${VERSION_ID} -ge 7 ]]; then
        echo -e "${OK} ${GreenBG} 当前系统为 Centos ${VERSION_ID} ${VERSION} ${Font}"
        INS="yum"
    elif [[ "${ID}" == "debian" && ${VERSION_ID} -ge 8 ]]; then
        echo -e "${OK} ${GreenBG} 当前系统为 Debian ${VERSION_ID} ${VERSION} ${Font}"
        INS="apt"
        $INS update
    elif [[ "${ID}" == "ubuntu" && $(echo "${VERSION_ID}" | cut -d '.' -f1) -ge 16 ]]; then
        echo -e "${OK} ${GreenBG} 当前系统为 Ubuntu ${VERSION_ID} ${UBUNTU_CODENAME} ${Font}"
        INS="apt"
        rm -f /var/lib/dpkg/lock
        dpkg --configure -a
        rm -f /var/lib/apt/lists/lock
        rm -f /var/cache/apt/archives/lock
        $INS update
    else
        echo -e "${Error} ${RedBG} 当前系统为 ${ID} ${VERSION_ID} 不在支持的系统列表内，安装中断 ${Font}"
        exit 1
    fi

    $INS install -y dbus

    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null
    echo -e "${OK} ${GreenBG} firewalld 已关闭 ${Font}"

    systemctl stop ufw 2>/dev/null
    systemctl disable ufw 2>/dev/null
    echo -e "${OK} ${GreenBG} ufw 已关闭 ${Font}"
}

# 检查 Root 权限
is_root() {
    if [ 0 == $UID ]; then
        echo -e "${OK} ${GreenBG} 当前用户是root用户，进入安装流程 ${Font}"
        sleep 1
    else
        echo -e "${Error} ${RedBG} 当前用户不是root用户，请切换到root用户后重新执行脚本 ${Font}"
        exit 1
    fi
}

# 判断命令执行结果
judge() {
    if [[ 0 -eq $? ]]; then
        echo -e "${OK} ${GreenBG} $1 完成 ${Font}"
        sleep 1
    else
        cleanup_partial_installation
        echo -e "${Error} ${RedBG} $1 失败${Font}"
        exit 1
    fi
}

# 安装时间同步服务
chrony_install() {
    ${INS} install -y chrony
    judge "安装 chrony 时间同步服务 "

    timedatectl set-ntp true

    if [[ "${ID}" == "centos" ]]; then
        systemctl enable chronyd && systemctl restart chronyd
    else
        systemctl enable chrony && systemctl restart chrony
    fi

    judge "chronyd 启动 "

    timedatectl set-timezone Asia/Shanghai

    echo -e "${OK} ${GreenBG} 等待时间同步 ${Font}"
    sleep 5
    
    date
}

# 安装基础依赖
dependency_install() {
    ${INS} install -y wget git lsof bind9-dnsutils bc unzip qrencode curl

    if [[ "${ID}" == "centos" ]]; then
        ${INS} install -y crontabs epel-release
        ${INS} install -y haveged
        systemctl start haveged && systemctl enable haveged
    else
        ${INS} install -y cron libjemalloc2
        ${INS} install -y haveged
        systemctl start haveged && systemctl enable haveged
    fi
    judge "基础依赖安装"

    # Crontab 初始化
    if [[ "${ID}" == "centos" ]]; then
        touch /var/spool/cron/root && chmod 600 /var/spool/cron/root
        systemctl start crond && systemctl enable crond
    else
        touch /var/spool/cron/crontabs/root && chmod 600 /var/spool/cron/crontabs/root
        systemctl start cron && systemctl enable cron
    fi
    judge "crontab 自启动配置 "
}

# 系统基本优化
basic_optimization() {
    # 最大文件打开数
    sed -i '/^\*\ *soft\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
    sed -i '/^\*\ *hard\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
    echo '* soft nofile 65536' >>/etc/security/limits.conf
    echo '* hard nofile 65536' >>/etc/security/limits.conf

    # 关闭 Selinux
    if [[ "${ID}" == "centos" ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        setenforce 0
    fi
}

# 设置端口和 AlterID
port_alterid_set() {
    if [[ "on" != "$old_config_status" ]]; then
        read -rp "请输入连接端口（default:443）:" port
        [[ -z ${port} ]] && port="443"
        alterID="0"
    fi
}

# 修改 V2Ray 伪装路径
modify_path() {
    if [[ "on" == "$old_config_status" ]]; then
        camouflage="$(grep '\"path\"' $v2ray_qr_config_file | awk -F '"' '{print $4}')"
    fi
    # 优先使用 jq 处理 JSON，更稳健
    if command -v jq &> /dev/null; then
        jq --arg path "$camouflage" '.inbounds[0].streamSettings.wsSettings.path = $path' $v2ray_conf > tmp.json && mv tmp.json $v2ray_conf
    else
        sed -i "/\"path\"/c \\\t  \"path\":\"${camouflage}\"" ${v2ray_conf}
    fi
    judge "V2ray 伪装路径 修改"
}

# 修改 V2Ray 入站端口
modify_inbound_port() {
    if [[ "on" == "$old_config_status" ]]; then
        port="$(info_extraction '\"port\"')"
    fi
    if [[ "$shell_mode" != "h2" ]]; then
        PORT=$((RANDOM + 10000))
        if command -v jq &> /dev/null; then
            jq --argjson port $PORT '.inbounds[0].port = $port' $v2ray_conf > tmp.json && mv tmp.json $v2ray_conf
        else
            sed -i "/\"port\"/c  \    \"port\":${PORT}," ${v2ray_conf}
        fi
    else
        if command -v jq &> /dev/null; then
             jq --argjson port $port '.inbounds[0].port = $port' $v2ray_conf > tmp.json && mv tmp.json $v2ray_conf
        else
            sed -i "/\"port\"/c  \    \"port\":${port}," ${v2ray_conf}
        fi
    fi
    judge "V2ray inbound_port 修改"
}

# 修改 UUID
modify_UUID() {
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    if [[ "on" == "$old_config_status" ]]; then
        UUID="$(info_extraction '\"id\"')"
    fi
    
    if command -v jq &> /dev/null; then
        jq --arg uuid "$UUID" '.inbounds[0].settings.clients[0].id = $uuid' $v2ray_conf > tmp.json && mv tmp.json $v2ray_conf
    else
        sed -i "/\"id\"/c \\\t  \"id\":\"${UUID}\"," ${v2ray_conf}
    fi
    
    judge "V2ray UUID 修改"
    [ -f ${v2ray_qr_config_file} ] && sed -i "/\"id\"/c \\  \"id\": \"${UUID}\"," ${v2ray_qr_config_file}
    echo -e "${OK} ${GreenBG} UUID:${UUID} ${Font}"
}

# 修改 Nginx 监听端口
modify_nginx_port() {
    if [[ "on" == "$old_config_status" ]]; then
        port="$(info_extraction '\"port\"')"
    fi
    sed -i "/listen 443/c \\\tlisten ${port} ssl http2;" ${nginx_conf}
    sed -i "/listen \[::\]:443/c \\\tlisten [::]:${port} ssl http2;" ${nginx_conf}
    judge "V2ray port 修改"
    [ -f ${v2ray_qr_config_file} ] && sed -i "/\"port\"/c \\  \"port\": \"${port}\"," ${v2ray_qr_config_file}
    echo -e "${OK} ${GreenBG} 端口号:${port} ${Font}"
}

# 修改 Nginx 其他配置（域名、路径等）
modify_nginx_other() {
    sed -i "/server_name/c \\\tserver_name ${domain};" ${nginx_conf}
    sed -i "/location \/ray/c \\\tlocation ${camouflage}" ${nginx_conf}
    sed -i "/proxy_pass/c \\\tproxy_pass http://127.0.0.1:${PORT};" ${nginx_conf}
    sed -i "/return 301/c \\\treturn 301 https://${domain}\$request_uri;" ${nginx_conf}
}

# 网站伪装（增加安全检查）
web_camouflage() {
    local web_root="/home/wwwroot"
    
    # 智能判断：如果目录存在且非空，提示用户确认
    if [[ -d "$web_root" && "$(ls -A $web_root 2>/dev/null)" ]]; then
        echo -e "${Warning} ${RedBG} 检测到 ${web_root} 目录已存在且包含文件 ${Font}"
        echo -e "${Warning} ${RedBG} 继续操作将【清空】该目录并克隆伪装站点 ${Font}"
        echo -e "${Warning} ${RedBG} 是否继续？[Y/N] (默认 N) ${Font}"
        read -r confirm_web
        case $confirm_web in
            [yY][eE][sS]|[yY])
                echo -e "${OK} ${GreenBG} 用户确认清空 ${Font}"
                ;;
            *)
                echo -e "${OK} ${GreenBG} 已取消伪装站点安装，保留原有数据 ${Font}"
                return 0
                ;;
        esac
    fi

    rm -rf "$web_root"
    mkdir -p "$web_root"
    cd "$web_root" || exit
    
    # 克隆伪装站点
    if git clone https://github.com/wulabing/3DCEList.git; then
        judge "web 站点伪装"
    else
        echo -e "${Warning} ${RedBG} 伪装站点克隆失败，使用本地占位页面 ${Font}"
        mkdir -p "$web_root/3DCEList"
        cat >"$web_root/3DCEList/index.html" <<'EOF'
<html><head><meta charset="utf-8"><title>V2Ray</title></head>
<body><h1>V2Ray WS+TLS</h1><p>伪装站点内容不可用，请稍后检查。</p></body>
</html>
EOF
        echo -e "${Warning} ${RedBG} 已创建占位页面 ${Font}"
    fi
}

# 安装 V2Ray 核心
v2ray_install() {
    if [[ -d /root/v2ray ]]; then
        rm -rf /root/v2ray
    fi
    if [[ -d /etc/v2ray ]]; then
        rm -rf /etc/v2ray
    fi
    mkdir -p /root/v2ray
    cd /root/v2ray || exit
    wget -N --no-check-certificate https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/v2ray.sh

    if [[ -f v2ray.sh ]]; then
        rm -rf /etc/systemd/system/v2ray.service
        systemctl daemon-reload
        bash v2ray.sh --force
        judge "安装 V2ray"
    else
        echo -e "${Error} ${RedBG} V2ray 安装文件下载失败，请检查下载地址是否可用 ${Font}"
        exit 4
    fi
    rm -rf /root/v2ray
}

# 智能检查 Nginx 是否存在
nginx_exist_check() {
    # 检查命令是否存在
    if command -v nginx &> /dev/null; then
        echo -e "${OK} ${GreenBG} 检测到 Nginx 已安装 ${Font}"

        if systemctl is-active --quiet nginx; then
            echo -e "${Warning} ${RedBG} Nginx 正在运行中 ${Font}"
            echo -e "${Warning} ${RedBG} 将跳过 Nginx 安装步骤，直接使用现有服务 ${Font}"
        else
            echo -e "${OK} ${GreenBG} Nginx 未运行，尝试启动... ${Font}"
            systemctl start nginx
            if [[ $? -ne 0 ]]; then
                error_exit "Nginx 启动失败，请检查 /etc/nginx/nginx.conf"
            fi
            judge "Nginx 启动"
        fi

        systemctl enable nginx 2>/dev/null || true

        nginx_conf_dir="/etc/nginx/conf.d"
        nginx_conf="${nginx_conf_dir}/v2ray.conf"
        sleep 2
    else
        nginx_install
    fi
}

# 通过包管理器安装 Nginx
nginx_install() {
    echo -e "${OK} ${GreenBG} 正在通过包管理器安装 Nginx... ${Font}"
    
    # 1. 安装 Nginx
    if [[ "${ID}" == "centos" ]]; then
        ${INS} install -y epel-release
        ${INS} install -y nginx jemalloc
    else
        ${INS} update
        ${INS} install -y nginx libjemalloc2
    fi
    
    # 验证安装
    if ! command -v nginx &> /dev/null; then
        echo -e "${Error} ${RedBG} Nginx 安装失败 ${Font}"
        exit 1
    fi

    # 2. 处理目录结构兼容性
    if [[ ! -d "/etc/nginx/conf.d" ]]; then
        mkdir -p /etc/nginx/conf.d
    fi
    
    # 更新全局变量以匹配实际路径
    nginx_conf_dir="/etc/nginx/conf.d"
    nginx_conf="${nginx_conf_dir}/v2ray.conf"
    
    # 3. (可选) Jemalloc 优化配置
    local jemalloc_lib=""
    if [[ "${ID}" == "centos" ]]; then
        jemalloc_lib="/usr/lib64/libjemalloc.so.2"
    else
        jemalloc_lib="/usr/lib/x86_64-linux-gnu/libjemalloc.so.2"
    fi

    if [[ -f "$jemalloc_lib" ]]; then
        mkdir -p /etc/systemd/system/nginx.service.d
        cat > /etc/systemd/system/nginx.service.d/jemalloc.conf <<EOF
[Service]
Environment=LD_PRELOAD=${jemalloc_lib}
EOF
        systemctl daemon-reload
        echo -e "${OK} ${GreenBG} Jemalloc 已配置 ${Font}"
    fi

    # 4. 优化主配置文件 /etc/nginx/nginx.conf
    if [[ -f "/etc/nginx/nginx.conf" ]]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        sed -i 's/worker_processes .*/worker_processes auto;/' /etc/nginx/nginx.conf
        if ! grep -q "include /etc/nginx/conf.d/\*.conf;" /etc/nginx/nginx.conf; then
            sed -i '/http {/a \    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf
        fi
    fi

    nginx -t
    judge "Nginx 配置文件语法检查"

    systemctl enable nginx
    systemctl start nginx
    judge "Nginx 启动"

    echo -e "${OK} ${GreenBG} Nginx 安装及基础配置完成 ${Font}"
}

# 安装 SSL 证书工具
ssl_install() {
    if [[ "${ID}" == "centos" ]]; then
        ${INS} install -y socat nc
	elif [[ "${ID}" == "debian" && ${VERSION_ID} -ge 12 ]]; then
		${INS} install -y socat netcat-openbsd
    else
        ${INS} install -y socat netcat
    fi
    judge "安装 SSL 证书生成脚本依赖"

    curl https://get.acme.sh | sh
    judge "安装 SSL 证书生成脚本"
}

# 域名解析检查
domain_check() {
    read -rp "请输入你的域名信息(eg:www.wulabing.com):" domain
    domain_ipv4="$(dig +short "${domain}" a)"
    domain_ipv6="$(dig +short "${domain}" aaaa)"
    echo -e "${OK} ${GreenBG} 正在获取 公网ip 信息，请耐心等待 ${Font}"
    
    # 简单的 IP 获取
    local_ipv4=$(curl -s4m8 http://ip.sb)
    local_ipv6=$(curl -s6m8 http://ip.sb)
    
    if [[ -z ${local_ipv4} && -n ${local_ipv6} ]]; then
        echo -e nameserver 2a01:4f8:c2c:123f::1 > /etc/resolv.conf
        echo -e "${OK} ${GreenBG} 识别为 IPv6 Only 的 VPS，自动添加 DNS64 服务器 ${Font}"
    fi
    
    echo -e "域名 DNS 解析到的 IP (IPv4): ${domain_ipv4}"
    echo -e "本机 IPv4: ${local_ipv4}"
    
    sleep 2
    if [[ ${domain_ipv4} == ${local_ipv4} ]]; then
        echo -e "${OK} ${GreenBG} 域名 DNS 解析 IP 与 本机 IPv4 匹配 ${Font}"
    elif [[ -n "${domain_ipv6}" && "${domain_ipv6}" == "${local_ipv6}" ]]; then
         echo -e "${OK} ${GreenBG} 域名 DNS 解析 IP 与 本机 IPv6 匹配 ${Font}"
    else
        echo -e "${Error} ${RedBG} 域名 DNS 解析 IP 与 本机 IP 不匹配 ${Font}"
        echo -e "${Error} ${RedBG} 是否继续安装？（y/n）${Font}" && read -r install
        case $install in
        [yY][eE][sS] | [yY])
            echo -e "${GreenBG} 继续安装 ${Font}"
            ;;
        *)
            echo -e "${RedBG} 安装终止 ${Font}"
            exit 2
            ;;
        esac
    fi
}

# 端口占用检查
port_exist_check() {
    if [[ 0 -eq $(lsof -i:"$1" | grep -i -c "listen") ]]; then
        echo -e "${OK} ${GreenBG} $1 端口未被占用 ${Font}"
        sleep 1
    else
        echo -e "${Error} ${RedBG} 检测到 $1 端口被占用，以下为 $1 端口占用信息 ${Font}"
        lsof -i:"$1"
        echo -e "${OK} ${GreenBG} 5s 后将尝试自动 kill 占用进程 ${Font}"
        sleep 5
        lsof -i:"$1" | awk '{print $2}' | grep -v "PID" | xargs kill -9 2>/dev/null
        echo -e "${OK} ${GreenBG} kill 完成 ${Font}"
        sleep 1
    fi
}

# Acme 申请证书
acme() {
    "$HOME"/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 创建验证目录
    mkdir -p /var/www/html/.well-known/acme-challenge
    
    # 使用 webroot 模式，指定网站根目录
    if "$HOME"/.acme.sh/acme.sh --issue -d "${domain}" --webroot /var/www/html -k ec-256 --force; then
        echo -e "${OK} ${GreenBG} SSL 证书生成成功 ${Font}"
        sleep 2
        mkdir -p /data
        if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath /data/v2ray.crt --keypath /data/v2ray.key --ecc --force; then
            echo -e "${OK} ${GreenBG} 证书配置成功 ${Font}"
            sleep 2
        fi
    else
        echo -e "${Error} ${RedBG} SSL 证书生成失败 ${Font}"
        rm -rf "$HOME/.acme.sh/${domain}_ecc"
        exit 1
    fi
}
# 添加 V2Ray TLS 配置
v2ray_conf_add_tls() {
    mkdir -p /etc/v2ray
    cd /etc/v2ray || exit
    if wget --no-check-certificate https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/tls/config.json -O config.json; then
        modify_path
        modify_inbound_port
        modify_UUID
    else
        error_exit "下载 V2Ray TLS 配置失败，请检查网络或 Github 地址"
    fi
}

# 添加 V2Ray H2 配置
v2ray_conf_add_h2() {
    mkdir -p /etc/v2ray
    cd /etc/v2ray || exit
    if wget --no-check-certificate https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/http2/config.json -O config.json; then
        modify_path
        modify_inbound_port
        modify_UUID
    else
        error_exit "下载 V2Ray H2 配置失败，请检查网络或 Github 地址"
    fi
}

# 检查是否存在旧配置
old_config_exist_check() {
    if [[ -f $v2ray_qr_config_file ]]; then
        echo -e "${OK} ${GreenBG} 检测到旧配置文件，是否读取旧文件配置 [Y/N]? ${Font}"
        read -r ssl_delete
        case $ssl_delete in
        [yY][eE][sS] | [yY])
            echo -e "${OK} ${GreenBG} 已保留旧配置  ${Font}"
            old_config_status="on"
            port=$(info_extraction '\"port\"')
            ;;
        *)
            rm -rf $v2ray_qr_config_file
            echo -e "${OK} ${GreenBG} 已删除旧配置  ${Font}"
            ;;
        esac
    fi
}

# 生成 ACME 证书验证所需的临时 Nginx 配置
nginx_conf_add_acme() {
    mkdir -p ${nginx_conf_dir}
    mkdir -p /var/www/html/.well-known/acme-challenge
    cat >${nginx_conf_dir}/v2ray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 404;
    }
}
EOF
    judge "Nginx 临时 ACME 配置生成"
}

# 生成 Nginx 配置文件
nginx_conf_add() {
    touch ${nginx_conf_dir}/v2ray.conf
    
    # 确定监听端口，默认为 443，如果用户自定义了 port 且不为 443，则使用自定义端口
    # 注意：在 install_v2ray_ws_tls 流程中，port_alterid_set 已经设置了 port 变量
    local listen_port=${port:-443}

    cat >${nginx_conf_dir}/v2ray.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    
    # Acme.sh 证书验证目录 (用于首次申请和自动续期)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # 其他 HTTP 请求重定向到 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${listen_port} ssl http2;
    listen [::]:${listen_port} ssl http2;
    ssl_certificate       /data/v2ray.crt;
    ssl_certificate_key   /data/v2ray.key;
    ssl_protocols         TLSv1.3;
    ssl_ciphers           TLS13-AES-256-GCM-SHA384:TLS13-CHACHA20-POLY1305-SHA256:TLS13-AES-128-GCM-SHA256:TLS13-AES-128-CCM-8-SHA256:TLS13-AES-128-CCM-SHA256:EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+ECDSA+AES128:EECDH+aRSA+AES128:RSA+AES128:EECDH+ECDSA+AES256:EECDH+aRSA+AES256:RSA+AES256:EECDH+ECDSA+3DES:EECDH+aRSA+3DES:RSA+3DES:!MD5;
    server_name           ${domain};
    index index.html index.htm;
    root  /home/wwwroot/3DCEList;
    error_page 400 = /400.html;

    # 启用 0-RTT
    ssl_early_data on;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=31536000";

    # Acme.sh 证书验证目录 (用于自动续期，必须存在于 HTTPS 块中以防重定向循环或验证失败)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location ${camouflage}
    {
    proxy_redirect off;
    proxy_read_timeout 1200s;
    # 直接使用变量 PORT，确保与 V2Ray 配置一致
    proxy_pass http://127.0.0.1:${PORT};
    proxy_http_version 1.1;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$http_host;
    proxy_set_header Early-Data \$ssl_early_data;
    }
}
EOF

    judge "Nginx 配置生成"
}


# 启动服务（增加配置预检）
start_process_systemd() {
    systemctl daemon-reload
    # Ensure v2ray log directory exists and log files are present
    mkdir -p /var/log/v2ray
    touch /var/log/v2ray/access.log /var/log/v2ray/error.log
    chown -R root:root /var/log/v2ray/
    
    # 确保 Nginx 用户能读取证书和网页
    chmod 755 /data
    chmod 644 /data/v2ray.crt
    chmod 600 /data/v2ray.key
    chmod -R 755 /home/wwwroot

    if [[ "$shell_mode" != "h2" ]]; then
        # 安全增强：重启前测试配置
        echo -e "${OK} ${GreenBG} 正在测试 Nginx 配置... ${Font}"
        nginx -t 2>/dev/null
        if [[ $? -ne 0 ]]; then
            echo -e "${Error} ${RedBG} Nginx 配置测试失败，请检查 ${nginx_conf} ${Font}"
            echo -e "${Error} ${RedBG} 安装中止，请手动修复配置后重启 Nginx ${Font}"
            exit 1
        fi
        systemctl restart nginx
        judge "Nginx 启动"
    fi
    systemctl restart v2ray
    judge "V2ray 启动"
}

# 设置开机自启
enable_process_systemd() {
    systemctl enable v2ray
    judge "设置 v2ray 开机自启"
    if [[ "$shell_mode" != "h2" ]]; then
        systemctl enable nginx
        judge "设置 Nginx 开机自启"
    fi
}

# 停止服务
stop_process_systemd() {
    if [[ "$shell_mode" != "h2" ]]; then
        systemctl stop nginx
    fi
    systemctl stop v2ray
}

# 更新证书 Cron 任务
acme_cron_update() {
    wget -N -P /usr/bin --no-check-certificate "https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/dev/ssl_update.sh"
    if [[ $(crontab -l 2>/dev/null | grep -c "ssl_update.sh") -lt 1 ]]; then
      if [[ "${ID}" == "centos" ]]; then
          sed -i "/acme.sh/c 0 3 * * 0 bash ${ssl_update_file}" /var/spool/cron/root
      else
          sed -i "/acme.sh/c 0 3 * * 0 bash ${ssl_update_file}" /var/spool/cron/crontabs/root
      fi
    fi
    judge "cron 计划任务更新"
}

# 生成 VMess 二维码配置 (WS+TLS)
vmess_qr_config_tls_ws() {
    cat >$v2ray_qr_config_file <<-EOF
{
  "v": "2",
  "ps": "wulabing_${domain}",
  "add": "${domain}",
  "port": "${port}",
  "id": "${UUID}",
  "aid": "${alterID}",
  "net": "ws",
  "type": "none",
  "host": "${domain}",
  "path": "${camouflage}",
  "tls": "tls"
}
EOF
}

# 生成 VMess 二维码配置 (H2)
vmess_qr_config_h2() {
    cat >$v2ray_qr_config_file <<-EOF
{
  "v": "2",
  "ps": "wulabing_${domain}",
  "add": "${domain}",
  "port": "${port}",
  "id": "${UUID}",
  "aid": "${alterID}",
  "net": "h2",
  "type": "none",
  "path": "${camouflage}",
  "tls": "tls"
}
EOF
}

# 生成二维码图片
vmess_qr_link_image() {
    vmess_link="vmess://$(base64 -w 0 $v2ray_qr_config_file)"
    {
        echo -e "$Red 二维码: $Font"
        echo -n "${vmess_link}" | qrencode -o - -t utf8
        echo -e "${Red} URL导入链接:${vmess_link} ${Font}"
    } >>"${v2ray_info_file}"
}

# 生成 Quantumult 链接
vmess_quan_link_image() {
    echo "$(info_extraction '\"ps\"') = vmess, $(info_extraction '\"add\"'), \
    $(info_extraction '\"port\"'), chacha20-ietf-poly1305, "\"$(info_extraction '\"id\"')\"", over-tls=true, \
    certificate=1, obfs=ws, obfs-path="\"$(info_extraction '\"path\"')\"", " > /tmp/vmess_quan.tmp
    vmess_link="vmess://$(base64 -w 0 /tmp/vmess_quan.tmp)"
    {
        echo -e "$Red 二维码: $Font"
        echo -n "${vmess_link}" | qrencode -o - -t utf8
        echo -e "${Red} URL导入链接:${vmess_link} ${Font}"
    } >>"${v2ray_info_file}"
}

# 选择链接类型
vmess_link_image_choice() {
        echo "请选择生成的链接种类"
        echo "1: V2RayNG/V2RayN"
        echo "2: quantumult"
        read -rp "请输入：" link_version
        [[ -z ${link_version} ]] && link_version=1
        if [[ $link_version == 1 ]]; then
            vmess_qr_link_image
        elif [[ $link_version == 2 ]]; then
            vmess_quan_link_image
        else
            vmess_qr_link_image
        fi
}

# 从配置文件中提取信息
info_extraction() {
    grep "$1" $v2ray_qr_config_file | awk -F '"' '{print $4}'
}

# 显示基本信息
basic_information() {
    {
        echo -e "${OK} ${GreenBG} V2ray+ws+tls 安装成功"
        echo -e "${Red} V2ray 配置信息 ${Font}"
        echo -e "${Red} 地址（address）:${Font} $(info_extraction '\"add\"') "
        echo -e "${Red} 端口（port）：${Font} $(info_extraction '\"port\"') "
        echo -e "${Red} 用户id（UUID）：${Font} $(info_extraction '\"id\"')"
        echo -e "${Red} 额外id（alterId）：${Font} $(info_extraction '\"aid\"')"
        echo -e "${Red} 加密方式（security）：${Font} 自适应 "
        echo -e "${Red} 传输协议（network）：${Font} $(info_extraction '\"net\"') "
        echo -e "${Red} 伪装类型（type）：${Font} none "
        echo -e "${Red} 路径（不要落下/）：${Font} $(info_extraction '\"path\"') "
        echo -e "${Red} 底层传输安全：${Font} tls "
    } >"${v2ray_info_file}"
}

show_information() {
    cat "${v2ray_info_file}"
}

# 判断并安装 SSL 证书
ssl_judge_and_install() {
    if [[ -f "/data/v2ray.key" || -f "/data/v2ray.crt" ]]; then
        echo "/data 目录下证书文件已存在"
        echo -e "${OK} ${GreenBG} 是否删除 [Y/N]? ${Font}"
        read -r ssl_delete
        case $ssl_delete in
        [yY][eE][sS] | [yY])
            rm -rf /data/v2ray.crt /data/v2ray.key
            echo -e "${OK} ${GreenBG} 已删除 ${Font}"
            ;;
        *) ;;
        esac
    fi

    if [[ -f "/data/v2ray.key" || -f "/data/v2ray.crt" ]]; then
        echo "证书文件已存在"
    elif [[ -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" ]]; then
        echo "证书文件已存在"
        "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath /data/v2ray.crt --keypath /data/v2ray.key --ecc
        judge "证书应用"
    else
        ssl_install
        acme
    fi
}

# 切换 TLS 版本
tls_type() {
    if command -v nginx &> /dev/null && [[ -f "$nginx_conf" ]] && [[ "$shell_mode" == "ws" ]]; then
        echo "请选择支持的 TLS 版本（default:3）:"
        echo "1: TLS1.1 TLS1.2 and TLS1.3（兼容模式）"
        echo "2: TLS1.2 and TLS1.3 (兼容模式)"
        echo "3: TLS1.3 only"
        read -rp "请输入：" tls_version
        [[ -z ${tls_version} ]] && tls_version=3
        if [[ $tls_version == 3 ]]; then
            sed -i 's/ssl_protocols.*/ssl_protocols         TLSv1.3;/' $nginx_conf
            echo -e "${OK} ${GreenBG} 已切换至 TLS1.3 only ${Font}"
        elif [[ $tls_version == 1 ]]; then
            sed -i 's/ssl_protocols.*/ssl_protocols         TLSv1.1 TLS1.2 TLSv1.3;/' $nginx_conf
            echo -e "${OK} ${GreenBG} 已切换至 TLS1.1 TLS1.2 and TLS1.3 ${Font}"
        else
            sed -i 's/ssl_protocols.*/ssl_protocols         TLSv1.2 TLSv1.3;/' $nginx_conf
            echo -e "${OK} ${GreenBG} 已切换至 TLS1.2 and TLS1.3 ${Font}"
        fi
        systemctl restart nginx
        judge "Nginx 重启"
    else
        echo -e "${Error} ${RedBG} Nginx 或 配置文件不存在 或当前安装版本为 h2 ，请正确安装脚本后执行${Font}"
    fi
}

show_access_log() {
    [ -f ${v2ray_access_log} ] && tail -f ${v2ray_access_log} || echo -e "${RedBG}log文件不存在${Font}"
}

show_error_log() {
    [ -f ${v2ray_error_log} ] && tail -f ${v2ray_error_log} || echo -e "${RedBG}log文件不存在${Font}"
}

# 手动更新证书
ssl_update_manuel() {
    [ -f ${amce_sh_file} ] && "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" || echo -e "${RedBG}证书签发工具不存在，请确认你是否使用了自己的证书${Font}"
    domain="$(info_extraction '\"add\"')"
    "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath /data/v2ray.crt --keypath /data/v2ray.key --ecc
}

# BBR 加速
bbr_boost_sh() {
    [ -f "tcp.sh" ] && rm -rf ./tcp.sh
    wget -N --no-check-certificate "https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
}

mtproxy_sh() {
    echo -e "${Error} ${RedBG} 功能维护，暂不可用 ${Font}"
}

# 卸载所有组件
uninstall_all() {
    stop_process_systemd
    
    echo -e "${Warning} ${RedBG} 即将卸载 V2Ray 及相关组件 ${Font}"
    echo -e "${Warning} ${RedBG} 以下文件/目录将被删除: ${Font}"
    echo -e "  - /etc/systemd/system/v2ray.service"
    echo -e "  - ${v2ray_bin_dir}"
    echo -e "  - ${v2ray_conf_dir}"
    echo -e "  - ${web_dir}"
    
    [[ -f /etc/systemd/system/v2ray.service ]] && rm -f /etc/systemd/system/v2ray.service
    [[ -f $v2ray_bin_dir ]] && rm -f $v2ray_bin_dir
    [[ -f $v2ctl_bin_dir ]] && rm -f $v2ctl_bin_dir
    [[ -d $v2ray_bin_dir_old ]] && rm -rf $v2ray_bin_dir_old
    
    # 卸载 Nginx (包管理方式)
    echo -e "${OK} ${Green} 是否卸载 Nginx [Y/N]? ${Font}"
    read -r uninstall_nginx
    case $uninstall_nginx in
    [yY][eE][sS] | [yY])
        if [[ "${ID}" == "centos" ]]; then
            yum remove -y nginx
        else
            apt remove -y nginx
            apt autoremove -y
        fi
        echo -e "${OK} ${Green} 已卸载 Nginx ${Font}"
        ;;
    *) ;;
    esac

    [[ -d $v2ray_conf_dir ]] && rm -rf $v2ray_conf_dir
    [[ -d $web_dir ]] && rm -rf $web_dir
    echo -e "${OK} ${Green} 是否卸载acme.sh及证书 [Y/N]? ${Font}"
    read -r uninstall_acme
    case $uninstall_acme in
    [yY][eE][sS] | [yY])
      /root/.acme.sh/acme.sh --uninstall
      rm -rf /root/.acme.sh
      rm -rf /data/v2ray.crt /data/v2ray.key
      ;;
    *) ;;
    esac
    systemctl daemon-reload
    echo -e "${OK} ${GreenBG} 已卸载 ${Font}"
}

delete_tls_key_and_crt() {
    [[ -f $HOME/.acme.sh/acme.sh ]] && /root/.acme.sh/acme.sh uninstall >/dev/null 2>&1
    [[ -d $HOME/.acme.sh ]] && rm -rf "$HOME/.acme.sh"
    echo -e "${OK} ${GreenBG} 已清空证书遗留文件 ${Font}"
}

# 判断当前安装模式
judge_mode() {
    if [ -f $v2ray_bin_dir ] || [ -f $v2ray_bin_dir_old/v2ray ]; then
        if grep -q "ws" $v2ray_qr_config_file; then
            shell_mode="ws"
        elif grep -q "h2" $v2ray_qr_config_file; then
            shell_mode="h2"
        fi
    fi
}

# 安装 WS+TLS 模式
install_v2ray_ws_tls() {
    is_root
    touch "${install_marker}"
    check_system
    chrony_install
    dependency_install
    basic_optimization
    domain_check
    old_config_exist_check
    port_alterid_set
    v2ray_install
    port_exist_check 80
    port_exist_check "${port}"
    nginx_exist_check
    v2ray_conf_add_tls
    nginx_conf_add_acme
    nginx -t >/dev/null 2>&1
    judge "Nginx ACME 配置检查"
    systemctl restart nginx
    judge "Nginx 重启"
    web_camouflage
    ssl_judge_and_install
    nginx_conf_add
    vmess_qr_config_tls_ws
    basic_information
    vmess_link_image_choice
    tls_type
    show_information
    start_process_systemd
    enable_process_systemd
    acme_cron_update
    rm -f "${install_marker}"
}

# 安装 H2 模式
install_v2_h2() {
    is_root
    touch "${install_marker}"
    check_system
    chrony_install
    dependency_install
    basic_optimization
    domain_check
    old_config_exist_check
    port_alterid_set
    v2ray_install
    port_exist_check 80
    port_exist_check "${port}"
    v2ray_conf_add_h2
    ssl_judge_and_install
    vmess_qr_config_h2
    basic_information
    vmess_qr_link_image
    show_information
    start_process_systemd
    enable_process_systemd
    rm -f "${install_marker}"
}

# 脚本自我更新
update_sh() {
    ol_version=$(curl -L -s https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/install.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
    echo "$ol_version" >$version_cmp
    echo "$shell_version" >>$version_cmp
    if [[ "$shell_version" < "$(sort -rV $version_cmp | head -1)" ]]; then
        echo -e "${OK} ${GreenBG} 存在新版本，是否更新 [Y/N]? ${Font}"
        read -r update_confirm
        case $update_confirm in
        [yY][eE][sS] | [yY])
            wget -N --no-check-certificate https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/install.sh
            echo -e "${OK} ${GreenBG} 更新完成 ${Font}"
            exit 0
            ;;
        *) ;;
        esac
    else
        echo -e "${OK} ${GreenBG} 当前版本为最新版本 ${Font}"
    fi
}

maintain() {
    echo -e "${RedBG}该选项暂时无法使用${Font}"
    echo -e "${RedBG}$1${Font}"
    exit 0
}

list() {
    case $1 in
    tls_modify)
        tls_type
        ;;
    uninstall)
        uninstall_all
        ;;
    crontab_modify)
        acme_cron_update
        ;;
    boost)
        bbr_boost_sh
        ;;
    *)
        menu
        ;;
    esac
}

# 修改伪装路径
modify_camouflage_path() {
    [[ -z ${camouflage_path} ]] && camouflage_path=1
    sed -i "/location \/ray/c \\\tlocation \/${camouflage_path}\/" ${nginx_conf}
    sed -i "/\"path\"/c \\\t  \"path\":\"\/${camouflage_path}\/\"" ${v2ray_conf}
    judge "V2ray camouflage path modified"
}

# 主菜单
menu() {
    update_sh
    echo -e "\t V2ray 安装管理脚本 ${Red}[${shell_version}]${Font}"
    echo -e "\t---authored by wulabing---"
    echo -e "\thttps://github.com/wulabing\n"
    echo -e "当前已安装版本:${shell_mode}\n"

    echo -e "—————————————— 安装向导 ——————————————"""
    echo -e "${Green}0.${Font}  升级 脚本"
    echo -e "${Green}1.${Font}  安装 V2Ray (Nginx+ws+tls)"
    echo -e "${Green}2.${Font}  安装 V2Ray (http/2)"
    echo -e "${Green}3.${Font}  升级 V2Ray core"
    echo -e "—————————————— 配置变更 ——————————————"
    echo -e "${Green}4.${Font}  变更 UUID"
    echo -e "${Green}6.${Font}  变更 port"
    echo -e "${Green}7.${Font}  变更 TLS 版本(仅ws+tls有效)"
    echo -e "${Green}18.${Font}  变更伪装路径"
    echo -e "—————————————— 查看信息 ——————————————"
    echo -e "${Green}8.${Font}  查看 实时访问日志"
    echo -e "${Green}9.${Font}  查看 实时错误日志"
    echo -e "${Green}10.${Font} 查看 V2Ray 配置信息"
    echo -e "—————————————— 其他选项 ——————————————"
    echo -e "${Green}11.${Font} 安装 4合1 bbr 锐速安装脚本"
    echo -e "${Green}12.${Font} 安装 MTproxy(支持TLS混淆)"
    echo -e "${Green}13.${Font} 证书 有效期更新"
    echo -e "${Green}14.${Font} 卸载 V2Ray"
    echo -e "${Green}15.${Font} 更新 证书crontab计划任务"
    echo -e "${Green}16.${Font} 清空 证书遗留文件"
    echo -e "${Green}17.${Font} 退出 \n"

    read -rp "请输入数字：" menu_num
    case $menu_num in
    0)
        update_sh
        ;;
    1)
        shell_mode="ws"
        install_v2ray_ws_tls
        ;;
    2)
        shell_mode="h2"
        install_v2_h2
        ;;
    3)
        bash <(curl -L -s https://raw.githubusercontent.com/bighead001/V2Ray_ws-tls_bash_onekey/${github_branch}/v2ray.sh)
        ;;
    4)
        read -rp "请输入UUID:" UUID
        modify_UUID
        start_process_systemd
        ;;
    6)
        read -rp "请输入连接端口:" port
        if grep -q "ws" $v2ray_qr_config_file; then
            modify_nginx_port
        elif grep -q "h2" $v2ray_qr_config_file; then
            modify_inbound_port
        fi
        start_process_systemd
        ;;
    7)
        tls_type
        ;;
    8)
        show_access_log
        ;;
    9)
        show_error_log
        ;;
    10)
        basic_information
        if [[ $shell_mode == "ws" ]]; then
            vmess_link_image_choice
        else
            vmess_qr_link_image
        fi
        show_information
        ;;
    11)
        bbr_boost_sh
        ;;
    12)
        mtproxy_sh
        ;;
    13)
        stop_process_systemd
        ssl_update_manuel
        start_process_systemd
        ;;
    14)
        source '/etc/os-release'
        uninstall_all
        ;;
    15)
        acme_cron_update
        ;;
    16)
        delete_tls_key_and_crt
        ;;
    17)
        exit 0
        ;;
    18)
        read -rp "请输入伪装路径(注意！不需要加斜杠 eg:ray):" camouflage_path
        modify_camouflage_path
        start_process_systemd
        ;;
    *)
        echo -e "${RedBG}请输入正确的数字${Font}"
        ;;
    esac
}

judge_mode
list "$1"