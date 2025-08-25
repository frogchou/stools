#!/bin/bash

# 文件查找工具 - 改进版

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 设置默认结果显示数量
RESULT_LIMIT=50

# 显示错误信息
show_error() {
    echo -e "${RED}错误: $1${NC}" >&2
}

# 验证目录是否存在且可访问
validate_directory() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        show_error "目录 '$dir' 不存在"
        return 1
    fi
    if [ ! -r "$dir" ]; then
        show_error "没有读取目录 '$dir' 的权限"
        return 1
    fi
    return 0
}

# 验证权限格式
validate_permission() {
    local perm="$1"
    if ! echo "$perm" | grep -Eq '^[0-7]{3,4}$'; then
        show_error "权限格式错误，应为3或4位数字 (如 755 或 0644)"
        return 1
    fi
    return 0
}

# 验证用户是否存在
validate_user() {
    local user="$1"
    if ! id "$user" &>/dev/null; then
        show_error "用户 '$user' 不存在"
        return 1
    fi
    return 0
}

# 安全执行find命令
safe_find() {
    local dir="$1"
    shift
    local result=$(find "$dir" "$@" 2>&1 | head -n $RESULT_LIMIT)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo -e "${YELLOW}查找过程中出现错误:${NC}"
        echo "$result" | grep -v "Permission denied" | head -5
        return 1
    fi

    local count=$(echo "$result" | wc -l)
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}未找到匹配的文件${NC}"
        return 0
    fi

    echo "$result"
    return 0
}

# 按名称查找
find_by_name() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    read -p "请输入文件名 (可使用*匹配): " name
    if [ -z "$name" ]; then
        show_error "文件名不能为空"
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -name "$name"
}

# 按类型查找
find_by_type() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    echo "请选择文件类型:"
    echo "1. 普通文件"
    echo "2. 目录"
    echo "3. 符号链接"
    echo "4. 块设备文件"
    echo "5. 字符设备文件"
    read -p "请选择 (1-5): " type_choice

    case $type_choice in
        1) type_option="f" ;;
        2) type_option="d" ;;
        3) type_option="l" ;;
        4) type_option="b" ;;
        5) type_option="c" ;;
        *)
            show_error "无效选择"
            return 1
            ;;
    esac

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -type "$type_option"
}

# 按大小查找
find_by_size() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    echo "请选择文件大小选项:"
    echo "1. 大于指定大小"
    echo "2. 小于指定大小"
    echo "3. 等于指定大小"
    echo "4. 空文件"
    read -p "请选择 (1-4): " size_choice

    case $size_choice in
        1|2|3)
            read -p "请输入大小 (如 10M, 100K, 1G): " size_value
            if [ -z "$size_value" ]; then
                show_error "大小不能为空"
                return 1
            fi

            case $size_choice in
                1) size="+$size_value" ;;
                2) size="-$size_value" ;;
                3) size="$size_value" ;;
            esac
            ;;
        4) size="0" ;;
        *)
            show_error "无效选择"
            return 1
            ;;
    esac

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -size "$size"
}

# 按时间查找
find_by_time() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    echo "请选择时间类型:"
    echo "1. 修改时间 (mtime)"
    echo "2. 访问时间 (atime)"
    echo "3. 状态改变时间 (ctime)"
    read -p "请选择 (1-3): " time_type_choice

    case $time_type_choice in
        1) time_option="-mtime" ;;
        2) time_option="-atime" ;;
        3) time_option="-ctime" ;;
        *)
            show_error "无效选择"
            return 1
            ;;
    esac

    echo "请选择时间范围:"
    echo "1. N天内修改过"
    echo "2. 超过N天未修改"
    echo "3. 正好N天前修改"
    read -p "请选择 (1-3): " time_range_choice

    case $time_range_choice in
        1) prefix="-" ;;
        2) prefix="+" ;;
        3) prefix="" ;;
        *)
            show_error "无效选择"
            return 1
            ;;
    esac

    read -p "请输入天数: " days
    if ! echo "$days" | grep -Eq '^[0-9]+$'; then
        show_error "天数必须是数字"
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" $time_option "$prefix$days"
}

# 按权限查找
find_by_permission() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    read -p "请输入权限数字 (如 755): " perm
    if ! validate_permission "$perm"; then
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -perm "$perm"
}

# 按所有者查找
find_by_owner() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    read -p "请输入用户名: " user
    if ! validate_user "$user"; then
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -user "$user"
}

# 按内容查找
find_by_content() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    read -p "请输入要查找的文字内容: " content
    if [ -z "$content" ]; then
        show_error "查找内容不能为空"
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"

    # 使用grep而不是find来查找文件内容
    local result=$(grep -r -l --include="*" "$content" "$directory" 2>/dev/null | head -n $RESULT_LIMIT)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo -e "${YELLOW}查找过程中出现错误${NC}"
        return 1
    fi

    local count=$(echo "$result" | wc -l)
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}未找到包含指定内容的文件${NC}"
        return 0
    fi

    echo "$result"
    return 0
}

# 按inode查找
find_by_inode() {
    read -p "请输入要查找的目录 (直接回车表示当前目录): " directory
    [ -z "$directory" ] && directory="."

    if ! validate_directory "$directory"; then
        return 1
    fi

    read -p "请输入inode号: " inode
    if ! echo "$inode" | grep -Eq '^[0-9]+$'; then
        show_error "inode号必须是数字"
        return 1
    fi

    echo -e "${BLUE}正在查找...${NC}"
    safe_find "$directory" -inum "$inode"
}

# 设置结果显示数量
set_result_limit() {
    read -p "请输入要显示的最大结果数量 (当前: $RESULT_LIMIT): " new_limit
    if echo "$new_limit" | grep -Eq '^[0-9]+$' && [ "$new_limit" -gt 0 ]; then
        RESULT_LIMIT=$new_limit
        echo -e "${GREEN}结果限制已设置为 $RESULT_LIMIT${NC}"
    else
        show_error "请输入有效的正数"
    fi
}

# 主菜单
main_menu() {
    echo -e "${GREEN}=== 文件查找工具 ===${NC}"
    echo ""
    echo "请选择查找方式:"
    echo "1. 按名称查找"
    echo "2. 按类型查找"
    echo "3. 按大小查找"
    echo "4. 按时间查找"
    echo "5. 按权限查找"
    echo "6. 按所有者查找"
    echo "7. 按内容查找"
    echo "8. 按inode查找"
    echo "9. 设置结果显示数量 (当前: $RESULT_LIMIT)"
    echo "10. 退出"
    echo ""
}

# 主循环
while true; do
    main_menu
    read -p "请输入选项 (1-10): " choice

    case $choice in
        1) find_by_name ;;
        2) find_by_type ;;
        3) find_by_size ;;
        4) find_by_time ;;
        5) find_by_permission ;;
        6) find_by_owner ;;
        7) find_by_content ;;
        8) find_by_inode ;;
        9) set_result_limit ;;
        10)
            echo -e "${GREEN}谢谢使用!${NC}"
            exit 0
            ;;
        *)
            show_error "无效选项，请重新选择"
            ;;
    esac

    echo ""
    read -p "按回车键返回菜单..."
    echo ""
done
