#!/bin/bash
# Linux用户/组/权限管理工具 v4.3
# 优化点：精确进度显示、麒麟命令修复、密码策略模板、断点续处理
# 支持Ubuntu, Debian, CentOS, RHEL, Fedora, Kylin等主流发行版

# ================= 初始化配置 =================

# 密码策略配置文件
PASSWORD_POLICY_FILE="/etc/user_manager_password_policy.conf"

# 默认密码策略
PASSWORD_MIN_LENGTH=8
PASSWORD_REQUIRE_UPPERCASE=1
PASSWORD_REQUIRE_LOWERCASE=1
PASSWORD_REQUIRE_DIGIT=1
PASSWORD_REQUIRE_SPECIAL=0
PASSWORD_DICT_CHECK=1

# 加载密码策略
load_password_policy() {
    if [ -f "$PASSWORD_POLICY_FILE" ]; then
        source "$PASSWORD_POLICY_FILE"
    else
        # 创建默认策略文件
        cat > "$PASSWORD_POLICY_FILE" <<EOF
# 密码策略配置
# 最小长度 (默认: 8)
PASSWORD_MIN_LENGTH=8
# 要求大写字母 (1:是, 0:否)
PASSWORD_REQUIRE_UPPERCASE=1
# 要求小写字母 (1:是, 0:否)
PASSWORD_REQUIRE_LOWERCASE=1
# 要求数字 (1:是, 0:否)
PASSWORD_REQUIRE_DIGIT=1
# 要求特殊字符 (1:是, 0:否)
PASSWORD_REQUIRE_SPECIAL=0
# 检查密码字典 (1:是, 0:否)
PASSWORD_DICT_CHECK=1
EOF
        chmod 600 "$PASSWORD_POLICY_FILE"
    fi
}

# ================= 进度显示优化 =================

# 精确进度显示函数
show_progress() {
    [ $SILENT_MODE -eq 1 ] && return
    
    local current=$1
    local total=$2
    local message="$3"
    
    # 计算百分比
    local percent=$((100 * current / total))
    
    # 创建进度条
    local bar_len=50
    local filled_len=$((bar_len * current / total))
    local bar=""
    for ((i=0; i<filled_len; i++)); do
        bar+="▓"
    done
    for ((i=filled_len; i<bar_len; i++)); do
        bar+="░"
    done
    
    # 显示进度
    printf "\r${message} [%s] %d%%" "$bar" "$percent"
    if [ $current -eq $total ]; then
        echo ""  # 换行
    fi
}

# 大目录处理函数（精确进度）
process_large_directory() {
    local target="$1"
    local operation="$2"  # chown 或 chmod
    local param="$3"      # 所有者或权限
    
    # 获取文件总数
    local total_files=$(find "$target" -type f 2>/dev/null | wc -l)
    local total_dirs=$(find "$target" -type d 2>/dev/null | wc -l)
    local total_items=$((total_files + total_dirs))
    
    # 小目录直接处理
    if [ $total_items -lt 1000 ]; then
        if [ "$operation" = "chown" ]; then
            chown -R "$param" "$target" 2>/dev/null
        else
            chmod -R "$param" "$target" 2>/dev/null
        fi
        return $?
    fi
    
    # 超大目录处理
    [ $SILENT_MODE -eq 0 ] && {
        echo "检测到超大目录（$total_items 个条目），启用优化处理..."
        echo "处理中，请稍候（可能需要较长时间）..."
    }
    
    # 检查恢复点
    local resume_file="$RESUME_DIR/${operation}_${param}_$(echo "$target" | md5sum | cut -d' ' -f1).resume"
    local processed_items=0
    
    if [ -f "$resume_file" ]; then
        processed_items=$(cat "$resume_file")
        [ $SILENT_MODE -eq 0 ] && echo "检测到恢复点，从第 $processed_items 项继续..."
    fi
    
    # 处理文件和目录（合并计数）
    local current_item=0
    find "$target" \( -type f -o -type d \) -print0 | while IFS= read -r -d $'\0' item; do
        ((current_item++))
        
        # 跳过已处理项
        if [ $current_item -le $processed_items ]; then
            continue
        fi
        
        # 执行操作
        if [ "$operation" = "chown" ]; then
            chown "$param" "$item" 2>/dev/null
        else
            chmod "$param" "$item" 2>/dev/null
        fi
        
        # 定期保存恢复点
        if (( current_item % 100 == 0 )); then
            echo $current_item > "$resume_file"
        fi
        
        # 显示进度（合并文件和目录）
        if [ $SILENT_MODE -eq 0 ] && (( current_item % 100 == 0 || current_item == total_items )); then
            show_progress $current_item $total_items "处理项目"
        fi
    done
    
    # 完成处理，清除恢复点
    rm -f "$resume_file" 2>/dev/null
    
    # 显示最终进度
    if [ $SILENT_MODE -eq 0 ]; then
        show_progress $total_items $total_items "完成"
        echo "操作已完成！"
    fi
    
    return 0
}

# ================= 麒麟命令修复 =================

# 麒麟专用安全命令（修复参数）
kysec_command() {
    local command="$1"
    local target="$2"
    local param="$3"
    
    # 检查麒麟专用命令是否存在
    if [ -x "/usr/bin/kysec_set" ]; then
        case $command in
            chown)
                # 修复参数：使用 -U 而不是 -u
                kysec_set -f "$target" -U "$param" 2>/dev/null
                ;;
            chmod)
                kysec_set -f "$target" -m "$param" 2>/dev/null
                ;;
            *)
                echo "错误：不支持的麒麟安全命令！"
                return 1
                ;;
        esac
    else
        # 回退到标准命令
        case $command in
            chown)
                chown "$param" "$target" 2>/dev/null
                ;;
            chmod)
                chmod "$param" "$target" 2>/dev/null
                ;;
        esac
    fi
}

# ================= 密码策略模板 =================

# 配置密码策略菜单
configure_password_policy() {
    while true; do
        clear
        echo "========================"
        echo "     密码策略配置"
        echo "========================"
        echo "当前策略:"
        echo "1. 最小长度: $PASSWORD_MIN_LENGTH"
        echo "2. 要求大写字母: $([ $PASSWORD_REQUIRE_UPPERCASE -eq 1 ] && echo "是" || echo "否")"
        echo "3. 要求小写字母: $([ $PASSWORD_REQUIRE_LOWERCASE -eq 1 ] && echo "是" || echo "否")"
        echo "4. 要求数字: $([ $PASSWORD_REQUIRE_DIGIT -eq 1 ] && echo "是" || echo "否")"
        echo "5. 要求特殊字符: $([ $PASSWORD_REQUIRE_SPECIAL -eq 1 ] && echo "是" || echo "否")"
        echo "6. 检查密码字典: $([ $PASSWORD_DICT_CHECK -eq 1 ] && echo "是" || echo "否")"
        echo "7. 预设策略模板"
        echo "8. 返回"
        echo "-----------------------"
        read -p "请选择要修改的项 [1-8]: " choice

        case $choice in
            1)
                read -p "输入新的最小长度 (当前: $PASSWORD_MIN_LENGTH): " new_length
                if [[ "$new_length" =~ ^[0-9]+$ ]] && [ $new_length -ge 6 ] && [ $new_length -le 32 ]; then
                    PASSWORD_MIN_LENGTH=$new_length
                    echo "最小长度已设置为 $PASSWORD_MIN_LENGTH"
                else
                    echo "错误：长度必须在6-32之间！"
                fi
                ;;
            2)
                if [ $PASSWORD_REQUIRE_UPPERCASE -eq 1 ]; then
                    PASSWORD_REQUIRE_UPPERCASE=0
                    echo "已禁用大写字母要求"
                else
                    PASSWORD_REQUIRE_UPPERCASE=1
                    echo "已启用大写字母要求"
                fi
                ;;
            3)
                if [ $PASSWORD_REQUIRE_LOWERCASE -eq 1 ]; then
                    PASSWORD_REQUIRE_LOWERCASE=0
                    echo "已禁用小写字母要求"
                else
                    PASSWORD_REQUIRE_LOWERCASE=1
                    echo "已启用小写字母要求"
                fi
                ;;
            4)
                if [ $PASSWORD_REQUIRE_DIGIT -eq 1 ]; then
                    PASSWORD_REQUIRE_DIGIT=0
                    echo "已禁用数字要求"
                else
                    PASSWORD_REQUIRE_DIGIT=1
                    echo "已启用数字要求"
                fi
                ;;
            5)
                if [ $PASSWORD_REQUIRE_SPECIAL -eq 1 ]; then
                    PASSWORD_REQUIRE_SPECIAL=0
                    echo "已禁用特殊字符要求"
                else
                    PASSWORD_REQUIRE_SPECIAL=1
                    echo "已启用特殊字符要求"
                fi
                ;;
            6)
                if [ $PASSWORD_DICT_CHECK -eq 1 ]; then
                    PASSWORD_DICT_CHECK=0
                    echo "已禁用密码字典检查"
                else
                    PASSWORD_DICT_CHECK=1
                    echo "已启用密码字典检查"
                fi
                ;;
            7)
                echo "选择预设策略模板:"
                echo "1. 高强度策略 (推荐)"
                echo "2. 宽松策略"
                echo "3. 取消"
                read -p "请选择 [1-3]: " preset_choice
                
                case $preset_choice in
                    1)
                        # 高强度策略
                        PASSWORD_MIN_LENGTH=12
                        PASSWORD_REQUIRE_UPPERCASE=1
                        PASSWORD_REQUIRE_LOWERCASE=1
                        PASSWORD_REQUIRE_DIGIT=1
                        PASSWORD_REQUIRE_SPECIAL=1
                        PASSWORD_DICT_CHECK=1
                        echo "已应用高强度策略"
                        ;;
                    2)
                        # 宽松策略
                        PASSWORD_MIN_LENGTH=8
                        PASSWORD_REQUIRE_UPPERCASE=0
                        PASSWORD_REQUIRE_LOWERCASE=0
                        PASSWORD_REQUIRE_DIGIT=0
                        PASSWORD_REQUIRE_SPECIAL=0
                        PASSWORD_DICT_CHECK=0
                        echo "已应用宽松策略"
                        ;;
                esac
                ;;
            8)
                # 保存策略到文件
                save_password_policy
                return
                ;;
            *)
                echo "无效选择！"
                ;;
        esac
        sleep 2
    done
}

# ================= 断点续处理优化 =================

# 保存恢复点
save_resume_point() {
    local operation="$1"
    local param="$2"
    local target="$3"
    local current_item="$4"
    
    # 创建恢复点文件名
    local resume_file="$RESUME_DIR/${operation}_${param}_$(echo "$target" | md5sum | cut -d' ' -f1).resume"
    echo "$current_item" > "$resume_file"
}

# 清除恢复点
clear_resume_points() {
    local target="$1"
    if [ -n "$target" ]; then
        # 清除特定目标的恢复点
        local resume_file_pattern="${operation}_${param}_$(echo "$target" | md5sum | cut -d' ' -f1)"
        rm -f "$RESUME_DIR/${resume_file_pattern}*.resume" 2>/dev/null
    else
        # 清除所有恢复点
        rm -f "$RESUME_DIR"/*.resume 2>/dev/null
    fi
    [ $SILENT_MODE -eq 0 ] && echo "恢复点已清除！"
}

# ================= 主函数 =================

# 修改文件所有权（使用精确进度）
change_ownership() {
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    # 危险路径二次确认
    if [[ "$target" == "/etc" || "$target" == "/var" || "$target" == "/usr" ]]; then
        read -p "警告：您正在修改系统关键目录的权限！是否继续? (y/n): " confirm
        [ "$confirm" != "y" ] && return
    fi
    
    read -p "输入新所有者 (格式: 用户:组): " owner
    
    # 保存当前权限以便撤销
    local current_owner=$(stat -c "%U:%G" "$target")
    save_undo "CHANGE_OWNERSHIP" "$target" "chown \"$current_owner\" \"$target\"" ""
    
    # 递归操作警告
    local recursive=""
    if [ -d "$target" ]; then
        read -p "是否递归应用到所有子项? (y/n): " recursive_opt
        [ "$recursive_opt" != "y" ] && recursive=""
    else
        recursive=""
    fi
    
    # 执行命令
    if [ "$recursive_opt" = "y" ] && [ -d "$target" ]; then
        # 使用优化的大目录处理（带精确进度）
        process_large_directory "$target" "chown" "$owner"
    else
        echo "正在修改所有权: chown $owner $target"
        chown "$owner" "$target"
    fi
    
    if [ $? -eq 0 ]; then
        echo "所有权已修改！"
        log_audit "PERMISSION" "$target" "Change ownership to $owner" "SUCCESS"
        # 麒麟系统安全上下文恢复
        if detect_kylin; then
            restore_kylin_security "$target"
        fi
    else
        echo "修改所有权失败！"
        log_audit "PERMISSION" "$target" "Change ownership to $owner" "FAILED"
    fi
    sleep 2
}

# 修改文件权限（使用精确进度）
change_permissions() {
    read -p "输入文件/目录路径: " target
    if ! validate_path "$target"; then
        sleep 2
        return
    fi
    
    # 保存当前权限以便撤销
    local current_perms=$(stat -c "%a" "$target")
    save_undo "CHANGE_PERMISSIONS" "$target" "chmod \"$current_perms\" \"$target\"" ""
    
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

    # 递归操作警告
    local recursive=""
    if [ -d "$target" ]; then
        read -p "是否递归应用到所有子项? (y/n): " recursive_opt
        [ "$recursive_opt" != "y" ] && recursive=""
    else
        recursive=""
    fi

    # 执行命令
    if [ "$recursive_opt" = "y" ] && [ -d "$target" ]; then
        # 使用优化的大目录处理（带精确进度）
        process_large_directory "$target" "chmod" "$perms"
    else
        echo "正在修改权限: chmod $perms $target"
        chmod "$perms" "$target"
    fi
    
    if [ $? -eq 0 ]; then
        echo "权限已修改！"
        log_audit "PERMISSION" "$target" "Change permissions to $perms" "SUCCESS"
    else
        echo "修改权限失败！"
        log_audit "PERMISSION" "$target" "Change permissions to $perms" "FAILED"
    fi
    sleep 2
}

# ================= 系统配置菜单 =================

system_configuration() {
    while true; do
        clear
        echo "========================"
        echo "     系统配置"
        echo "========================"
        echo "1. 配置远程syslog"
        echo "2. 配置LDAP连接"
        echo "3. 切换静默模式"
        echo "4. 切换详细日志模式"
        echo "5. 配置并行处理"
        echo "6. 配置密码策略"
        echo "7. 清除恢复点"
        echo "8. 返回主菜单"
        echo "-----------------------"
        echo "h. 显示帮助"
        read -p "请选择操作 [1-8/h]: " choice
        
        case $choice in
            1) 
                read -p "输入远程syslog服务器地址: " SYSLOG_SERVER
                read -p "输入端口 [514]: " SYSLOG_PORT
                SYSLOG_PORT=${SYSLOG_PORT:-514}
                echo "远程日志服务器已设置为 $SYSLOG_SERVER:$SYSLOG_PORT"
                SYSLOG_ENABLED=1
                log_audit "SYSTEM" "Remote Logging" "Configured syslog server $SYSLOG_SERVER:$SYSLOG_PORT" "SUCCESS"
                ;;
            2) setup_ldap_config ;;
            3) 
                if [ $SILENT_MODE -eq 0 ]; then
                    SILENT_MODE=1
                    echo "静默模式已启用"
                else
                    SILENT_MODE=0
                    echo "静默模式已禁用"
                fi
                log_audit "SYSTEM" "Silent Mode" "Set to $SILENT_MODE" "极CCESS"
                ;;
            4) 
                if [ $VERBOSE_LOG -eq 0 ]; then
                    VERBOSE_LOG=1
                    echo "详细日志模式已启用"
                    touch "${AUDIT_LOG}.verbose"
                    chmod 600 "${AUDIT_LOG}.verbose"
                else
                    VERBOSE_LOG=0
                    echo "详细日志模式已禁用"
                fi
                log_audit "SYSTEM" "Verbose Log" "Set to $VERBOSE_LOG" "SUCCESS"
                ;;
            5) 
                echo "当前并行处理配置:"
                echo "1. 并行处理: $([ $PARALLEL_ENABLED -eq 1 ] && echo "启用" || echo "禁用")"
                echo "2. 并行任务数: $PARALLEL_JOBS"
                echo "3. 自动配置并行任务数"
                echo "4. 返回"
                read -p "请选择 [1-4]: " parallel_choice
                
                case $parallel_choice in
                    1)
                        if [ $PARALLEL_ENABLED -eq 1 ]; then
                            PARALLEL_ENABLED=0
                            echo "并行处理已禁用"
                        else
                            PARALLEL_ENABLED=1
                            echo "并行处理已启用"
                        fi
                        ;;
                    2)
                        read -p "输入并行任务数 (1-8): " jobs
                        if [[ "$jobs" =~ ^[1-8]$ ]]; then
                            PARALLEL_JOBS=$jobs
                            echo "并行任务数已设置为 $PARALLEL_JOBS"
                        else
                            echo "错误：无效的并行任务数！"
                        fi
                        ;;
                    3)
                        set_parallel_jobs
                        echo "并行任务数已自动设置为 $PARALLEL_JOBS"
                        ;;
                esac
                ;;
            6) configure_password_policy ;;
            7) 
                clear_resume_points
                log_audit "SYSTEM" "Resume Points" "Cleared all resume points" "SUCCESS"
                ;;
            8) break ;;
            h) show_help ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
        sleep 2
    done
}

# ================= 主菜单 =================

main_menu() {
    # 加载密码策略
    load_password_policy
    
    while true; do
        clear
        echo "============================================"
        echo " Linux 用户/组/权限管理工具 v4.3"
        echo " 优化：精确进度、麒麟修复、策略模板、断点续处理"
        
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
        
        if [ $SYSLOG_ENABLED -eq 1 ]; then
            echo " 日志: 远程syslog已启用"
        fi
        
        if [ $SILENT_MODE -eq 1 ]; then
            echo " 状态: 静默模式已启用"
        fi
        
        if [ $VERBOSE_LOG -eq 1 ]; then
            echo " 日志模式: 详细日志已启用"
        fi
        
        if [ $PARALLEL_ENABLED -eq 1 ]; then
            echo " 并行处理: 启用 ($PARALLEL_JOBS 任务)"
        else
            echo " 并行处理: 禁用"
        fi
        
        echo " 密码策略: 最小长度 ${PASSWORD_MIN_LENGTH} 字符"
        
        # 检查恢复点
        local resume_count=$(ls "$RESUME_DIR"/*.resume 2>/dev/null | wc -l)
        if [ $resume_count -gt 0 ]; then
            echo " 恢复点: $resume_count 个待恢复操作"
        fi
        
        echo "============================================"
        echo "1. 用户管理"
        echo "2. 用户组管理"
        echo "3. 权限管理"
        echo "4. Sudo权限管理"
        echo "5. 系统配置"
        echo "6. 系统信息"
        echo "7. 查看审计日志"
        echo "8. 退出"
        echo "-----------------------"
        echo "h. 显示帮助"
        echo "u. 撤销上一次操作"
        read -p "请选择主功能 [1-8/h/u]: " main_choice

        case $main_choice in
            1) user_management ;;
            2) group_management ;;
            3) permission_management ;;
            4) sudo_management ;;
            5) system_configuration ;;
            6) show_system_info ;;
            7) 
                less "$AUDIT_LOG"
                ;;
            8) 
                log_audit "SYSTEM" "Shutdown" "Tool exited" "SUCCESS"
                echo "感谢使用！"
                exit 0 
                ;;
            h) show_help ;;
            u) undo_last_operation ;;
            *) echo "无效选择！"; sleep 1 ;;
        esac
    done
}

# ================= 初始化 =================

# 初始化函数
init_tool() {
    check_root
    [ $SILENT_MODE -eq 0 ] && echo "正在检测系统环境..."
    install_dependencies
    
    # 安装密码字典（如果不存在）
    if [ ! -f "$PASSWORD_DICT" ]; then
        [ $SILENT_MODE -eq 0 ] && echo "安装密码字典..."
        if [ -f "/usr/share/dict/american-english" ]; then
            ln -s "/usr/share/dict/american-english" "$PASSWORD_DICT"
        elif command -v apt-get &>/dev/null; then
            apt-get install -y wamerican 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y words 2>/dev/null
        fi
    fi
    
    # 安装cracklib（如果不存在）
    if ! command -v cracklib-check &>/dev/null; then
        [ $SILENT_MODE -eq 0 ] && echo "安装密码策略工具..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y libcrack2 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y cracklib 2>/dev/null
        fi
    fi
    
    # 加载密码策略
    load_password_policy
    
    # 创建恢复点目录
    mkdir -p "$RESUME_DIR"
    chmod 700 "$RESUME_DIR"
    
    [ $SILENT_MODE -eq 0 ] && echo "初始化完成！"
    sleep 1
}

# 启动
init_tool
main_menu