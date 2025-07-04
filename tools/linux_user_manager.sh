#!/bin/bash
# Linux用户/组/权限交互式管理工具
# 支持Ubuntu, Debian, CentOS, RHEL, Fedora, Kylin等主流发行版

# 审计日志文件路径
AUDIT_LOG="/var/log/user_manager_audit.log"

# 记录审计日志函数
log_audit() {
    local action="$1"
    local target="$2"
    local details="$3"
    local status="$4"
    
    # 获取当前用户（可能是sudo用户）
    local current_user=$(whoami)
    
    # 获取实际调用者（如果是sudo执行）
    if [ -n "$SUDO_USER" ]; then
        current_user="$SUDO_USER"
    fi
    
    # 记录日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') | User: $current_user | Action: $action | Target: $target | Details: $details | Status: $status" >> "$AUDIT_LOG"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：此脚本必须以root权限运行！"
        exit 1
    fi
    
    # 创建审计日志
    touch "$AUDIT_LOG"
    chmod 600 "$AUDIT_LOG"
    log_audit "SYSTEM" "Startup" "Tool initialized" "SUCCESS"
}

# 安全输入验证函数
sanitize_input() {
    # 移除非字母数字字符（保留下划线、减号和点）
    echo "$1" | tr -cd '[:alnum:]_.-'
}

# 安全路径验证函数
validate_path() {
    local path="$1"
    
    # 防止危险路径
    if [[ "$path" == "/" || "$path" == "/root" || "$path" == "/home" ]]; then
        echo "错误：禁止操作系统关键目录！"
        return 1
    fi
    
    # 检查路径是否存在
    if [ ! -e "$path" ]; then
        echo "错误：路径 '$path' 不存在！"
        return 1
    fi
    
    return 0
}

# 检测麒麟系统
detect_kylin() {
    if [ -f /etc/kylin-release ]; then
        return 0
    elif grep -qi "kylin" /etc/os-release 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/centos-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

# 检测包管理器并安装必要组件
install_dependencies() {
    local os_type=$(detect_os)
    local pkg_manager=""
    
    case $os_type in
        ubuntu|debian|kylin)
            pkg_manager="apt-get -y install"
            ;;
        centos|rhel|fedora)
            if command -v dnf &>/dev/null; then
                pkg_manager="dnf -y install"
            else
                pkg_manager="yum -y install"
            fi
            ;;
        opensuse*|sles)
            pkg_manager="zypper -n install"
            ;;
        *)
            echo "警告：未知系统类型 - $os_type"
            return 1
            ;;
    esac
    
    # 检查并安装缺失的命令
    local missing_pkgs=()
    
    # 基础工具检查
    for cmd in passwd chown chmod usermod; do
        if ! command -v $cmd &>/dev/null; then
            missing_pkgs+=("$cmd")
        fi
    done
    
    # 麒麟系统需要额外组件
    if detect_kylin; then
        if ! command -v restorecon &>/dev/null; then
            missing_pkgs+=("policycoreutils")
        fi
        if ! command -v getfacl &>/dev/null; then
            missing_pkgs+=("acl")
        fi
    fi
    
    # 安装缺失的包
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "安装缺失的组件: ${missing_pkgs[*]}"
        $pkg_manager "${missing_pkgs[@]}" > /dev/null 2>&1 || {
            echo "错误：组件安装失败！某些功能可能受限"
            log_audit "SYSTEM" "Dependencies" "Failed to install: ${missing_pkgs[*]}" "ERROR"
            return 1
        }
        log_audit "SYSTEM" "Dependencies" "Installed: ${missing_pkgs[*]}" "SUCCESS"
    fi
    return 0
}

# 用户管理菜单
user_management() {
    while true; do
        clear
        echo "========================"
        echo "     用户管理"
        echo "========================"
        echo "1. 创建用户"
        echo "2. 删除用户"
        echo "3. 修改用户属性"
        echo "4. 设置/重置密码"
        echo "5. 锁定/解锁用户"
        echo "6. 列出所有用户"
        echo "7. 查看用户详情"
        echo "8. 返回主菜单"
        read -p "请选择操作 [1-8]: " choice

        case $choice in
            1) create_user ;;
            2) delete_user ;;
            3) modify_user ;;
            4) set_password ;;
            5) toggle_user_lock ;;
            6) list_users ;;
            7) show_user_details ;;
            8) break ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
    done
}

# 用户组管理菜单
group_management() {
    while true; do
        clear
        echo "========================"
        echo "     用户组管理"
        echo "========================"
        echo "1. 创建用户组"
        echo "2. 删除用户组"
        echo "3. 修改组名"
        echo "4. 添加用户到组"
        echo "5. 从组移除用户"
        echo "6. 设置组管理员"
        echo "7. 列出所有用户组"
        echo "8. 查看组详情"
        echo "9. 返回主菜单"
        read -p "请选择操作 [1-9]: " choice

        case $choice in
            1) create_group ;;
            2) delete_group ;;
            3) modify_group_name ;;
            4) add_user_to_group ;;
            5) remove_user_from_group ;;
            6) set_group_admin ;;
            7) list_groups ;;
            8) show_group_details ;;
            9) break ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
    done
}

# 权限管理菜单
permission_management() {
    while true; do
        clear
        echo "========================"
        echo "     权限管理"
        echo "========================"
        echo "1. 修改文件/目录所有权"
        echo "2. 修改文件/目录权限"
        echo "3. 设置ACL权限"
        echo "4. 查看权限详情"
        echo "5. 恢复安全上下文(麒麟)"
        echo "6. 返回主菜单"
        read -p "请选择操作 [1-6]: " choice

        case $choice in
            1) change_ownership ;;
            2) change_permissions ;;
            3) set_acl_permissions ;;
            4) view_permissions ;;
            5) restore_security_context ;;
            6) break ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
    done
}

# ================= 用户管理函数 =================

# 检查密码强度
check_password_strength() {
    local password="$1"
    
    # 最小长度检查
    if [ ${#password} -lt 8 ]; then
        echo "错误：密码长度至少需要8个字符！"
        return 1
    fi
    
    # 复杂度检查
    if ! [[ "$password" =~ [A-Z] ]]; then
        echo "错误：密码必须包含至少一个大写字母！"
        return 1
    fi
    
    if ! [[ "$password" =~ [a-z] ]]; then
        echo "错误：密码必须包含至少一个小写字母！"
        return 1
    fi
    
    if ! [[ "$password" =~ [0-9] ]]; then
        echo "错误：密码必须包含至少一个数字！"
        return 1
    fi
    
    return 0
}

create_user() {
    read -p "输入用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 已存在！"
        log_audit "USER" "$username" "Create user" "FAILED (already exists)"
        sleep 2
        return
    fi
    
    # 麒麟系统特殊处理
    local create_cmd="useradd"
    local create_opts="-m"
    
    if detect_kylin; then
        create_opts="$create_opts -s /bin/bash"
        read -p "是否创建同名用户组? (y/n) [y]: " create_group
        [ "$create_group" = "n" ] && create_opts="$create_opts -N"
    else
        create_opts="$create_opts -s /bin/bash"
    fi
    
    read -p "输入用户描述 (可选): " description
    [ -n "$description" ] && create_opts="$create_opts -c \"$description\""
    
    read -p "输入主目录 (默认自动创建): " home_dir
    [ -n "$home_dir" ] && create_opts="$create_opts -d $home_dir"
    
    while true; do
        read -p "指定用户ID (UID) (1000-65533): " uid
        if [ -z "$uid" ]; then
            break
        elif [[ ! "$uid" =~ ^[0-9]+$ ]]; then
            echo "错误：UID必须是数字！"
        elif [ "$uid" -lt 1000 ] || [ "$uid" -gt 65533 ]; then
            echo "错误：UID必须在1000-65533范围内！"
        else
            create_opts="$create_opts -u $uid"
            break
        fi
    done
    
    # 执行创建命令
    echo "创建用户: $create_cmd $create_opts $username"
    if $create_cmd $create_opts "$username" 2>&1; then
        echo "用户 $username 创建成功！"
        log_audit "USER" "$username" "Create user" "SUCCESS"
        
        # 设置密码
        read -p "是否立即设置密码? (y/n) [y]: " set_pw
        if [ "$set_pw" != "n" ]; then
            set_password "$username"
        fi
        
        # 麒麟系统安全上下文
        if detect_kylin; then
            if [ -d "$(getent passwd "$username" | cut -d: -f6)" ]; then
                restorecon -R "$(getent passwd "$username" | cut -d: -f6)"
            fi
        fi
    else
        echo "用户创建失败！"
        log_audit "USER" "$username" "Create user" "FAILED"
    fi
    sleep 2
}

delete_user() {
    read -p "输入要删除的用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        log_audit "USER" "$username" "Delete user" "FAILED (not exists)"
        sleep 2
        return
    fi
    
    # 确认操作
    read -p "确认删除用户 $username? (y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    # 删除选项
    local del_opts=""
    read -p "删除主目录及其内容? (y/n): " del_home
    [ "$del_home" = "y" ] && del_opts="$del_opts -r"
    
    read -p "强制删除? (y/n): " force
    [ "$force" = "y" ] && del_opts="$del_opts -f"
    
    # 执行删除
    echo "删除用户: userdel $del_opts $username"
    output=$(userdel $del_opts "$username" 2>&1)
    result=$?
    
    if [ $result -eq 0 ]; then
        echo "用户 $username 已删除！"
        log_audit "USER" "$username" "Delete user" "SUCCESS"
    else
        echo "删除用户失败！原因："
        
        # 增强错误解析
        if [[ "$output" == *"currently used"* ]]; then
            echo "- 用户当前已登录"
        fi
        
        if [[ "$output" == *"primary group"* ]]; then
            echo "- 这是其他用户的主要组"
        fi
        
        if [[ "$output" == *"permission denied"* ]]; then
            echo "- 权限不足"
        fi
        
        echo "原始错误信息: $output"
        log_audit "USER" "$username" "Delete user" "FAILED ($output)"
    fi
    sleep 2
}

set_password() {
    local username="$1"
    local password=""
    local confirm_password=""
    local retry_count=0
    local max_retries=3
    
    if [ -z "$username" ]; then
        read -p "输入用户名: " raw_username
        username=$(sanitize_input "$raw_username")
    fi
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    # 安全调用passwd命令
    while [ $retry_count -lt $max_retries ]; do
        read -s -p "输入新密码: " password
        echo
        read -s -p "确认新密码: " confirm_password
        echo
        
        if [ "$password" != "$confirm_password" ]; then
            echo "错误：两次输入的密码不匹配！"
            ((retry_count++))
            continue
        fi
        
        # 检查密码强度
        if ! check_password_strength "$password"; then
            ((retry_count++))
            continue
        fi
        
        # 使用chpasswd安全设置密码
        echo "正在为 $username 设置密码..."
        echo "$username:$password" | chpasswd 2>/dev/null
        result=$?
        
        if [ $result -eq 0 ]; then
            echo "密码设置成功！"
            log_audit "USER" "$username" "Set password" "SUCCESS"
            break
        else
            echo "密码设置失败！"
            echo "可能原因："
            echo "1. 密码不符合系统策略要求"
            echo "2. 用户账户被锁定"
            echo "3. 系统权限问题"
            
            ((retry_count++))
            
            if [ $retry_count -lt $max_retries ]; then
                read -p "是否重试? (y/n): " retry
                [ "$retry" != "y" ] && break
            else
                echo "已达到最大重试次数！"
                log_audit "USER" "$username" "Set password" "FAILED (max retries)"
                break
            fi
        fi
    done
    sleep 2
}

toggle_user_lock() {
    read -p "输入用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    local status=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
    
    if [ "$status" = "L" ]; then
        echo "用户当前状态: 已锁定"
        read -p "是否解锁用户? (y/n): " unlock
        if [ "$unlock" = "y" ]; then
            if usermod -U "$username"; then
                echo "用户已解锁"
                log_audit "USER" "$username" "Unlock user" "SUCCESS"
            else
                echo "解锁失败"
                log_audit "USER" "$username" "Unlock user" "FAILED"
            fi
        fi
    else
        echo "用户当前状态: 正常"
        read -p "是否锁定用户? (y/n): " lock
        if [ "$lock" = "y" ]; then
            if usermod -L "$username"; then
                echo "用户已锁定"
                log_audit "USER" "$username" "Lock user" "SUCCESS"
            else
                echo "锁定失败"
                log_audit "USER" "$username" "Lock user" "FAILED"
            fi
        fi
    fi
    sleep 2
}

list_users() {
    echo "系统用户列表："
    echo "--------------------------------------------"
    awk -F: '$3 >= 1000 && $3 < 65534 {printf "%-15s (UID: %s)\n", $1, $3}' /etc/passwd | less
    echo "--------------------------------------------"
    read -p "按Enter键继续..."
}

show_user_details() {
    read -p "输入用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    echo "用户详细信息: $username"
    echo "============================================"
    echo "基本信息:"
    grep "^$username:" /etc/passwd | awk -F: '{print "用户名: "$1"\nUID: "$3"\nGID: "$4"\n描述: "$5"\n主目录: "$6"\nShell: "$7}'
    echo "--------------------------------------------"
    echo "密码信息:"
    chage -l "$username" 2>/dev/null || echo "密码信息不可用"
    echo "--------------------------------------------"
    echo "所属用户组:"
    groups "$username" | sed 's/^.* : //'
    echo "============================================"
    read -p "按Enter键继续..."
    log_audit "USER" "$username" "View user details" "SUCCESS"
}

modify_user() {
    read -p "输入要修改的用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    echo "选择要修改的属性："
    echo "1. 用户名"
    echo "2. 用户描述"
    echo "3. 主目录"
    echo "4. 登录Shell"
    echo "5. 用户ID (UID)"
    echo "6. 主要组"
    read -p "请选择 [1-6]: " opt

    case $opt in
        1)
            read -p "输入新用户名: " new_name_raw
            new_name=$(sanitize_input "$new_name_raw")
            
            if [ -z "$new_name" ]; then
                echo "错误：新用户名不能为空！"
                sleep 2
                return
            fi
            
            if id "$new_name" &>/dev/null; then
                echo "错误：新用户名 '$new_name' 已存在！"
                sleep 2
                return
            fi
            
            echo "正在修改用户名: usermod -l $new_name $username"
            if usermod -l "$new_name" "$username" 2>&1; then
                echo "用户名已修改为 $new_name"
                log_audit "USER" "$username" "Rename to $new_name" "SUCCESS"
                username="$new_name"  # 更新当前用户名变量
            else
                echo "修改用户名失败！"
                log_audit "USER" "$username" "Rename to $new_name" "FAILED"
            fi
            ;;
        2)
            read -p "输入新描述: " new_comment
            echo "正在修改描述: usermod -c \"$new_comment\" $username"
            if usermod -c "$new_comment" "$username" 2>&1; then
                echo "描述修改成功"
                log_audit "USER" "$username" "Change description" "SUCCESS"
            else
                echo "修改描述失败！"
                log_audit "USER" "$username" "Change description" "FAILED"
            fi
            ;;
        3)
            read -p "输入新主目录: " new_home
            if ! validate_path "$new_home"; then
                sleep 2
                return
            fi
            echo "正在修改主目录: usermod -d $new_home -m $username"
            if usermod -d "$new_home" -m "$username" 2>&1; then
                echo "主目录修改成功"
                log_audit "USER" "$username" "Change home to $new_home" "SUCCESS"
            else
                echo "修改主目录失败！"
                log_audit "USER" "$username" "Change home to $new_home" "FAILED"
            fi
            ;;
        4)
            read -p "输入新Shell (例如 /bin/bash): " new_shell
            echo "正在修改Shell: usermod -s $new_shell $username"
            if usermod -s "$new_shell" "$username" 2>&1; then
                echo "Shell修改成功"
                log_audit "USER" "$username" "Change shell to $new_shell" "SUCCESS"
            else
                echo "修改Shell失败！"
                log_audit "USER" "$username" "Change shell to $new_shell" "FAILED"
            fi
            ;;
        5)
            while true; do
                read -p "输入新UID (1000-65533): " new_uid
                if [[ ! "$new_uid" =~ ^[0-9]+$ ]]; then
                    echo "错误：UID必须是数字！"
                elif [ "$new_uid" -lt 1000 ] || [ "$new_uid" -gt 65533 ]; then
                    echo "错误：UID必须在1000-65533范围内！"
                else
                    echo "正在修改UID: usermod -u $new_uid $username"
                    if usermod -u "$new_uid" "$username" 2>&1; then
                        echo "UID修改成功"
                        log_audit "USER" "$username" "Change UID to $new_uid" "SUCCESS"
                    else
                        echo "修改UID失败！"
                        log_audit "USER" "$username" "Change UID to $new_uid" "FAILED"
                    fi
                    break
                fi
            done
            ;;
        6)
            read -p "输入新的主要组: " new_group
            if ! getent group "$new_group" >/dev/null; then
                echo "错误：组 '$new_group' 不存在！"
                sleep 2
                return
            fi
            echo "正在修改主要组: usermod -g $new_group $username"
            if usermod -g "$new_group" "$username" 2>&1; then
                echo "主要组修改成功"
                log_audit "USER" "$username" "Change primary group to $new_group" "SUCCESS"
            else
                echo "修改主要组失败！"
                log_audit "USER" "$username" "Change primary group to $new_group" "FAILED"
            fi
            ;;
        *)
            echo "无效选择！"
            ;;
    esac
    
    # 麒麟系统更新安全上下文
    if detect_kylin; then
        user_home=$(getent passwd "$username" | cut -d: -f6)
        if [ -d "$user_home" ]; then
            restorecon -R "$user_home"
        fi
    fi
    
    sleep 2
}

# ================= 用户组管理函数 =================

create_group() {
    read -p "输入组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 已存在！"
        log_audit "GROUP" "$groupname" "Create group" "FAILED (already exists)"
        sleep 2
        return
    fi
    
    while true; do
        read -p "输入组ID (GID) (1000-65533): " gid
        if [ -z "$gid" ]; then
            groupadd_cmd="groupadd"
            break
        elif [[ ! "$gid" =~ ^[0-9]+$ ]]; then
            echo "错误：GID必须是数字！"
        elif [ "$gid" -lt 1000 ] || [ "$gid" -gt 65533 ]; then
            echo "错误：GID必须在1000-65533范围内！"
        else
            groupadd_cmd="groupadd -g $gid"
            break
        fi
    done
    
    echo "正在创建组: $groupadd_cmd $groupname"
    if $groupadd_cmd "$groupname" 2>&1; then
        echo "组 $groupname 创建成功！"
        log_audit "GROUP" "$groupname" "Create group" "SUCCESS"
    else
        echo "创建组失败！"
        log_audit "GROUP" "$groupname" "Create group" "FAILED"
    fi
    sleep 2
}

delete_group() {
    read -p "输入要删除的组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if ! getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 不存在！"
        log_audit "GROUP" "$groupname" "Delete group" "FAILED (not exists)"
        sleep 2
        return
    fi
    
    read -p "确认删除组 $groupname? (y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    echo "正在删除组: groupdel $groupname"
    output=$(groupdel "$groupname" 2>&1)
    result=$?
    
    if [ $result -eq 0 ]; then
        echo "组 $groupname 已删除！"
        log_audit "GROUP" "$groupname" "Delete group" "SUCCESS"
    else
        echo "删除组失败！原因："
        
        # 增强错误解析
        if [[ "$output" == *"primary group"* ]]; then
            echo "- 这是用户的主要组，请先删除或迁移用户"
        elif [[ "$output" == *"permission denied"* ]]; then
            echo "- 权限不足"
        elif [[ "$output" == *"does not exist"* ]]; then
            echo "- 组不存在"
        else
            echo "- 未知错误"
        fi
        
        echo "原始错误信息: $output"
        log_audit "GROUP" "$groupname" "Delete group" "FAILED ($output)"
    fi
    sleep 2
}

add_user_to_group() {
    read -p "输入用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    read -p "输入组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    if ! getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 不存在！"
        sleep 2
        return
    fi
    
    echo "正在添加用户到组: gpasswd -a $username $groupname"
    if gpasswd -a "$username" "$groupname" 2>&1; then
        echo "已将 $username 添加到 $groupname 组"
        log_audit "GROUP" "$groupname" "Add user $username" "SUCCESS"
    else
        echo "添加用户到组失败！"
        log_audit "GROUP" "$groupname" "Add user $username" "FAILED"
    fi
    sleep 2
}

remove_user_from_group() {
    read -p "输入用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    read -p "输入组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi

    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi

    if ! getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 不存在！"
        sleep 2
        return
    fi

    echo "正在从组移除用户: gpasswd -d $username $groupname"
    if gpasswd -d "$username" "$groupname" 2>&1; then
        echo "已将 $username 从 $groupname 组移除"
        log_audit "GROUP" "$groupname" "Remove user $username" "SUCCESS"
    else
        echo "移除用户失败！"
        log_audit "GROUP" "$groupname" "Remove user $username" "FAILED"
    fi
    sleep 2
}

list_groups() {
    echo "系统用户组列表："
    echo "--------------------------------------------"
    awk -F: '$3 >= 1000 && $3 < 65534 {printf "%-15s (GID: %s)\n", $1, $3}' /etc/group | less
    echo "--------------------------------------------"
    read -p "按Enter键继续..."
    log_audit "SYSTEM" "Groups" "List groups" "SUCCESS"
}

show_group_details() {
    read -p "输入组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if ! getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 不存在！"
        sleep 2
        return
    fi
    
    echo "组详细信息: $groupname"
    echo "============================================"
    echo "基本信息:"
    grep "^$groupname:" /etc/group | awk -F: '{print "组名: "$1"\nGID: "$3"\n成员: "$4}'
    echo "--------------------------------------------"
    echo "组成员列表:"
    getent group "$groupname" | cut -d: -f4 | tr ',' '\n' | sort
    echo "============================================"
    read -p "按Enter键继续..."
    log_audit "GROUP" "$groupname" "View group details" "SUCCESS"
}

modify_group_name() {
    read -p "输入原组名: " old_group_raw
    old_group=$(sanitize_input "$old_group_raw")
    
    if [ -z "$old_group" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if ! getent group "$old_group" >/dev/null; then
        echo "错误：组 '$old_group' 不存在！"
        sleep 2
        return
    fi
    
    read -p "输入新组名: " new_group_raw
    new_group=$(sanitize_input "$new_group_raw")
    
    if [ -z "$new_group" ]; then
        echo "错误：新组名不能为空！"
        sleep 2
        return
    fi
    
    if getent group "$new_group" >/dev/null; then
        echo "错误：新组名 '$new_group' 已存在！"
        sleep 2
        return
    fi
    
    echo "正在修改组名: groupmod -n $new_group $old_group"
    if groupmod -n "$new_group" "$old_group" 2>&1; then
        echo "组名已从 $old_group 修改为 $new_group"
        log_audit "GROUP" "$old_group" "Rename to $new_group" "SUCCESS"
    else
        echo "修改组名失败！"
        log_audit "GROUP" "$old_group" "Rename to $new_group" "FAILED"
    fi
    sleep 2
}

set_group_admin() {
    read -p "输入组名: " raw_groupname
    groupname=$(sanitize_input "$raw_groupname")
    
    if [ -z "$groupname" ]; then
        echo "错误：组名不能为空！"
        sleep 2
        return
    fi
    
    if ! getent group "$groupname" >/dev/null; then
        echo "错误：组 '$groupname' 不存在！"
        sleep 2
        return
    fi
    
    read -p "输入管理员用户名: " raw_username
    username=$(sanitize_input "$raw_username")
    
    if [ -z "$username" ]; then
        echo "错误：用户名不能为空！"
        sleep 2
        return
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "错误：用户 '$username' 不存在！"
        sleep 2
        return
    fi
    
    echo "正在设置组管理员: gpasswd -A $username $groupname"
    if gpasswd -A "$username" "$groupname" 2>&1; then
        echo "已将 $username 设置为 $groupname 组的管理员"
        log_audit "GROUP" "$groupname" "Set admin $username" "SUCCESS"
    else
        echo "设置组管理员失败！"
        log_audit "GROUP" "$groupname" "Set admin $username" "FAILED"
    fi
    sleep 2
}

# ================= 权限管理函数 =================

# 检查目录大小
check_directory_size() {
    local target="$1"
    
    # 如果是文件，直接返回
    if [ ! -d "$target" ]; then
        return 0
    fi
    
    # 估算文件数量
    local file_count=$(find "$target" -type f 2>/dev/null | wc -l)
    
    if [ "$file_count" -gt 1000 ]; then
        echo "警告：此目录包含超过 $file_count 个文件！"
        read -p "递归操作可能消耗大量系统资源，是否继续? [y/N]: " confirm
        
        if [ "$confirm" != "y" ]; then
            echo "操作已取消"
            log_audit "PERMISSION" "$target" "Recursive operation canceled" "CANCELED"
            return 1  # 返回非0表示用户取消
        fi
    fi
    
    return 0
}

change_ownership() {
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    # 危险路径二次确认
    if [[ "$target" == "/etc" || "$target" == "/var" || "$target" == "/usr" ]]; then
        read -p "警告：您正在修改系统目录的权限！是否继续? (y/n): " confirm
        [ "$confirm" != "y" ] && return
    fi
    
    read -p "输入新所有者 (格式: 用户:组): " owner
    
    # 检查目录大小，如果用户取消则完全终止
    if ! check_directory_size "$target"; then
        return 1  # 完全终止当前操作
    fi
    
    # 递归操作警告
    local recursive=""
    if [ -d "$target" ]; then
        read -p "是否递归应用到所有子项? (y/n): " recursive_opt
        [ "$recursive_opt" = "y" ] && recursive="-R"
    fi
    
    echo "正在修改所有权: chown $recursive $owner $target"
    if chown $recursive "$owner" "$target" 2>&1; then
        echo "所有权已修改！"
        log_audit "PERMISSION" "$target" "Change ownership to $owner" "SUCCESS"
        # 麒麟系统安全上下文恢复
        if detect_kylin; then
            restorecon -Rv "$target"
        fi
    else
        echo "修改所有权失败！"
        log_audit "PERMISSION" "$target" "Change ownership to $owner" "FAILED"
    fi
    sleep 2
}

change_permissions() {
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    # 危险权限警告
    while true; do
        read -p "输入权限 (八进制格式，如755): " perms
        if [[ ! "$perms" =~ ^[0-7]{3,4}$ ]]; then
            echo "错误：权限格式无效！请使用3-4位八进制数字"
        else
            # 阻止危险权限设置
            if [[ "$perms" == "777" && "$target" == "/"* ]]; then
                read -p "警告：您正在设置全局可写权限！是否继续? (y/n): " confirm
                [ "$confirm" != "y" ] && continue
            fi
            break
        fi
    done

    # 检查目录大小，如果用户取消则完全终止
    if ! check_directory_size "$target"; then
        return 1  # 完全终止当前操作
    fi

    # 递归操作警告
    local recursive=""
    if [ -d "$target" ]; then
        read -p "是否递归应用到所有子项? (y/n): " recursive_opt
        [ "$recursive_opt" = "y" ] && recursive="-R"
    fi

    echo "正在修改权限: chmod $recursive $perms $target"
    if chmod $recursive "$perms" "$target" 2>&1; then
        echo "权限已修改！"
        log_audit "PERMISSION" "$target" "Change permissions to $perms" "SUCCESS"
    else
        echo "修改权限失败！"
        log_audit "PERMISSION" "$target" "Change permissions to $perms" "FAILED"
    fi
    sleep 2
}

# 验证ACL权限格式
validate_acl_perms() {
    local perms="$1"
    
    # 标准格式: rwx, r-x, rw-, etc.
    if [[ "$perms" =~ ^[r-][w-][x-]$ ]]; then
        return 0
    fi
    
    # 数字格式: 7, 5, 6, etc.
    if [[ "$perms" =~ ^[0-7]$ ]]; then
        return 0
    fi
    
    return 1
}

set_acl_permissions() {
    if ! command -v setfacl &>/dev/null; then
        echo "ACL工具未安装，尝试安装中..."
        install_dependencies
        if ! command -v setfacl &>/dev/null; then
            echo "错误：ACL支持不可用！"
            sleep 2
            return
        fi
    fi
    
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    echo "选择ACL类型:"
    echo "1. 为用户设置权限"
    echo "2. 为用户组设置权限"
    echo "3. 设置默认ACL(目录)"
    read -p "请选择 [1-3]: " acl_type
    
    case $acl_type in
        1)
            read -p "输入用户名: " raw_username
            username=$(sanitize_input "$raw_username")
            
            if [ -z "$username" ]; then
                echo "错误：用户名不能为空！"
                sleep 2
                return
            fi
            
            if ! id "$username" &>/dev/null; then
                echo "错误：用户 '$username' 不存在！"
                sleep 2
                return
            fi
            
            while true; do
                read -p "输入权限 (如 rwx 或 7): " perms
                if validate_acl_perms "$perms"; then
                    break
                else
                    echo "错误：权限格式无效！"
                    echo "有效格式: rwx (字母) 或 7 (数字)"
                    echo "权限字符: r=读, w=写, x=执行"
                fi
            done
            
            echo "设置ACL: setfacl -m u:$username:$perms $target"
            if setfacl -m u:"$username":"$perms" "$target" 2>&1; then
                echo "ACL设置成功！"
                log_audit "ACL" "$target" "Set ACL for user $username: $perms" "SUCCESS"
            else
                echo "设置ACL失败！"
                log_audit "ACL" "$target" "Set ACL for user $username: $perms" "FAILED"
            fi
            ;;
        2)
            read -p "输入组名: " raw_groupname
            groupname=$(sanitize_input "$raw_groupname")
            
            if [ -z "$groupname" ]; then
                echo "错误：组名不能为空！"
                sleep 2
                return
            fi
            
            if ! getent group "$groupname" >/dev/null; then
                echo "错误：组 '$groupname' 不存在！"
                sleep 2
                return
            fi
            
            while true; do
                read -p "输入权限 (如 r-x 或 5): " perms
                if validate_acl_perms "$perms"; then
                    break
                else
                    echo "错误：权限格式无效！"
                    echo "有效格式: r-x (字母) 或 5 (数字)"
                    echo "权限字符: r=读, w=写, x=执行"
                fi
            done
            
            echo "设置ACL: setfacl -m g:$groupname:$perms $target"
            if setfacl -m g:"$groupname":"$perms" "$target" 2>&1; then
                echo "ACL设置成功！"
                log_audit "ACL" "$target" "Set ACL for group $groupname: $perms" "SUCCESS"
            else
                echo "设置ACL失败！"
                log_audit "ACL" "$target" "Set ACL for group $groupname: $perms" "FAILED"
            fi
            ;;
        3)
            if [ ! -d "$target" ]; then
                echo "错误：默认ACL仅适用于目录！"
                sleep 2
                return
            fi
            
            while true; do
                read -p "输入权限 (如 rwx 或 7): " perms
                if validate_acl_perms "$perms"; then
                    break
                else
                    echo "错误：权限格式无效！"
                    echo "有效格式: rwx (字母) 或 7 (数字)"
                fi
            done
            
            echo "设置默认ACL: setfacl -d -m u::$perms,g::$perms,o::$perms $target"
            if setfacl -d -m u::"$perms",g::"$perms",o::"$perms" "$target" 2>&1; then
                echo "默认ACL设置成功！"
                log_audit "ACL" "$target" "Set default ACL: $perms" "SUCCESS"
            else
                echo "设置默认ACL失败！"
                log_audit "ACL" "$target" "Set default ACL: $perms" "FAILED"
            fi
            ;;
        *)
            echo "无效选择！"
            ;;
    esac
    sleep 2
}

view_permissions() {
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi

    echo "权限信息: $target"
    echo "============================================"
    ls -ld "$target"
    echo "--------------------------------------------"
    echo "ACL权限:"
    getfacl "$target" 2>/dev/null || echo "ACL未设置或不可用"
    echo "============================================"
    read -p "按Enter键继续..."
    log_audit "PERMISSION" "$target" "View permissions" "SUCCESS"
}

restore_security_context() {
    # 非麒麟系统明确提示
    if ! detect_kylin; then
        echo "====================================================="
        echo " 错误：此功能仅适用于麒麟系统！"
        echo " 当前系统不支持安全上下文恢复操作。"
        echo "====================================================="
        sleep 3
        return
    fi
    
    if ! command -v restorecon &>/dev/null; then
        echo "restorecon命令不可用，尝试安装policycoreutils..."
        install_dependencies
        if ! command -v restorecon &>/dev/null; then
            echo "错误：安全上下文恢复不可用！"
            sleep 2
            return
        fi
    fi
    
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    # 危险路径检查
    if [[ "$target" == "/" || "$target" == "/root" || "$target" == "/home" ]]; then
        read -p "警告：您正在恢复系统关键目录的安全上下文！是否继续? (y/n): " confirm
        [ "$confirm" != "y" ] && return
    fi
    
    # 检查目录大小，如果用户取消则完全终止
    if ! check_directory_size "$target"; then
        return 1  # 完全终止当前操作
    fi
    
    echo "正在恢复安全上下文: restorecon -Rv $target"
    if restorecon -Rv "$target" 2>&1; then
        echo "安全上下文已恢复！"
        log_audit "SECURITY" "$target" "Restore security context" "SUCCESS"
    else
        echo "恢复安全上下文失败！"
        log_audit "SECURITY" "$target" "Restore security context" "FAILED"
    fi
    sleep 2
}

# ================= 主菜单 =================

main_menu() {
    while true; do
        clear
        echo "============================================"
        echo " Linux 用户/组/权限管理工具 v2.3"
        echo " 安全加固版 | 审计日志 | 操作控制"
        
        # 显示系统信息
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo " 系统: $PRETTY_NAME"
        else
            echo " 系统: $(uname -srm)"
        fi
        
        if detect_kylin; then
            echo " 模式: 麒麟系统优化模式"
        fi
        
        echo "============================================"
        echo "1. 用户管理"
        echo "2. 用户组管理"
        echo "3. 权限管理"
        echo "4. 系统信息"
        echo "5. 查看审计日志"
        echo "6. 退出"
        read -p "请选择主功能 [1-6]: " main_choice

        case $main_choice in
            1) user_management ;;
            2) group_management ;;
            3) permission_management ;;
            4) show_system_info ;;
            5) view_audit_log ;;
            6) 
                log_audit "SYSTEM" "Shutdown" "Tool exited" "SUCCESS"
                echo "感谢使用！"
                exit 0 
                ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
    done
}

# 显示系统信息
show_system_info() {
    clear
    echo "系统信息"
    echo "============================================"
    
    # 操作系统信息
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "操作系统: $PRETTY_NAME"
    else
        echo "操作系统: $(cat /etc/issue 2>/dev/null || echo '未知')"
    fi
    
    # 内核信息
    echo "内核版本: $(uname -r)"
    
    # 系统架构
    echo "系统架构: $(uname -m)"
    
    # 用户统计
    echo "用户数量: $(getent passwd | grep -vE 'nologin$|false$' | wc -l)"
    
    # 组统计
    echo "用户组数量: $(getent group | wc -l)"
    
    # 内存信息
    echo "内存使用: $(free -m | awk '/Mem/{print $3"MB/"$2"MB ("$4"MB 空闲)"}')"
    
    # 安全模块
    if [ -f /sys/kernel/security/lsm ]; then
        echo "安全模块: $(cat /sys/kernel/security/lsm)"
    fi
    
    # 麒麟系统特殊信息
    if detect_kylin; then
        if [ -f /etc/kylin-release ]; then
            echo "麒麟版本: $(cat /etc/kylin-release)"
        fi
        if command -v kylin-security-config &>/dev/null; then
            echo "安全策略: 已启用"
        fi
    fi
    
    echo "============================================"
    read -p "按Enter键返回主菜单..."
}

# 查看审计日志
view_audit_log() {
    if [ ! -f "$AUDIT_LOG" ]; then
        echo "审计日志不存在！"
        sleep 2
        return
    fi
    
    echo "审计日志查看 (最新20条)"
    echo "============================================"
    tail -n 20 "$AUDIT_LOG"
    echo "============================================"
    
    echo "1. 查看完整日志"
    echo "2. 清空日志"
    echo "3. 返回"
    read -p "请选择 [1-3]: " log_choice
    
    case $log_choice in
        1) 
            less "$AUDIT_LOG"
            ;;
        2)
            read -p "确认清空审计日志? (y/n): " confirm
            if [ "$confirm" = "y" ]; then
                > "$AUDIT_LOG"
                echo "审计日志已清空！"
                log_audit "AUDIT" "Log" "Cleared audit log" "SUCCESS"
            fi
            ;;
        *)
            return
            ;;
    esac
}

# 初始化
init_tool() {
    check_root
    echo "正在检测系统环境..."
    install_dependencies
    echo "初始化完成！"
    sleep 1
}

# 启动
init_tool
main_menu