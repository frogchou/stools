#!/bin/bash

# linux_user_manager.sh - 功能全面的Linux用户/组/权限交互式管理工具
# 兼容 Ubuntu, Debian, CentOS, RHEL, Fedora, Kylin 等主流发行版
# 作者: zsw

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志文件
LOG_FILE="/var/log/linux_user_manager.log"

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本必须以 root 权限运行。请使用 sudo。${NC}" 1>&2
        exit 1
    fi
}

# 日志记录函数
log_action() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# 自动检测发行版并安装依赖 (修复了退出状态检查)
install_dependencies() {
    log_action "INFO: 开始检查并安装必要依赖..."
    local install_success=false
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu 系列
        apt-get update && apt-get install -y whois acl expect
        if [[ $? -eq 0 ]]; then
            install_success=true
        else
            log_action "ERROR: 使用 apt-get 安装依赖失败"
        fi
    elif command -v yum &> /dev/null; then
        # RHEL/CentOS 7 系列
        yum install -y epel-release
        yum install -y expect whois acl
        if [[ $? -eq 0 ]]; then
             install_success=true
        else
            log_action "ERROR: 使用 yum 安装依赖失败"
        fi
    elif command -v dnf &> /dev/null; then
        # Fedora/RHEL/CentOS 8+ 系列
        dnf install -y expect whois acl
        if [[ $? -eq 0 ]]; then
            install_success=true
        else
            log_action "ERROR: 使用 dnf 安装依赖失败"
        fi
    else
        log_action "WARN: 无法识别的包管理器，跳过依赖安装。请确保 whois, expect, acl 已安装。"
        # 如果无法识别包管理器，我们假设用户已手动安装或不需要
        install_success=true
    fi

    if [[ "$install_success" = true ]]; then
        log_action "INFO: 依赖检查与安装完成。"
        echo -e "${GREEN}依赖检查与安装完成。${NC}"
    else
        echo -e "${RED}依赖安装过程中出现错误，请检查日志 $LOG_FILE。${NC}"
    fi
    read -p "按回车键继续..."
}

# 主菜单
show_menu() {
    clear
    echo "=========================================="
    echo "   Linux 用户/组/权限 交互式管理工具     "
    echo "=========================================="
    echo "1. 用户管理"
    echo "2. 组管理"
    echo "3. 权限控制"
    echo "4. 审计与日志"
    echo "5. 安全策略"
    echo "6. 依赖检查与安装"
    echo "0. 退出"
    echo "=========================================="
}

# 用户管理子菜单
user_management_menu() {
    while true; do
        clear
        echo "---------------------------"
        echo "       用户管理菜单        "
        echo "---------------------------"
        echo "1. 创建用户"
        echo "2. 删除用户"
        echo "3. 修改用户信息"
        echo "4. 列出所有用户"
        echo "5. 锁定/解锁用户"
        echo "0. 返回主菜单"
        echo "---------------------------"
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) modify_user ;;
            4) list_users ;;
            5) lock_unlock_user ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${NC}"; sleep 2 ;;
        esac
    done
}

# 创建用户
create_user() {
    read -p "请输入要创建的用户名: " username
    # 基本用户名有效性检查
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。用户名应以字母开头，可包含字母、数字、点(.)、下划线(_)和连字符(-)。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if id "$username" &>/dev/null; then
        echo -e "${YELLOW}警告: 用户 '$username' 已存在。${NC}"
        read -p "是否要重置该用户的密码? (y/N): " reset_pass
        if [[ $reset_pass =~ ^[Yy]$ ]]; then
            passwd "$username"
            log_action "INFO: 重置了用户 $username 的密码。"
        fi
        read -p "按回车键继续..."
        return
    fi

    # 询问详细信息
    read -p "请输入用户全名 (可选): " fullname
    read -p "是否创建同名用户组? (Y/n): " create_group
    local group_option=""
    if [[ ! $create_group =~ ^[Nn]$ ]]; then
        group_option="-U" # 在支持的系统上创建用户私有组
    fi

    # 创建用户
    useradd $group_option -c "$fullname" "$username"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}用户 '$username' 创建成功。${NC}"
        log_action "INFO: 创建用户 $username ($fullname)。"
        read -p "是否立即设置密码? (Y/n): " set_pass
        if [[ ! $set_pass =~ ^[Nn]$ ]]; then
            passwd "$username"
            log_action "INFO: 为用户 $username 设置密码。"
        fi
    else
        echo -e "${RED}创建用户 '$username' 失败。${NC}"
        log_action "ERROR: 创建用户 $username 失败。"
    fi
    read -p "按回车键继续..."
}

# 删除用户
delete_user() {
    read -p "请输入要删除的用户名: " username
    # 检查用户名有效性
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    read -p "是否删除用户主目录和邮件池? (y/N): " delete_home
    local remove_option=""
    if [[ $delete_home =~ ^[Yy]$ ]]; then
        remove_option="-r"
    fi

    userdel $remove_option "$username"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}用户 '$username' 删除成功。${NC}"
        log_action "INFO: 删除用户 $username (主目录删除: ${delete_home:-no})。"
    else
        echo -e "${RED}删除用户 '$username' 失败。${NC}"
        log_action "ERROR: 删除用户 $username 失败。"
    fi
    read -p "按回车键继续..."
}

# 修改用户信息
modify_user() {
    read -p "请输入要修改的用户名: " username
    # 检查用户名有效性
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "当前用户信息:"
    echo "用户名: $username"
    echo "UID: $(id -u "$username")"
    echo "GID: $(id -g "$username")"
    echo "主目录: $(eval echo ~"$username")"
    echo "Shell: $(grep "^${username}:" /etc/passwd | cut -d: -f7)"
    echo "全名: $(grep "^${username}:" /etc/passwd | cut -d: -f5)"

    echo ""
    echo "请选择要修改的属性:"
    echo "1. 全名 (GECOS)"
    echo "2. 主目录"
    echo "3. 登录Shell"
    echo "4. UID"
    echo "0. 返回"
    read -p "请选择 [0-4]: " modify_choice

    case $modify_choice in
        1)
            read -p "请输入新的全名: " new_fullname
            usermod -c "$new_fullname" "$username"
            if [[ $? -eq 0 ]]; then
                log_action "INFO: 修改用户 $username 的全名为 '$new_fullname'。"
                echo -e "${GREEN}全名修改成功。${NC}"
            else
                echo -e "${RED}全名修改失败。${NC}"
            fi
            ;;
        2)
            read -p "请输入新的主目录路径: " new_home
            # 简单路径检查
            if [[ "$new_home" != /* ]]; then
                echo -e "${RED}错误: 路径必须是绝对路径。${NC}"
            else
                usermod -d "$new_home" -m "$username" # -m 移动旧主目录
                if [[ $? -eq 0 ]]; then
                    log_action "INFO: 修改用户 $username 的主目录为 '$new_home' 并移动内容。"
                    echo -e "${GREEN}主目录修改并移动内容成功。${NC}"
                else
                    echo -e "${RED}主目录修改失败。${NC}"
                fi
            fi
            ;;
        3)
            read -p "请输入新的登录Shell路径: " new_shell
            if [[ -f "$new_shell" && -x "$new_shell" ]]; then
                usermod -s "$new_shell" "$username"
                if [[ $? -eq 0 ]]; then
                    log_action "INFO: 修改用户 $username 的登录Shell为 '$new_shell'。"
                    echo -e "${GREEN}登录Shell修改成功。${NC}"
                else
                    echo -e "${RED}登录Shell修改失败。${NC}"
                fi
            else
                echo -e "${RED}错误: '$new_shell' 不是有效的可执行文件。${NC}"
            fi
            ;;
        4)
            read -p "请输入新的UID: " new_uid
            if [[ $new_uid =~ ^[0-9]+$ ]]; then
                usermod -u "$new_uid" "$username"
                if [[ $? -eq 0 ]]; then
                    log_action "INFO: 修改用户 $username 的UID为 '$new_uid'。"
                    echo -e "${GREEN}UID修改成功。${NC}"
                else
                    echo -e "${RED}UID修改失败。${NC}"
                fi
            else
                echo -e "${RED}错误: UID 必须是数字。${NC}"
            fi
            ;;
        0) return ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
    read -p "按回车键继续..."
}

# 列出所有用户
list_users() {
    echo "系统中的所有用户:"
    echo "----------------------------"
    awk -F: '{printf "%-15s UID: %-6s GID: %-6s Home: %-20s Shell: %s\n", $1, $3, $4, $6, $7}' /etc/passwd
    echo "----------------------------"
    read -p "按回车键继续..."
}

# 锁定/解锁用户
lock_unlock_user() {
    read -p "请输入用户名: " username
    # 检查用户名有效性
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    # 检查账户是否被锁定 (检查 /etc/shadow 第二字段是否以 ! 或 * 开头)
    local is_locked=$(passwd -S "$username" | awk '{print $2}')
    if [[ "$is_locked" == "L" || "$is_locked" == "LK" ]]; then
        echo "用户 '$username' 当前状态: ${RED}已锁定${NC}"
        read -p "是否解锁该用户? (y/N): " unlock_choice
        if [[ $unlock_choice =~ ^[Yy]$ ]]; then
            usermod -U "$username"
            if [[ $? -eq 0 ]]; then
                log_action "INFO: 解锁用户 $username。"
                echo -e "${GREEN}用户 '$username' 已解锁。${NC}"
            else
                echo -e "${RED}用户解锁失败。${NC}"
            fi
        fi
    else
        echo "用户 '$username' 当前状态: ${GREEN}未锁定${NC}"
        read -p "是否锁定该用户? (y/N): " lock_choice
        if [[ $lock_choice =~ ^[Yy]$ ]]; then
            usermod -L "$username"
            if [[ $? -eq 0 ]]; then
                log_action "INFO: 锁定用户 $username。"
                echo -e "${GREEN}用户 '$username' 已锁定。${NC}"
            else
                 echo -e "${RED}用户锁定失败。${NC}"
            fi
        fi
    fi
    read -p "按回车键继续..."
}

# 组管理子菜单
group_management_menu() {
    while true; do
        clear
        echo "---------------------------"
        echo "         组管理菜单        "
        echo "---------------------------"
        echo "1. 创建组"
        echo "2. 删除组"
        echo "3. 修改组信息"
        echo "4. 列出所有组"
        echo "5. 添加用户到组"
        echo "6. 从组中移除用户"
        echo "0. 返回主菜单"
        echo "---------------------------"
        read -p "请选择操作 [0-6]: " choice

        case $choice in
            1) create_group ;;
            2) delete_group ;;
            3) modify_group ;;
            4) list_groups ;;
            5) add_user_to_group ;;
            6) remove_user_from_group ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${NC}"; sleep 2 ;;
        esac
    done
}

# 创建组
create_group() {
    read -p "请输入要创建的组名: " groupname
    # 基本组名有效性检查
    if [[ ! "$groupname" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 组名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if getent group "$groupname" &>/dev/null; then
        echo -e "${YELLOW}警告: 组 '$groupname' 已存在。${NC}"
        read -p "是否修改其GID? (y/N): " specify_gid
        if [[ $specify_gid =~ ^[Yy]$ ]]; then
            read -p "请输入新的GID: " gid
            if [[ $gid =~ ^[0-9]+$ ]]; then
                groupmod -g "$gid" "$groupname"
                if [[ $? -eq 0 ]]; then
                    log_action "INFO: 修改组 $groupname 的GID为 $gid。"
                    echo -e "${GREEN}组 '$groupname' 的GID已修改为 $gid。${NC}"
                else
                    echo -e "${RED}GID修改失败。${NC}"
                fi
            else
                echo -e "${RED}错误: GID 必须是数字。${NC}"
            fi
        fi
        read -p "按回车键继续..."
        return
    fi

    read -p "是否指定GID? (y/N): " specify_gid
    local gid_option=""
    if [[ $specify_gid =~ ^[Yy]$ ]]; then
        read -p "请输入GID: " gid
        if [[ $gid =~ ^[0-9]+$ ]]; then
            gid_option="-g $gid"
        else
            echo -e "${RED}错误: GID 必须是数字。${NC}"
            read -p "按回车键继续..."
            return
        fi
    fi

    groupadd $gid_option "$groupname"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}组 '$groupname' 创建成功。${NC}"
        log_action "INFO: 创建组 $groupname ($gid_option)。"
    else
        echo -e "${RED}创建组 '$groupname' 失败。${NC}"
        log_action "ERROR: 创建组 $groupname 失败。"
    fi
    read -p "按回车键继续..."
}

# 删除组
delete_group() {
    read -p "请输入要删除的组名: " groupname
    # 检查组名有效性
    if [[ ! "$groupname" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 组名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! getent group "$groupname" &>/dev/null; then
        echo -e "${YELLOW}组 '$groupname' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    # 检查是否有用户以此组为主要组
    local primary_users=$(awk -F: '$4 == g {print $1}' g=$(getent group "$groupname" | cut -d: -f3) /etc/passwd | tr '\n' ' ')
    if [[ -n "$primary_users" ]]; then
        echo -e "${YELLOW}警告: 以下用户将此组作为主要组: $primary_users${NC}"
        echo -e "${YELLOW}删除组可能会影响这些用户。${NC}"
        read -p "是否继续删除? (y/N): " confirm_delete
        if [[ ! $confirm_delete =~ ^[Yy]$ ]]; then
            echo "操作已取消。"
            read -p "按回车键继续..."
            return
        fi
    fi

    groupdel "$groupname"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}组 '$groupname' 删除成功。${NC}"
        log_action "INFO: 删除组 $groupname。"
    else
        echo -e "${RED}删除组 '$groupname' 失败。可能有用户仍属于此组。${NC}"
        log_action "ERROR: 删除组 $groupname 失败。"
    fi
    read -p "按回车键继续..."
}

# 修改组信息 (主要是GID)
modify_group() {
    read -p "请输入要修改的组名: " groupname
    # 检查组名有效性
    if [[ ! "$groupname" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 组名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! getent group "$groupname" &>/dev/null; then
        echo -e "${YELLOW}组 '$groupname' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "当前组信息:"
    echo "组名: $groupname"
    echo "GID: $(getent group "$groupname" | cut -d: -f3)"
    echo "成员: $(getent group "$groupname" | cut -d: -f4)"

    read -p "请输入新的GID: " new_gid
    if [[ $new_gid =~ ^[0-9]+$ ]]; then
        groupmod -g "$new_gid" "$groupname"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}组 '$groupname' 的GID已修改为 $new_gid。${NC}"
            log_action "INFO: 修改组 $groupname 的GID为 $new_gid。"
        else
            echo -e "${RED}修改组 '$groupname' 的GID失败。${NC}"
            log_action "ERROR: 修改组 $groupname 的GID为 $new_gid 失败。"
        fi
    else
        echo -e "${RED}错误: GID 必须是数字。${NC}"
    fi
    read -p "按回车键继续..."
}

# 列出所有组
list_groups() {
    echo "系统中的所有组:"
    echo "----------------------------"
    awk -F: '{printf "%-20s GID: %-6s Members: %s\n", $1, $3, $4}' /etc/group
    echo "----------------------------"
    read -p "按回车键继续..."
}

# 添加用户到组
add_user_to_group() {
    read -p "请输入用户名: " username
    # 检查用户名有效性
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    read -p "请输入组名: " groupname
    # 检查组名有效性
    if [[ ! "$groupname" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 组名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! getent group "$groupname" &>/dev/null; then
        echo -e "${YELLOW}组 '$groupname' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    # 使用 usermod -aG 添加到附加组
    usermod -aG "$groupname" "$username"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}用户 '$username' 已成功添加到组 '$groupname'。${NC}"
        log_action "INFO: 将用户 $username 添加到组 $groupname。"
    else
        echo -e "${RED}将用户 '$username' 添加到组 '$groupname' 失败。${NC}"
        log_action "ERROR: 将用户 $username 添加到组 $groupname 失败。"
    fi
    read -p "按回车键继续..."
}

# 从组中移除用户
remove_user_from_group() {
    read -p "请输入用户名: " username
    # 检查用户名有效性
    if [[ ! "$username" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 用户名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    read -p "请输入组名: " groupname
    # 检查组名有效性
    if [[ ! "$groupname" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]]; then
        echo -e "${RED}错误: 组名格式无效。${NC}"
        read -p "按回车键继续..."
        return
    fi

    if ! getent group "$groupname" &>/dev/null; then
        echo -e "${YELLOW}组 '$groupname' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    # 检查用户是否在组中
    if id -nG "$username" | grep -qw "$groupname"; then
        # 使用 gpasswd -d 从组中移除用户
        gpasswd -d "$username" "$groupname"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}用户 '$username' 已成功从组 '$groupname' 中移除。${NC}"
            log_action "INFO: 将用户 $username 从组 $groupname 中移除。"
        else
            echo -e "${RED}将用户 '$username' 从组 '$groupname' 中移除失败。${NC}"
            log_action "ERROR: 将用户 $username 从组 $groupname 中移除失败。"
        fi
    else
        echo -e "${YELLOW}用户 '$username' 不属于组 '$groupname'。${NC}"
    fi
    read -p "按回车键继续..."
}

# 权限控制子菜单
permission_control_menu() {
    while true; do
        clear
        echo "---------------------------"
        echo "       权限控制菜单        "
        echo "---------------------------"
        echo "1. 修改文件/目录权限 (chmod)"
        echo "2. 修改文件/目录所有者 (chown)"
        echo "3. 查看文件/目录详细权限"
        echo "4. 设置ACL权限"
        echo "5. 查看ACL权限"
        echo "0. 返回主菜单"
        echo "---------------------------"
        read -p "请选择操作 [0-5]: " choice

        case $choice in
            1) change_permissions ;;
            2) change_ownership ;;
            3) view_detailed_permissions ;;
            4) set_acl_permissions ;;
            5) view_acl_permissions ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${NC}"; sleep 2 ;;
        esac
    done
}

# 修改文件/目录权限
change_permissions() {
    read -p "请输入文件或目录的路径: " path
    if [[ ! -e "$path" ]]; then
        echo -e "${YELLOW}路径 '$path' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "当前权限: $(ls -ld "$path" | cut -d' ' -f1)"
    read -p "请输入新的权限 (八进制, 如 755): " perm
    if [[ $perm =~ ^[0-7]{3,4}$ ]]; then
        chmod "$perm" "$path"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}权限修改成功。${NC}"
            log_action "INFO: 修改 $path 的权限为 $perm。"
        else
            echo -e "${RED}权限修改失败。${NC}"
            log_action "ERROR: 修改 $path 的权限为 $perm 失败。"
        fi
    else
        echo -e "${RED}错误: 权限格式无效。请使用3位或4位八进制数。${NC}"
    fi
    read -p "按回车键继续..."
}

# 修改文件/目录所有者 (修复了变量引用)
change_ownership() {
    read -p "请输入文件或目录的路径: " path
    if [[ ! -e "$path" ]]; then
        echo -e "${YELLOW}路径 '$path' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "当前所有者: $(ls -ld "$path" | awk '{print $3":"$4}')"
    read -p "请输入新的所有者 (用户名[:组名]): " owner
    # 简单验证用户是否存在 (检查用户名部分)
    local user_part=$(echo "$owner" | cut -d: -f1)
    if id "$user_part" &>/dev/null; then
        # 修复：为变量加上引号
        chown "$owner" "$path"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}所有者修改成功。${NC}"
            log_action "INFO: 修改 $path 的所有者为 $owner。"
        else
            echo -e "${RED}所有者修改失败。${NC}"
            log_action "ERROR: 修改 $path 的所有者为 $owner 失败。"
        fi
    else
        echo -e "${RED}错误: 用户 '$user_part' 不存在。${NC}"
    fi
    read -p "按回车键继续..."
}

# 查看文件/目录详细权限
view_detailed_permissions() {
    read -p "请输入文件或目录的路径: " path
    if [[ ! -e "$path" ]]; then
        echo -e "${YELLOW}路径 '$path' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi
    echo "详细权限信息:"
    echo "----------------------------"
    ls -ld "$path"
    echo "----------------------------"
    read -p "按回车键继续..."
}

# 设置ACL权限
set_acl_permissions() {
    read -p "请输入文件或目录的路径: " path
    if [[ ! -e "$path" ]]; then
        echo -e "${YELLOW}路径 '$path' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "请选择ACL类型:"
    echo "1. 为用户设置ACL"
    echo "2. 为组设置ACL"
    read -p "请选择 [1-2]: " acl_type

    local acl_spec=""
    case $acl_type in
        1)
            read -p "请输入用户名: " acl_user
            if id "$acl_user" &>/dev/null; then
                acl_spec="u:$acl_user"
            else
                echo -e "${RED}错误: 用户 '$acl_user' 不存在。${NC}"
                read -p "按回车键继续..."
                return
            fi
            ;;
        2)
            read -p "请输入组名: " acl_group
            if getent group "$acl_group" &>/dev/null; then
                acl_spec="g:$acl_group"
            else
                echo -e "${RED}错误: 组 '$acl_group' 不存在。${NC}"
                read -p "按回车键继续..."
                return
            fi
            ;;
        *)
            echo -e "${RED}无效选项。${NC}"
            read -p "按回车键继续..."
            return
            ;;
    esac

    echo "请输入权限 (r, w, x 的组合, 如 rw, rwx): "
    read -p "权限: " perms
    # 简单验证权限格式
    if [[ $perms =~ ^[rwx]+$ ]]; then
        setfacl -m "$acl_spec:$perms" "$path"
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}ACL权限设置成功。${NC}"
            log_action "INFO: 为 $path 设置ACL $acl_spec:$perms。"
        else
            echo -e "${RED}ACL权限设置失败。${NC}"
            log_action "ERROR: 为 $path 设置ACL $acl_spec:$perms 失败。"
        fi
    else
        echo -e "${RED}错误: 权限格式无效。请使用 r, w, x 的组合。${NC}"
    fi
    read -p "按回车键继续..."
}

# 查看ACL权限
view_acl_permissions() {
    read -p "请输入文件或目录的路径: " path
    if [[ ! -e "$path" ]]; then
        echo -e "${YELLOW}路径 '$path' 不存在。${NC}"
        read -p "按回车键继续..."
        return
    fi
    echo "ACL权限信息:"
    echo "----------------------------"
    getfacl "$path"
    echo "----------------------------"
    read -p "按回车键继续..."
}

# 审计与日志子菜单
audit_log_menu() {
    while true; do
        clear
        echo "---------------------------"
        echo "       审计与日志菜单      "
        echo "---------------------------"
        echo "1. 查看管理日志"
        echo "2. 查看用户登录历史"
        echo "3. 查看最近失败的登录尝试"
        echo "0. 返回主菜单"
        echo "---------------------------"
        read -p "请选择操作 [0-3]: " choice

        case $choice in
            1) view_management_log ;;
            2) view_login_history ;;
            3) view_failed_logins ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${NC}"; sleep 2 ;;
        esac
    done
}

# 查看管理日志
view_management_log() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "管理日志内容 ($LOG_FILE):"
        echo "=================================================="
        # 使用 less 或 more 如果内容过多，这里简单cat
        cat "$LOG_FILE"
        echo "=================================================="
    else
        echo -e "${YELLOW}日志文件 '$LOG_FILE' 不存在。${NC}"
    fi
    read -p "按回车键继续..."
}

# 查看用户登录历史
view_login_history() {
    echo "最近的用户登录历史:"
    echo "=================================================="
    last | head -20
    echo "=================================================="
    read -p "按回车键继续..."
}

# 查看最近失败的登录尝试
view_failed_logins() {
    echo "最近失败的登录尝试 (来自 /var/log/auth.log 或 secure):"
    echo "=================================================="
    # 尝试不同的日志文件
    local found_log=false
    if [[ -f "/var/log/auth.log" ]]; then
        grep -i "Failed\|failure" /var/log/auth.log | tail -20
        found_log=true
    elif [[ -f "/var/log/secure" ]]; then
        grep -i "Failed\|failure" /var/log/secure | tail -20
        found_log=true
    fi
    if [[ "$found_log" != true ]]; then
        echo "未找到标准认证日志文件 (/var/log/auth.log 或 /var/log/secure)。"
    fi
    echo "=================================================="
    read -p "按回车键继续..."
}

# 安全策略子菜单
security_policy_menu() {
    while true; do
        clear
        echo "---------------------------"
        echo "       安全策略菜单        "
        echo "---------------------------"
        echo "1. 设置密码策略 (复杂度、过期)"
        echo "2. 配置SSH安全 (禁用root登录, 更改端口)"
        echo "3. 启用/配置防火墙 (iptables/firewalld)"
        echo "0. 返回主菜单"
        echo "---------------------------"
        # 注意：这些操作较为敏感，此处仅提供框架和概念性实现
        echo -e "${YELLOW}注意：此部分功能为高级功能，修改系统配置请谨慎操作。${NC}"
        read -p "请选择操作 [0-3]: " choice

        case $choice in
            1) set_password_policy ;;
            2) configure_ssh_security ;;
            3) configure_firewall ;;
            0) break ;;
            *) echo -e "${RED}无效选项，请重新选择。${NC}"; sleep 2 ;;
        esac
    done
}

# 设置密码策略 (示例：使用 chage 和 pam_pwquality) (修复了chage命令调用)
set_password_policy() {
    echo "密码策略设置:"
    echo "1. 查看/设置用户密码过期策略 (chage)"
    echo "2. 配置全局密码复杂度策略 (pam_pwquality, 需手动编辑配置)"
    read -p "请选择 [1-2]: " policy_choice

    case $policy_choice in
        1)
            read -p "请输入用户名 (留空则查看当前用户): " username
            if [[ -z "$username" ]]; then
                username=$(whoami)
            elif ! id "$username" &>/dev/null; then
                echo -e "${YELLOW}用户 '$username' 不存在。${NC}"
                read -p "按回车键继续..."
                return
            fi
            echo "用户 '$username' 的当前密码策略:"
            # 修复：为变量加上引号
            chage -l "$username"
            read -p "是否要修改策略? (y/N): " modify_chage
            if [[ $modify_chage =~ ^[Yy]$ ]]; then
                # 交互式修改，直接调用
                chage "$username"
                if [[ $? -eq 0 ]]; then
                     log_action "INFO: 为用户 $username 运行了 chage 交互式修改。"
                     echo -e "${GREEN}密码策略修改命令已执行。请检查输出确认。${NC}"
                else
                     echo -e "${RED}执行 chage 命令时出错。${NC}"
                fi
            fi
            ;;
        2)
            echo "全局密码复杂度策略通常通过编辑 PAM 配置文件来实现，例如:"
            echo "- /etc/pam.d/common-password (Debian/Ubuntu)"
            echo "- /etc/pam.d/system-auth 或 /etc/pam.d/passwd (RHEL/CentOS/Fedora)"
            echo ""
            echo "需要添加或修改类似以下行来启用 pam_pwquality:"
            echo "password requisite pam_pwquality.so retry=3 minlen=8 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1"
            echo ""
            echo -e "${YELLOW}此操作需要手动编辑配置文件，请确保了解其风险。${NC}"
            log_action "INFO: 用户查看了密码复杂度策略配置信息。"
            ;;
        *)
            echo -e "${RED}无效选项。${NC}"
            ;;
    esac
    read -p "按回车键继续..."
}

# 配置SSH安全 (概念性)
configure_ssh_security() {
    local ssh_config_file="/etc/ssh/sshd_config"
    if [[ ! -f "$ssh_config_file" ]]; then
        echo -e "${YELLOW}SSH配置文件 '$ssh_config_file' 未找到。${NC}"
        read -p "按回车键继续..."
        return
    fi

    echo "SSH安全配置选项:"
    echo "1. 禁用 root 直接登录"
    echo "2. 更改 SSH 端口"
    echo "3. 限制特定用户/组登录"
    echo "4. 查看当前SSH配置摘要"
    echo -e "${YELLOW}注意：修改SSH配置后需要重启 sshd 服务才能生效。${NC}"
    read -p "请选择操作 [1-4]: " ssh_choice

    case $ssh_choice in
        1)
            echo "禁用 root 直接登录..."
            # 备份原配置 (增加时间戳)
            local backup_file="${ssh_config_file}.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$ssh_config_file" "$backup_file"
            if [[ $? -eq 0 ]]; then
                 echo "原配置已备份至: $backup_file"
            else
                 echo -e "${RED}警告: 配置文件备份失败。${NC}"
            fi
            # 使用 sed 禁用并设置为 no
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$ssh_config_file"
            echo -e "${GREEN}已设置 PermitRootLogin no。请记得重启 sshd 服务。${NC}"
            log_action "INFO: 在 $ssh_config_file 中设置 PermitRootLogin no。"
            ;;
        2)
            read -p "请输入新的SSH端口号 (建议1024以上): " new_port
            if [[ $new_port =~ ^[0-9]+$ ]] && [[ $new_port -gt 1024 ]] && [[ $new_port -lt 65536 ]]; then
                local backup_file="${ssh_config_file}.bak.$(date +%Y%m%d_%H%M%S)"
                cp "$ssh_config_file" "$backup_file"
                if [[ $? -eq 0 ]]; then
                     echo "原配置已备份至: $backup_file"
                else
                     echo -e "${RED}警告: 配置文件备份失败。${NC}"
                fi
                sed -i "s/^#*Port.*/Port $new_port/" "$ssh_config_file"
                echo -e "${GREEN}已设置 Port $new_port。请记得重启 sshd 服务并在防火墙放行新端口。${NC}"
                log_action "INFO: 在 $ssh_config_file 中设置 Port $new_port。"
            else
                echo -e "${RED}错误: 端口号无效。必须是1025-65535之间的数字。${NC}"
            fi
            ;;
        3)
            echo "限制登录功能需要编辑 AllowUsers, AllowGroups, DenyUsers, DenyGroups 指令。"
            echo "请手动编辑 '$ssh_config_file' 文件进行配置。"
            log_action "INFO: 用户查看了SSH用户/组限制配置信息。"
            ;;
        4)
            echo "当前SSH配置摘要 (已注释和空行已过滤):"
            echo "----------------------------"
            grep -v '^#' "$ssh_config_file" | grep -v '^$' | head -20
            echo "----------------------------"
            echo "请检查以上配置。"
            log_action "INFO: 用户查看了SSH配置摘要。"
            ;;
        *)
            echo -e "${RED}无效选项。${NC}"
            ;;
    esac
    read -p "按回车键继续..."
}

# 配置防火墙 (概念性)
configure_firewall() {
    echo "防火墙配置选项:"
    echo "检测到的防火墙工具:"
    local fw_status="未检测到"
    local fw_cmd=""
    if command -v ufw &> /dev/null; then
        fw_status="UFW (Uncomplicated Firewall)"
        fw_cmd="ufw"
        echo "- UFW"
    fi
    if command -v firewall-cmd &> /dev/null; then
        fw_status="Firewalld"
        fw_cmd="firewall-cmd"
        echo "- Firewalld"
    fi
    if command -v iptables &> /dev/null; then
        fw_status="iptables"
        fw_cmd="iptables"
        echo "- iptables"
    fi
    echo "当前状态: $fw_status"

    if [[ -n "$fw_cmd" ]]; then
        echo ""
        echo "您可以运行 '$fw_cmd --help' 或查阅相关文档来管理防火墙规则。"
    fi
    echo ""
    echo "防火墙配置通常涉及:"
    echo "- 开放/关闭特定端口"
    echo "- 设置默认策略"
    echo "- 配置服务规则"
    echo ""
    echo -e "${YELLOW}此工具不直接修改防火墙规则，请使用对应的命令行工具进行配置。${NC}"
    log_action "INFO: 用户查看了防火墙配置信息。"
    read -p "按回车键继续..."
}

# 主程序逻辑
main() {
    check_root
    # 检查日志文件，不存在则创建
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}警告: 无法创建日志文件 $LOG_FILE。日志记录可能无法正常工作。${NC}"
        fi
    fi
    log_action "INFO: 脚本启动。"

    while true; do
        show_menu
        read -p "请选择操作 [0-6]: " main_choice

        case $main_choice in
            1) user_management_menu ;;
            2) group_management_menu ;;
            3) permission_control_menu ;;
            4) audit_log_menu ;;
            5) security_policy_menu ;;
            6) install_dependencies ;; # 调用修复后的函数
            0)
                log_action "INFO: 脚本退出。"
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择。${NC}"
                sleep 2
                ;;
        esac
    done
}

# 脚本入口
main "$@"




