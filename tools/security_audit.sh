#!/bin/sh
# 企业级系统安全审计脚本 v3.9

# 初始化变量（优化临时目录权限）
REPORT_FILE="/tmp/security_audit_$(date +%Y%m%d_%H%M%S).txt"
TMP_DIR=$(mktemp -d -p /tmp 2>/dev/null || mkdir /tmp/sec_audit.XXXXXX)
chmod 700 "$TMP_DIR"
CONTAINER_ENV=0
critical_count=0
high_count=0
WSL_ENV=0
SCAP_ENABLED=0
ARM_ARCH=""

# 清理函数
cleanup() {
    rm -rf "$TMP_DIR"
    chmod 600 "$REPORT_FILE" 2>/dev/null
}
trap cleanup EXIT

# 飞腾架构检测优化（防止误判）
detect_ft_arch() {
    # 优先检查硬件OEM信息
    if [ -f "/sys/firmware/acpi/tables/FACP" ]; then
        oem_id=$(strings /sys/firmware/acpi/tables/FACP | grep -A1 OEMID | tail -1)
        oem_table=$(strings /sys/firmware/acpi/tables/FACP | grep -A1 "OEM Table ID" | tail -1)
        
        if echo "$oem_id" | grep -qiE "phytium|ft"; then
            ARM_ARCH="飞腾架构 [硬件验证: $oem_id/$oem_table]"
            return
        fi
    fi
    
    # 次选CPU信息检测
    cpu_info=$(awk -F: '/model name/{print tolower($0)}' /proc/cpuinfo 2>/dev/null)
    case "$cpu_info" in
        *phytium*|*ft-2000*|*ft-2500*|*ft-3000*|*s2500*)
            ARM_ARCH="飞腾架构" ;;
        *ft-*|*feiteng*) 
            # 二次验证防止误判NVIDIA显卡
            if ! echo "$cpu_info" | grep -qi "nvidia"; then
                ARM_ARCH="飞腾架构 [需验证]" 
            else
                ARM_ARCH="通用ARM64 [误判过滤]" 
            fi ;;
        *kunpeng*|*huawei*) ARM_ARCH="鲲鹏架构" ;;
        aarch64|armv8l) ARM_ARCH="通用ARM64" ;;
        "") ARM_ARCH="无法确定架构" ;;
        *) ARM_ARCH="检测为: $(awk -F: '/model name/{print $2}' /proc/cpuinfo | head -1 | cut -c -40)" ;;
    esac
}

# 达梦数据库服务检测（路径检测增强）
check_dmdb() {
    echo "==== 达梦数据库安全检查 ===="
    
    # 多路径查找（包含常见安装目录和bin变体）
    find_paths=(
        "/opt/dmdbms/bin/dmserver*"
        "/dm/bin/dmserver*"
        "/usr/local/dm/bin/dmserver*"
        "/home/dmdbms/bin/dmserver*"
    )
    
    DM_SERVER=""
    for path in "${find_paths[@]}"; do
        [ -z "$DM_SERVER" ] && DM_SERVER=$(find ${path%%\**} -path "$path" -type f -executable 2>/dev/null | head -1)
    done
    
    [ -z "$DM_SERVER" ] && DM_SERVER="/opt/dmdbms/bin/dmserver"
    DM_DIR="${DM_SERVER%/*}"
    
    # 获取服务状态
    if systemctl is-active dmserverd >/dev/null 2>&1 || pgrep -f dmserver >/dev/null; then
        echo "服务状态: 运行中 [路径: $DM_DIR]"
        
        # 安全配置检查
        disql_found=0
        for disql_cmd in "${DM_DIR}/disql" "${DM_DIR}/disql64" "${DM_DIR}/../bin/disql" "${DM_DIR}/../bin/disql64"; do
            if [ -x "$disql_cmd" ]; then
                echo "使用disql工具: $disql_cmd"
                # 非交互式命令执行（带超时防止卡死）
                timeout 5 bash -c "echo -e \"select * from v\\\$dm_ini where para_name='ENABLE_ENCRYPT';\nquit\" | \
                    \"$disql_cmd\" SYSDBA/SYSDBA 2>&1 | grep -E 'ENABLE_ENCRYPT|没有执行权限'" || \
                    echo "查询超时或失败（可能需要手动验证）"
                disql_found=1
                break
            fi
        done
        
        if [ "$disql_found" -eq 0 ]; then
            echo "警告: 未找到disql工具，尝试全局查找..."
            DISQL_PATH=$(find /opt /usr/local /dm /home -name disql* -type f -executable 2>/dev/null | head -1)
            if [ -n "$DISQL_PATH" ]; then
                timeout 5 bash -c "echo -e \"select * from v\\\$dm_ini where para_name='ENABLE_ENCRYPT';\nquit\" | \
                    \"$DISQL_PATH\" SYSDBA/SYSDBA 2>&1 | grep -E 'ENABLE_ENCRYPT|没有执行权限'" || \
                    echo "使用备选disql路径查询失败"
            else
                echo "严重: 无法找到disql工具，跳过数据库检查"
            fi
        fi
        
        # 配置文件检查
        echo -e "\n配置文件检查:"
        for ini_file in "${DM_DIR}/../dm.ini" "${DM_DIR}/../conf/dm.ini" "${DM_DIR}/../../config/dm.ini"; do
            if [ -f "$ini_file" ]; then
                echo "配置文件: $ini_file"
                grep -E 'ENABLE_ENCRYPT|PWD_POLICY' "$ini_file" 2>/dev/null || \
                    echo "未找到关键安全参数"
                break
            fi
        done
    else
        echo "服务状态: 未运行 [路径: $DM_DIR]"
        echo "警告: 数据库未运行时无法进行安全配置检查"
        echo "建议检查:"
        echo "1. 安装路径确认: $DM_DIR"
        echo "2. 服务状态: systemctl status dmserverd"
        echo "3. 进程状态: pgrep dmserver"
    fi
    
    echo "=========================="
}

# 检测WSL环境
detect_wsl() {
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        WSL_ENV=1
        echo "检测到Windows Subsystem for Linux (WSL)环境"
        return 0
    fi
    return 1
}

# 增强容器检测
detect_container() {
    # 在WSL环境中跳过容器检测
    [ "$WSL_ENV" -eq 1 ] && return 1
    
    # 标准容器检测
    [ -f /.dockerenv ] && return 0
    [ -f /run/.containerenv ] && return 0
    
    # 增强cgroup检测
    if grep -qi "docker\|kubepods\|containerd" /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # 检查namespace数量
    ns_count=$(ls -l /proc/1/ns 2>/dev/null | wc -l)
    if [ -n "$ns_count" ] && [ $ns_count -lt 6 ]; then
        return 0
    fi
    
    # 检查根文件系统类型
    root_fs=$(awk '$2 == "/" {print $3}' /proc/mounts 2>/dev/null)
    case $root_fs in
        overlay*|aufs) return 0 ;;
    esac
    
    return 1
}

# SCAP兼容性检查（带依赖验证）
check_scap() {
    # 检查OpenSCAP是否安装
    if ! cmd_exists oscap; then
        echo "OpenSCAP未安装，跳过SCAP检查"
        return 1
    fi
    
    echo "==== SCAP安全基线检查 ===="
    
    # 验证依赖包
    required_pkgs=("openscap" "scap-security-guide")
    missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1 && ! dpkg -l "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "缺失依赖包: ${missing_pkgs[*]}"
        return 1
    fi
    
    # 确定系统类型和对应的SCAP配置文件
    local scap_profile=""
    
    if [ -f "/etc/redhat-release" ]; then
        scap_profile="/usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml"
    elif [ -f "/etc/debian_version" ]; then
        scap_profile="/usr/share/xml/scap/ssg/content/ssg-debian10-ds.xml"
    elif grep -qi "kylin" /etc/os-release; then
        scap_profile="/usr/share/xml/scap/ssg/content/ssg-kylin-ds.xml"
    elif grep -qi "uos" /etc/os-release; then
        scap_profile="/usr/share/xml/scap/ssg/content/ssg-ubuntu1804-ds.xml"
    else
        echo "未找到系统对应的SCAP配置文件"
        return 1
    fi
    
    # 检查配置文件是否存在
    if [ ! -f "$scap_profile" ]; then
        echo "SCAP配置文件不存在: $scap_profile"
        # 尝试通用fallback
        alt_profile=$(find /usr/share/xml/scap/ssg/content -name "*.xml" | head -1)
        if [ -n "$alt_profile" ]; then
            echo "使用替代配置文件: $alt_profile"
            scap_profile="$alt_profile"
        else
            return 1
        fi
    fi
    
    # 执行SCAP扫描
    local scap_report="$TMP_DIR/scap_report.html"
    echo "使用配置文件: $scap_profile"
    echo "执行SCAP扫描(超时: 30分钟)..."
    
    # 根据可用资源选择配置文件
    local profile=""
    if oscap info "$scap_profile" | grep -q "pci-dss"; then
        profile="pci-dss"
    elif oscap info "$scap_profile" | grep -q "stig"; then
        profile="stig"
    else
        profile="standard"
    fi
    
    # 诊断文件
    local scap_diag="$TMP_DIR/scap_diag.log"
    
    # 执行扫描（带超时）
    timeout 1800 oscap xccdf eval --profile "$profile" --report "$scap_report" "$scap_profile" >"$scap_diag" 2>&1
    
    # 处理扫描结果
    oscap_exit=$?
    if [ $oscap_exit -eq 124 ]; then
        echo "SCAP扫描超时（30分钟），结果可能不完整"
        SCAP_ENABLED=0
    elif [ $oscap_exit -ne 0 ]; then
        echo "SCAP扫描失败 (退出码: $oscap_exit)"
        echo "诊断信息:"
        grep -iE "error|fail" "$scap_diag" | head -10
        return 1
    elif [ ! -s "$scap_report" ]; then
        echo "SCAP扫描未生成有效报告"
        return 1
    else
        echo "SCAP扫描完成，报告保存到: $scap_report"
        SCAP_ENABLED=1
        
        # 提取关键结果
        echo -e "\n关键发现:"
        grep -E "fail|error" "$scap_report" | head -5
    fi
    
    echo "=========================="
}

# WSL特定检查（Windows更新检测修复）
check_wsl_specific() {
    if [ "$WSL_ENV" -eq 0 ]; then
        return
    fi
    
    echo "==== WSL特定安全检查 ===="
    
    # 检查Windows互操作
    echo "Windows互操作状态:"
    if [ -f "/etc/wsl.conf" ]; then
        grep -E "interop.enabled" /etc/wsl.conf 2>/dev/null || echo "未配置互操作"
    else
        echo "未找到wsl.conf配置文件"
    fi
    
    # 检查WSL版本
    echo -e "\nWSL版本:"
    uname -r | grep -i "microsoft" || echo "非Microsoft内核"
    
    # 更可靠的Windows更新检测
    echo -e "\nWindows更新状态:"
    if cmd_exists wmic.exe; then
        echo "最后安装的Windows更新:"
        wmic.exe qfe list brief | tail -n +2 | head -3
    elif cmd_exists powershell.exe; then
        echo "最后安装的更新:"
        powershell.exe -Command "Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 3 InstalledOn,Description | Format-Table" \
            2>/dev/null || echo "无法获取更新信息"
    else
        echo "无法检测Windows更新状态（请手动运行Windows Update）"
    fi
    
    # 检查Windows Defender集成
    echo -e "\nWindows Defender状态:"
    if cmd_exists powershell.exe; then
        powershell.exe -Command "Get-MpComputerStatus | select AntivirusEnabled,AntispywareEnabled" 2>/dev/null || \
            echo "无法获取Defender状态"
    else
        echo "无法检测Defender状态"
    fi
    
    echo "========================"
}

# 风险计数逻辑优化（避免假阳性）
check_item() {
    local id="$1"
    local check_cmd="$2"
    local level="$3"
    local description="$4"
    local remediation="$5"
    local skip_non_root=${6:-0}
    local os_whitelist=${7:-}
    
    # 临时文件用于风险评估
    local check_output="$TMP_DIR/check_${id}.log"
    
    # 系统白名单检查
    if [ -n "$os_whitelist" ]; then
        local match=0
        for os in $os_whitelist; do
            if grep -qi "$os" /etc/os-release; then
                match=1
                break
            fi
        done
        
        if [ $match -eq 0 ]; then
            echo "[$id][$level] $description" >> "$REPORT_FILE"
            echo "系统不兼容 - 跳过检查 ($os_whitelist)" >> "$REPORT_FILE"
            echo -e "\n" >> "$REPORT_FILE"
            return
        fi
    fi
    
    # 非root用户跳过需要特权的检查
    if [ "$skip_non_root" -eq 1 ] && ! check_root; then
        echo "[$id][$level] $description" >> "$REPORT_FILE"
        echo "需要root权限 - 跳过检查" >> "$REPORT_FILE"
        echo -e "\n" >> "$REPORT_FILE"
        return
    fi
    
    # 容器环境跳过特定检查
    if [ "$CONTAINER_ENV" -eq 1 ]; then
        case $id in
            SYS-003|FS-008|FS-009|PATCH-*|SRV-005)
                echo "[$id][$level] $description" >> "$REPORT_FILE"
                echo "容器环境 - 跳过检查" >> "$REPORT_FILE"
                echo -e "\n" >> "$REPORT_FILE"
                return
                ;;
        esac
    fi

    # WSL环境跳过特定检查
    if [ "$WSL_ENV" -eq 1 ]; then
        case $id in
            SRV-005|PATCH-001|SYS-003)
                echo "[$id][$level] $description" >> "$REPORT_FILE"
                echo "WSL环境 - 跳过检查" >> "$REPORT_FILE"
                echo -e "\n" >> "$REPORT_FILE"
                return
                ;;
        esac
    fi

    echo "[$id][$level] $description" >> "$REPORT_FILE"
    echo "--------------------------------------------------" >> "$REPORT_FILE"
    [ -n "$remediation" ] && echo "修复建议: $remediation" >> "$REPORT_FILE"
    echo "检查命令: $check_cmd" >> "$REPORT_FILE"
    echo "输出结果:" >> "$REPORT_FILE"
    
    # 执行检查命令并捕获输出
    eval "$check_cmd" > "$check_output" 2>&1
    cat "$check_output" >> "$REPORT_FILE"
    
    # 风险分析（避免正常消息被误判）
    risk_found=0
    while IFS= read -r line; do
        # 关键风险模式匹配（排除已知正常输出）
        if echo "$line" | grep -qiE "(漏洞|风险|警告|失败|未通过|不安全|开启|禁用|未设置|禁止|暴露|未加固)|(NOT SECURE|NOT FOUND|DISABLED|OPEN|INSECURE|VULNERABLE)"; then
            # 排除假阳性关键词
            if ! echo "$line" | grep -qiE "未检测到|未启用|未找到|已设置|已关闭|已禁用|没有发现|无结果"; then
                risk_found=1
                break
            fi
        fi
    done < "$check_output"
    
    # 精确计数
    if [ $risk_found -eq 1 ]; then
        echo ">> 检测到潜在风险" >> "$REPORT_FILE"
        case $level in
            CRITICAL) critical_count=$((critical_count + 1)) ;;
            HIGH) high_count=$((high_count + 1)) ;;
        esac
    fi
    
    echo -e "\n\n" >> "$REPORT_FILE"
}

# 关键文件权限专项检查
check_key_permissions() {
    {
        echo "===== 关键文件权限数值验证 ====="
        echo "提示：此处显示详细的权限数值比较"
        echo
        check_permission /etc/passwd 644
        echo
        check_permission /etc/shadow 640
        echo
        check_permission /etc/gshadow 640
        echo
        check_permission /etc/sudoers 440
        echo
        [ -f "/etc/kylin-release" ] && check_permission /etc/kylin-release 600
        echo
        echo "其他关键文件:"
        ls -l /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers 2>/dev/null
        echo
        echo "================================="
        echo -e "\n"
    } >> "$REPORT_FILE"
}

# 国产系统更新检查增强
check_patch() {
    # ... (保持不变) ...
}

# 安全风险摘要功能增强
add_security_summary() {
    # ... (保持不变) ...
}

# === 主程序开始 ===
detect_wsl
detect_container && CONTAINER_ENV=1
detect_ft_arch

# 报告头（增加架构信息）
{
echo "===== 系统安全审计报告 ====="
echo "生成时间: $(date)"
echo "主机名: $(hostname)"
echo "操作系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -a)"
echo "内核版本: $(uname -r)"
echo "执行用户: $(id -un)"
[ -n "$ARM_ARCH" ] && echo "系统架构: $ARM_ARCH"
[ "$CONTAINER_ENV" -eq 1 ] && echo "环境: 容器（支持cgroupns host模式）"
[ "$WSL_ENV" -eq 1 ] && echo "环境: Windows Subsystem for Linux (WSL)"

# 显示国产系统发行版
if [ -f "/etc/kylin-release" ]; then
    echo "国产系统: 银河麒麟 $(cat /etc/kylin-release)"
elif grep -qi "uos" /etc/os-release; then
    echo "国产系统: 统信UOS $(grep VERSION /etc/os-release | cut -d= -f2 | tr -d '"')"
elif [ -f "/etc/neokylin-release" ]; then
    echo "国产系统: 中标麒麟 $(cat /etc/neokylin-release)"
fi

echo "审计标准: CIS Benchmark Level 1 + 国产化增强"
echo -e "\n"
} > "$REPORT_FILE"

# ==== 新增集成检查模块 ====
{
    # 达梦数据库安全检测（关键优化点）
    check_dmdb
    echo
    
    # LDAP/AD域集成检查
    check_domain
    echo
    
    # SCAP兼容性检查（带依赖验证）
    check_scap
    echo
    
    # WSL特定检查（Windows更新检测修复）
    check_wsl_specific
    echo
} >> "$REPORT_FILE"

# ==== 高危检查前置 ====
echo "===== [高危] 关键安全检查 ====" >> "$REPORT_FILE"

# ... (其余检查项保持不变，使用优化后的check_item) ...

# 结束报告
{
echo "===== 扫描完成 ====="
echo "报告文件: $REPORT_FILE"
[ "$SCAP_ENABLED" -eq 1 ] && echo "SCAP报告: $TMP_DIR/scap_report.html"
echo "文件大小: $(du -sh $REPORT_FILE | awk '{print $1}')"
echo "警告：此报告包含敏感信息，请妥善保管！"
echo "建议：根据报告中的修复建议进行安全加固"
} >> "$REPORT_FILE"

# 打印报告路径和摘要
echo "安全审计完成！报告已保存至: $REPORT_FILE"
[ "$SCAP_ENABLED" -eq 1 ] && echo "SCAP报告已保存至: $TMP_DIR/scap_report.html"
echo "系统架构: $ARM_ARCH"
echo "=== 安全风险摘要 ==="
grep -A10 "安全风险摘要" "$REPORT_FILE" | head -15
echo
echo "关键文件权限验证已包含在报告中"