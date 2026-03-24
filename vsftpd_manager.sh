#!/bin/sh

set -u

STATE_FILE=""
VSFTPD_CONF=""
BACKUP_CONF=""
PAM_VSFTPD_CONF="/etc/pam.d/vsftpd"
PAM_VSFTPD_BACKUP="/etc/pam.d/vsftpd.bak_codex"

print_line() {
    printf '%s\n' "--------------------------------------------------"
}

info() {
    printf '%s\n' "[INFO] $1"
}

warn() {
    printf '%s\n' "[WARN] $1"
}

error() {
    printf '%s\n' "[ERROR] $1" >&2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

resolve_paths() {
    if [ -f "/etc/vsftpd.conf" ]; then
        VSFTPD_CONF="/etc/vsftpd.conf"
        BACKUP_CONF="/etc/vsftpd.conf.bak_codex"
        STATE_FILE="/etc/codex_ftp_manager.conf"
        return
    fi

    if [ -f "/etc/vsftpd/vsftpd.conf" ] || [ -d "/etc/vsftpd" ]; then
        VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
        BACKUP_CONF="/etc/vsftpd/vsftpd.conf.bak_codex"
        STATE_FILE="/etc/vsftpd/codex_ftp_manager.conf"
        return
    fi

    VSFTPD_CONF="/etc/vsftpd.conf"
    BACKUP_CONF="/etc/vsftpd.conf.bak_codex"
    STATE_FILE="/etc/codex_ftp_manager.conf"
}

ensure_parent_dir() {
    target_file="$1"
    target_dir=$(dirname "$target_file")
    [ -d "$target_dir" ] || mkdir -p "$target_dir"
}

is_path_under_root() {
    case "$1" in
        /root|/root/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

path_is_traversable() {
    target_path="$1"
    while [ "$target_path" != "/" ] && [ -n "$target_path" ]; do
        if [ ! -x "$target_path" ]; then
            return 1
        fi
        target_path=$(dirname "$target_path")
    done
    return 0
}

normalize_ftp_dir() {
    if is_path_under_root "$FTP_DIR"; then
        warn "检测到 FTP 目录位于 /root 下，普通 FTP 用户无法进入。"
        FTP_DIR="/srv/${FTP_USER}"
        info "已自动切换 FTP 目录为: $FTP_DIR"
        return 0
    fi

    if ! path_is_traversable "$FTP_DIR"; then
        warn "检测到 FTP 目录的父级目录缺少执行权限，FTP 用户无法进入。"
        FTP_DIR="/srv/${FTP_USER}"
        info "已自动切换 FTP 目录为: $FTP_DIR"
    fi
}

detect_pkg_manager() {
    if command_exists apt-get; then
        echo "apt"
        return
    fi
    if command_exists dnf; then
        echo "dnf"
        return
    fi
    if command_exists yum; then
        echo "yum"
        return
    fi
    echo ""
}

install_vsftpd_package() {
    pkg_manager=$(detect_pkg_manager)

    case "$pkg_manager" in
        apt)
            info "检测到 apt，开始安装 vsftpd。"
            apt-get update && apt-get install -y vsftpd
            ;;
        dnf)
            info "检测到 dnf，开始安装 vsftpd。"
            dnf install -y vsftpd
            ;;
        yum)
            info "检测到 yum，开始安装 vsftpd。"
            yum install -y vsftpd
            ;;
        *)
            error "未识别到支持的包管理器（apt/dnf/yum）。"
            return 1
            ;;
    esac
}

remove_vsftpd_package() {
    pkg_manager=$(detect_pkg_manager)

    case "$pkg_manager" in
        apt)
            apt-get remove -y vsftpd
            ;;
        dnf)
            dnf remove -y vsftpd
            ;;
        yum)
            yum remove -y vsftpd
            ;;
        *)
            error "未识别到支持的包管理器（apt/dnf/yum）。"
            return 1
            ;;
    esac
}

service_action() {
    action="$1"
    if command_exists systemctl; then
        systemctl "$action" vsftpd
    else
        service vsftpd "$action"
    fi
}

enable_vsftpd() {
    if command_exists systemctl; then
        systemctl enable vsftpd >/dev/null 2>&1
    fi
}

get_login_shell() {
    if [ -x "/bin/bash" ]; then
        printf '%s\n' "/bin/bash"
        return
    fi
    if [ -x "/bin/sh" ]; then
        printf '%s\n' "/bin/sh"
        return
    fi
    if [ -x "/bin/false" ]; then
        printf '%s\n' "/bin/false"
        return
    fi
    printf '%s\n' "/bin/sh"
}

ensure_shell_allowed() {
    shell_path="$1"
    [ -f "/etc/shells" ] || touch /etc/shells
    if ! grep -Fx "$shell_path" /etc/shells >/dev/null 2>&1; then
        printf '%s\n' "$shell_path" >> /etc/shells
    fi
}

open_firewall_ports() {
    info "尝试自动放行 FTP 端口和被动端口范围。"

    if command_exists ufw; then
        ufw allow "$FTP_PORT"/tcp >/dev/null 2>&1 || true
        ufw allow 20/tcp >/dev/null 2>&1 || true
        ufw allow 40000:40100/tcp >/dev/null 2>&1 || true
    fi

    if command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port="${FTP_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=20/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=40000-40100/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if command_exists iptables; then
        iptables -C INPUT -p tcp --dport "$FTP_PORT" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport "$FTP_PORT" -j ACCEPT >/dev/null 2>&1 || true
        iptables -C INPUT -p tcp --dport 20 -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport 20 -j ACCEPT >/dev/null 2>&1 || true
        iptables -C INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --match multiport --dports 40000:40100 -j ACCEPT >/dev/null 2>&1 || true
    fi
}

remove_user_from_deny_lists() {
    for deny_file in /etc/ftpusers /etc/vsftpd.user_list /etc/vsftpd/ftpusers /etc/vsftpd/user_list; do
        if [ -f "$deny_file" ]; then
            tmp_file="${deny_file}.codex_tmp"
            grep -vxF "$FTP_USER" "$deny_file" >"$tmp_file" 2>/dev/null || true
            cat "$tmp_file" >"$deny_file"
            rm -f "$tmp_file"
        fi
    done
}

install_selfcheck_tools() {
    if command_exists curl; then
        return 0
    fi

    pkg_manager=$(detect_pkg_manager)
    case "$pkg_manager" in
        apt)
            apt-get install -y curl >/dev/null 2>&1 || true
            ;;
        dnf)
            dnf install -y curl >/dev/null 2>&1 || true
            ;;
        yum)
            yum install -y curl >/dev/null 2>&1 || true
            ;;
    esac
}

backup_pam_vsftpd() {
    if [ -f "$PAM_VSFTPD_CONF" ] && [ ! -f "$PAM_VSFTPD_BACKUP" ]; then
        cp "$PAM_VSFTPD_CONF" "$PAM_VSFTPD_BACKUP"
    fi
}

write_pam_vsftpd_conf() {
    ensure_parent_dir "$PAM_VSFTPD_CONF"
    backup_pam_vsftpd
    cat >"$PAM_VSFTPD_CONF" <<'EOF'
auth    required pam_unix.so
account required pam_unix.so
session required pam_loginuid.so
session required pam_unix.so
EOF
}

show_auth_diagnostics() {
    if id "$FTP_USER" >/dev/null 2>&1; then
        if command_exists passwd; then
            passwd -S "$FTP_USER" 2>/dev/null || true
        fi
        if command_exists chage; then
            chage -l "$FTP_USER" 2>/dev/null || true
        fi
        getent passwd "$FTP_USER" 2>/dev/null || true
    fi

    if [ -f "/var/log/auth.log" ]; then
        tail -n 20 /var/log/auth.log 2>/dev/null || true
    fi

    if command_exists journalctl; then
        journalctl -u vsftpd -n 20 --no-pager 2>/dev/null || true
    fi
}

ftp_self_check() {
    if ! read_state; then
        error "未检测到安装信息，请先安装 FTP 服务端。"
        return 1
    fi

    print_line
    printf "开始本机自检: 127.0.0.1:%s\n" "$FTP_PORT"

    if ! service_action status >/dev/null 2>&1; then
        warn "vsftpd 服务当前未处于正常运行状态。"
    fi

    if command_exists ss; then
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]${FTP_PORT}\$" >/dev/null 2>&1; then
            info "监听端口检测通过。"
        else
            error "未检测到 FTP 端口监听。"
        fi
    fi

    install_selfcheck_tools
    if command_exists curl; then
        curl_output_file="/tmp/codex_ftp_selfcheck.log"
        if curl --verbose --disable-epsv --user "$FTP_USER:$FTP_PASS" "ftp://127.0.0.1:$FTP_PORT/" >"$curl_output_file" 2>&1; then
            info "FTP 用户名密码自检通过。"
            rm -f "$curl_output_file"
            print_line
            return 0
        fi
        error "FTP 用户名密码自检失败。"
        if [ -f "$curl_output_file" ]; then
            tail -n 30 "$curl_output_file" 2>/dev/null || true
            rm -f "$curl_output_file"
        fi
        warn "建议检查 /var/log/auth.log、journalctl -u vsftpd 和云安全组。"
        show_auth_diagnostics
    else
        warn "系统没有 curl，跳过 FTP 登录自检。"
    fi

    print_line
    return 1
}

random_username() {
    suffix=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
    printf 'ftp%s\n' "$suffix"
}

random_password() {
    tr -dc 'A-Za-z0-9@#%+=' </dev/urandom | head -c 12
    printf '\n'
}

random_port() {
    shuf -i 20000-50000 -n 1 2>/dev/null && return
    awk 'BEGIN{srand(); print int(20000+rand()*30000)}'
}

read_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        return 0
    fi
    return 1
}

escape_squote() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

write_state_safe() {
    ensure_parent_dir "$STATE_FILE"
    umask 077
    safe_user=$(escape_squote "$FTP_USER")
    safe_pass=$(escape_squote "$FTP_PASS")
    safe_port=$(escape_squote "$FTP_PORT")
    safe_dir=$(escape_squote "$FTP_DIR")
    cat >"$STATE_FILE" <<EOF
FTP_USER='$safe_user'
FTP_PASS='$safe_pass'
FTP_PORT='$safe_port'
FTP_DIR='$safe_dir'
EOF
}

prompt_directory() {
    while :; do
        printf "请输入 FTP 目录（可填写现有目录，或输入新目录路径）: "
        read -r target_dir

        if [ -z "$target_dir" ]; then
            warn "目录不能为空。"
            continue
        fi

        if [ -d "$target_dir" ]; then
            FTP_DIR="$target_dir"
            return 0
        fi

        printf "目录不存在，是否创建 [%s] ? (y/n): " "$target_dir"
        read -r create_answer
        case "$create_answer" in
            y|Y)
                mkdir -p "$target_dir" || return 1
                FTP_DIR="$target_dir"
                return 0
                ;;
            *)
                warn "请重新输入目录。"
                ;;
        esac
    done
}

prompt_port() {
    while :; do
        printf "1. 自定义端口\n"
        printf "2. 随机端口\n"
        printf "请选择端口设置方式 [1-2]: "
        read -r port_choice
        case "$port_choice" in
            1)
                printf "请输入端口号（1-65535）: "
                read -r input_port
                case "$input_port" in
                    ''|*[!0-9]*)
                        warn "端口必须是数字。"
                        ;;
                    *)
                        if [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
                            FTP_PORT="$input_port"
                            return 0
                        fi
                        warn "端口范围无效。"
                        ;;
                esac
                ;;
            2)
                FTP_PORT=$(random_port)
                info "已生成随机端口: $FTP_PORT"
                return 0
                ;;
            *)
                warn "请输入 1 或 2。"
                ;;
        esac
    done
}

prompt_user_pass() {
    while :; do
        printf "1. 自定义用户名和密码\n"
        printf "2. 随机生成用户名和密码\n"
        printf "请选择账号设置方式 [1-2]: "
        read -r user_choice
        case "$user_choice" in
            1)
                printf "请输入 FTP 用户名: "
                read -r FTP_USER
                if [ -z "$FTP_USER" ]; then
                    warn "用户名不能为空。"
                    continue
                fi
                printf "请输入 FTP 密码: "
                read -r FTP_PASS
                if [ -z "$FTP_PASS" ]; then
                    warn "密码不能为空。"
                    continue
                fi
                return 0
                ;;
            2)
                FTP_USER=$(random_username)
                FTP_PASS=$(random_password | tr -d '\n')
                info "已生成用户名: $FTP_USER"
                info "已生成密码: $FTP_PASS"
                return 0
                ;;
            *)
                warn "请输入 1 或 2。"
                ;;
        esac
    done
}

ensure_user() {
    shell_path=$(get_login_shell)
    ensure_shell_allowed "$shell_path"
    normalize_ftp_dir

    if id "$FTP_USER" >/dev/null 2>&1; then
        info "用户 $FTP_USER 已存在，将更新密码和目录。"
        usermod -d "$FTP_DIR" -s "$shell_path" "$FTP_USER" 2>/dev/null || true
    else
        useradd -d "$FTP_DIR" -s "$shell_path" "$FTP_USER"
    fi

    printf '%s:%s\n' "$FTP_USER" "$FTP_PASS" | chpasswd
    if command_exists usermod; then
        usermod -U "$FTP_USER" >/dev/null 2>&1 || true
        usermod -e "" "$FTP_USER" >/dev/null 2>&1 || true
    fi
    if command_exists passwd; then
        passwd -u "$FTP_USER" >/dev/null 2>&1 || true
    fi
    if command_exists chage; then
        chage -I -1 -m 0 -M 99999 -E -1 "$FTP_USER" >/dev/null 2>&1 || true
    fi
    remove_user_from_deny_lists
    mkdir -p "$FTP_DIR"
    user_group=$(id -gn "$FTP_USER" 2>/dev/null || printf '%s' "$FTP_USER")
    chown "$FTP_USER:$user_group" "$FTP_DIR"
    chmod 755 "$FTP_DIR"
}

backup_vsftpd_conf() {
    ensure_parent_dir "$VSFTPD_CONF"
    if [ -f "$VSFTPD_CONF" ] && [ ! -f "$BACKUP_CONF" ]; then
        cp "$VSFTPD_CONF" "$BACKUP_CONF"
    fi
}

write_vsftpd_conf() {
    backup_vsftpd_conf
    cat >"$VSFTPD_CONF" <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
guest_enable=NO
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
xferlog_std_format=YES
userlist_enable=NO
tcp_wrappers=NO
user_sub_token=\$USER
local_root=$FTP_DIR
listen_port=$FTP_PORT
port_enable=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
utf8_filesystem=YES
EOF
}

get_primary_ipv4() {
    if command_exists ip; then
        ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | paste -sd ',' -
        return
    fi
    hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /:/) print $i}' | paste -sd ',' -
}

get_primary_ipv6() {
    if command_exists ip; then
        ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | paste -sd ',' -
        return
    fi
    hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /:/) print $i}' | paste -sd ',' -
}

show_status() {
    print_line
    if read_state; then
        ipv4=$(get_primary_ipv4)
        ipv6=$(get_primary_ipv6)
        [ -n "$ipv4" ] || ipv4="未获取到"
        [ -n "$ipv6" ] || ipv6="未获取到"
        printf "FTP 目录: %s\n" "$FTP_DIR"
        printf "IPv4 地址: %s\n" "$ipv4"
        printf "IPv6 地址: %s\n" "$ipv6"
        printf "端口: %s\n" "$FTP_PORT"
        printf "用户名: %s\n" "$FTP_USER"
        printf "密码: %s\n" "$FTP_PASS"
        if is_path_under_root "$FTP_DIR"; then
            printf "目录状态: 当前目录位于 /root 下，不适合 FTP 登录，请重新安装或修改为 /srv/目录\n"
        fi
    else
        printf "当前未检测到已安装的 FTP 配置。\n"
    fi
    print_line
}

show_dashboard() {
    if read_state; then
        printf "当前 FTP 配置信息:\n"
        show_status
    else
        printf "当前尚未安装 FTP 服务端。\n"
        print_line
    fi
}

install_ftp() {
    prompt_directory || {
        error "目录处理失败。"
        return 1
    }

    prompt_port
    prompt_user_pass

    install_vsftpd_package || {
        error "vsftpd 安装失败。"
        return 1
    }

    ensure_user || {
        error "FTP 用户创建或更新失败。"
        return 1
    }

    write_vsftpd_conf || {
        error "vsftpd 配置文件写入失败。"
        return 1
    }
    write_pam_vsftpd_conf || {
        error "vsftpd PAM 配置写入失败。"
        return 1
    }

    write_state_safe || {
        error "状态文件写入失败。"
        return 1
    }

    open_firewall_ports
    enable_vsftpd
    service_action restart || service_action start || {
        error "vsftpd 服务启动失败，请检查系统日志。"
        return 1
    }

    info "FTP 服务端安装并配置完成。"
    show_status
    ftp_self_check || true
}

uninstall_ftp() {
    if read_state; then
        old_user="$FTP_USER"
    else
        old_user=""
    fi

    service_action stop >/dev/null 2>&1 || true
    remove_vsftpd_package || return 1

    if [ -n "$old_user" ] && id "$old_user" >/dev/null 2>&1; then
        printf "是否删除 FTP 系统用户 [%s] ? (y/n): " "$old_user"
        read -r delete_user
        case "$delete_user" in
            y|Y)
                userdel "$old_user" >/dev/null 2>&1 || true
                ;;
        esac
    fi

    rm -f "$STATE_FILE"
    info "vsftpd 已卸载。"
}

change_credentials() {
    if ! read_state; then
        error "未检测到安装信息，请先安装 FTP 服务端。"
        return 1
    fi

    old_user="$FTP_USER"
    old_dir="$FTP_DIR"
    old_port="$FTP_PORT"

    prompt_user_pass

    if [ "$FTP_USER" != "$old_user" ]; then
        if id "$FTP_USER" >/dev/null 2>&1; then
            error "目标用户名 [$FTP_USER] 已存在，请换一个用户名。"
            return 1
        fi

        if id "$old_user" >/dev/null 2>&1; then
            old_group=$(id -gn "$old_user" 2>/dev/null || printf '%s' "$old_user")
            usermod -l "$FTP_USER" "$old_user" || {
                error "用户名修改失败。"
                return 1
            }
            if getent group "$old_group" >/dev/null 2>&1; then
                groupmod -n "$FTP_USER" "$old_group" >/dev/null 2>&1 || true
            fi
            current_home=$(getent passwd "$FTP_USER" 2>/dev/null | cut -d: -f6)
            if [ "$current_home" = "$old_dir" ] || [ -z "$current_home" ]; then
                usermod -d "$old_dir" "$FTP_USER" 2>/dev/null || true
            fi
            user_group=$(id -gn "$FTP_USER" 2>/dev/null || printf '%s' "$FTP_USER")
            chown "$FTP_USER:$user_group" "$old_dir" >/dev/null 2>&1 || true
        else
            FTP_DIR="$old_dir"
            FTP_PORT="$old_port"
            ensure_user
        fi
    fi

    if ! id "$FTP_USER" >/dev/null 2>&1; then
        FTP_DIR="$old_dir"
        FTP_PORT="$old_port"
        ensure_user || return 1
    else
        printf '%s:%s\n' "$FTP_USER" "$FTP_PASS" | chpasswd
        FTP_DIR="$old_dir"
        FTP_PORT="$old_port"
    fi

    write_state_safe
    info "用户名和密码修改完成。"
    show_status
    ftp_self_check || true
}

change_port() {
    if ! read_state; then
        error "未检测到安装信息，请先安装 FTP 服务端。"
        return 1
    fi

    old_user="$FTP_USER"
    old_pass="$FTP_PASS"
    old_dir="$FTP_DIR"

    prompt_port
    write_vsftpd_conf || {
        error "vsftpd 配置文件写入失败。"
        return 1
    }
    write_pam_vsftpd_conf || {
        error "vsftpd PAM 配置写入失败。"
        return 1
    }
    FTP_USER="$old_user"
    FTP_PASS="$old_pass"
    FTP_DIR="$old_dir"
    write_state_safe || {
        error "状态文件写入失败。"
        return 1
    }
    open_firewall_ports
    service_action restart || service_action start || {
        error "vsftpd 服务重启失败，请检查系统日志。"
        return 1
    }

    info "端口修改完成。"
    show_status
    ftp_self_check || true
}

show_menu() {
    print_line
    printf "vsftpd FTP 管理脚本\n"
    print_line
    printf "1. 安装 FTP 服务端\n"
    printf "2. 卸载 FTP 服务端\n"
    printf "3. 修改用户名密码\n"
    printf "4. 修改端口\n"
    printf "5. FTP 本机自检\n"
    printf "0. 退出\n"
    print_line
    printf "请输入序号: "
}

main() {
    require_root
    resolve_paths
    show_dashboard

    while :; do
        show_menu
        read -r choice
        case "$choice" in
            1)
                install_ftp
                ;;
            2)
                uninstall_ftp
                ;;
            3)
                change_credentials
                ;;
            4)
                change_port
                ;;
            5)
                ftp_self_check
                ;;
            0)
                exit 0
                ;;
            *)
                warn "无效选项，请重新输入。"
                ;;
        esac
    done
}

main "$@"
