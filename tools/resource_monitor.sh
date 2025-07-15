#!/bin/bash
# 支持: CentOS, Ubuntu, Kylin系统

VERSION="3.5.0"
CONFIG_FILE="/etc/resource_monitor.conf"
LOG_FILE="/var/log/resource_monitor.log"

# 初始化日志文件路径
init_log_file() {
    local alt_log="$HOME/resource_monitor.log"
    
    # 检查默认路径权限
    if touch "$LOG_FILE" 2>/dev/null; then
        # 默认路径可用
        return
    fi
    
    # 尝试创建日志目录
    local log_dir=$(dirname "$LOG_FILE")
    if mkdir -p "$log_dir" 2>/dev/null; then
        return
    fi
    
    # 使用备选路径
    LOG_FILE="$alt_log"
    echo -e "\033[1;33m警告: 使用备选日志路径: $LOG_FILE\033[0m"
}

# 初始化配置
init_config() {
    cat > $CONFIG_FILE <<- EOF
# 系统资源监控配置
THRESHOLD_CPU=85
THRESHOLD_MEM=85
THRESHOLD_DISK=85
THRESHOLD_NET=80
THRESHOLD_IO=80
EMAIL=""
CRON_SCHEDULE=""
MONITOR_PARTITIONS="/ /boot /home"
ALERT_COOLDOWN=3600
EOF
    chmod 644 $CONFIG_FILE
    echo -e "\033[1;32m配置文件已创建: $CONFIG_FILE\033[0m"
}

# 加载配置
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m配置文件不存在，创建默认配置...\033[0m"
        init_config
    fi
    source $CONFIG_FILE >/dev/null 2>&1 || {
        echo -e "\033[1;31m错误：配置文件加载失败！请检查格式\033[0m"
        exit 1
    }
}

# 保存配置
save_config() {
    cat > $CONFIG_FILE <<- EOF
# 系统资源监控配置
THRESHOLD_CPU=$THRESHOLD_CPU
THRESHOLD_MEM=$THRESHOLD_MEM
THRESHOLD_DISK=$THRESHOLD_DISK
THRESHOLD_NET=$THRESHOLD_NET
THRESHOLD_IO=$THRESHOLD_IO
EMAIL="$EMAIL"
CRON_SCHEDULE="$CRON_SCHEDULE"
MONITOR_PARTITIONS="$MONITOR_PARTITIONS"
ALERT_COOLDOWN=$ALERT_COOLDOWN
EOF
    echo -e "\033[1;32m配置已保存到 $CONFIG_FILE\033[0m"
}

# 检查命令是否存在
command_exists() {
    type "$1" &>/dev/null
}

# 日志记录函数 (增强磁盘满处理)
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color=""
    
    # 日志消息格式
    local log_entry="[$timestamp] [$level] $message"
    
    # 终端输出
    case $level in
        "INFO") color="\033[1;37m" ;;
        "WARN") color="\033[1;33m" ;;
        "ERROR") color="\033[1;31m" ;;
        "ALERT") color="\033[1;35m" ;;
        *) color="\033[0m" ;;
    esac
    
    echo -e "${color}${log_entry}\033[0m"
    
    # 磁盘空间检查 (避免磁盘满时写入失败)
    local log_dir=$(dirname "$LOG_FILE")
    local disk_usage=$(df -P "$log_dir" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    
    # 当磁盘使用率 > 95% 时启用保护模式
    if [[ -z "$disk_usage" ]] || [[ $disk_usage -ge 95 ]]; then
        # 内存日志缓冲 (最后30行)
        if ! [[ -v MEM_LOG_BUFFER ]]; then
            declare -g -a MEM_LOG_BUFFER
            # 尝试从文件加载现有日志
            if [[ -f "$LOG_FILE" ]]; then
                mapfile -t MEM_LOG_BUFFER < <(tail -30 "$LOG_FILE" 2>/dev/null)
            fi
        fi
        
        # 添加到内存缓冲 (保持最多30行)
        MEM_LOG_BUFFER+=("$log_entry")
        if [[ ${#MEM_LOG_BUFFER[@]} -gt 30 ]]; then
            MEM_LOG_BUFFER=("${MEM_LOG_BUFFER[@]:1}")
        fi
        
        # 每3条日志尝试写入一次 (优化Kylin刷新频率)
        if [[ $((${#MEM_LOG_BUFFER[@]} % 3)) -eq 0 ]]; then
            if [[ -z "$disk_usage" ]] || [[ $disk_usage -lt 99 ]]; then
                printf "%s\n" "${MEM_LOG_BUFFER[@]}" > "$LOG_FILE" 2>/dev/null && unset MEM_LOG_BUFFER
            fi
        fi
        
        # 特殊处理磁盘满警报
        if [[ "$message" == *"磁盘使用率过高"* ]]; then
            echo -e "\033[1;31m[紧急] 磁盘空间不足，日志使用内存缓冲! 请立即清理磁盘空间!\033[0m"
        fi
        return
    fi
    
    # 正常写入日志
    echo "$log_entry" >> "$LOG_FILE"
    
    # 如果存在内存缓冲，先写入缓冲内容
    if [[ -v MEM_LOG_BUFFER ]]; then
        printf "%s\n" "${MEM_LOG_BUFFER[@]}" >> "$LOG_FILE"
        unset MEM_LOG_BUFFER
    fi
}

# 获取系统信息
get_system_info() {
    echo -e "\n\033[1;34m================ 系统信息 ================\033[0m"
    
    # 获取发行版信息
    if [ -f /etc/os-release ]; then
        distro_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    elif [ -f /etc/centos-release ]; then
        distro_info=$(cat /etc/centos-release)
    elif [ -f /etc/kylin-release ]; then
        distro_info="Kylin $(cat /etc/kylin-release)"
    elif [ -f /etc/redhat-release ]; then
        distro_info=$(cat /etc/redhat-release)
    else
        distro_info=$(cat /etc/*release | head -n1 2>/dev/null || echo "Unknown OS")
    fi
    
    # 系统信息
    printf "\033[1;36m%-20s : \033[0m%s\n" "OS" "${distro_info:-无法获取}"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Hostname" "$(hostname)"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Kernel" "$(uname -r)"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Architecture" "$(uname -m)"
    
    # CPU信息
    if command_exists lscpu; then
        cpu_model=$(lscpu | grep 'Model name' | cut -d':' -f2 | sed 's/^ *//')
    else
        cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
    fi
    printf "\033[1;36m%-20s : \033[0m%s\n" "CPU Model" "$cpu_model"
    
    if command_exists nproc; then
        cpu_cores=$(nproc)
    else
        cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
    fi
    printf "\033[1;36m%-20s : \033[0m%s\n" "CPU Cores" "$cpu_cores"
    
    # 内存信息
    total_mem=$(grep MemTotal /proc/meminfo | awk '{printf "%.1fG", $2/1024/1024}')
    printf "\033[1;36m%-20s : \033[0m%s\n" "Memory" "${total_mem} Total"
    
    # Uptime信息
    if [ -f /proc/uptime ]; then
        uptime_raw=$(awk '{print $1}' /proc/uptime)
        days=$(awk -v t=$uptime_raw 'BEGIN {printf "%d", t/86400}')
        hours=$(awk -v t=$uptime_raw 'BEGIN {printf "%d", (t%86400)/3600}')
        printf "\033[1;36m%-20s : \033[0m%d天 %d小时\n" "Uptime" "$days" "$hours"
    else
        printf "\033[1;36m%-20s : \033[0m%s\n" "Uptime" "无法获取"
    fi
}

# 获取CPU使用率
get_cpu_usage() {
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total1=$((user+system+nice+idle+iowait+irq+softirq+steal))
    idle1=$((idle+iowait))
    
    sleep 1
    
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total2=$((user+system+nice+idle+iowait+irq+softirq+steal))
    idle2=$((idle+iowait))
    
    total=$((total2-total1))
    idle=$((idle2-idle1))
    
    if [[ $total -eq 0 ]]; then
        echo 0
    else
        echo $((100 - 100*idle/total))
    fi
}

# 获取内存使用率 (返回整数)
get_mem_usage() {
    total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available_mem=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    if [ -z "$total_mem" ] || [ -z "$available_mem" ] || [ "$total_mem" -eq 0 ]; then
        echo 0
        return
    fi
    
    used_mem=$((total_mem - available_mem))
    usage=$((used_mem * 100 / total_mem))
    
    echo $usage
}

# 获取磁盘使用率
get_disk_usage() {
    local partition=$1
    df -P "$partition" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%'
}

# 获取网络使用率
get_network_usage() {
    # 获取主要网络接口
    local interface="eth0"
    if [ -f /proc/net/route ]; then
        interface=$(awk '{if ($2 == "00000000") print $1}' /proc/net/route | head -1)
    fi
    
    # 检查接口是否存在
    if [ ! -d /sys/class/net/$interface ]; then
        echo 0
        return
    fi
    
    # 获取当前流量
    rx1=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)
    
    sleep 1
    
    # 获取1秒后流量
    rx2=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)
    
    # 计算速度 (字节/秒)
    rx_speed=$((rx2 - rx1))
    tx_speed=$((tx2 - tx1))
    
    # 转换为Mbps
    rx_mbps=$((rx_speed * 8 / 1000000))
    tx_mbps=$((tx_speed * 8 / 1000000))
    
    # 默认速度1000Mbps (1G)
    max_speed=1000
    
    # 尝试获取实际接口速度
    if [ -f /sys/class/net/$interface/speed ]; then
        speed=$(cat /sys/class/net/$interface/speed 2>/dev/null)
        [[ $speed =~ ^[0-9]+$ ]] && max_speed=$speed
    fi
    
    # 计算使用率
    local usage=$(( (rx_mbps > tx_mbps ? rx_mbps : tx_mbps) * 100 / max_speed ))
    
    # 确保使用率在0-100范围内
    if [[ $usage -gt 100 ]]; then
        echo 100
    elif [[ $usage -lt 0 ]]; then
        echo 0
    else
        echo $usage
    fi
}

# 获取磁盘IO使用率（增强虚拟化支持）
get_disk_io_usage() {
    local total_usage=0
    local count=0
    local virtual_env=0
    
    # 检测是否在虚拟化环境中运行
    if command_exists systemd-detect-virt; then
        if [ "$(systemd-detect-virt)" != "none" ]; then
            virtual_env=1
            log "INFO" "检测到虚拟化环境: $(systemd-detect-virt)"
        fi
    elif [ -f /proc/cpuinfo ] && grep -q "hypervisor" /proc/cpuinfo; then
        virtual_env=1
        log "INFO" "检测到虚拟化环境: 基于/proc/cpuinfo"
    fi
    
    # 获取所有磁盘设备
    disks=$(ls /sys/block/ 2>/dev/null | grep -E '^[sv]d[a-z]+$|^nvme\d+n\d+$|^mmcblk\d+$')
    
    for disk in $disks; do
        # 跳过只读设备
        [ -f /sys/block/$disk/ro ] && [ $(cat /sys/block/$disk/ro) -eq 1 ] && continue
        
        # 获取第一次统计
        local stats1
        stats1=$(grep "$disk " /proc/diskstats 2>/dev/null)
        [ -z "$stats1" ] && continue
        
        # 获取字段数量
        local num_fields=$(echo $stats1 | awk '{print NF}')
        
        # 根据字段数量决定读取哪些字段
        local read1 write1 iotime1
        read1=$(echo $stats1 | awk '{print $4}')    # 读完成次数
        write1=$(echo $stats1 | awk '{print $8}')   # 写完成次数
        iotime1=0
        
        # 虚拟化环境中字段可能不足
        if [ $num_fields -ge 14 ]; then
            iotime1=$(echo $stats1 | awk '{print $13}') # 设备繁忙时间(毫秒)
        elif [ $virtual_env -eq 1 ]; then
            log "WARN" "虚拟化环境中磁盘统计字段不足($num_fields)，使用IOPS估算"
        else
            log "WARN" "磁盘统计字段不足($num_fields)，使用IOPS估算"
        fi
        
        sleep 1
        
        # 获取第二次统计
        local stats2
        stats2=$(grep "$disk " /proc/diskstats 2>/dev/null)
        [ -z "$stats2" ] && continue
        
        # 获取第二次统计的字段
        local read2 write2 iotime2
        read2=$(echo $stats2 | awk '{print $4}')
        write2=$(echo $stats2 | awk '{print $8}')
        iotime2=0
        if [ $num_fields -ge 14 ]; then
            iotime2=$(echo $stats2 | awk '{print $13}')
        fi
        
        # 计算差值
        local io_diff=$(( (read2 - read1) + (write2 - write1) ))
        local time_diff=$((iotime2 - iotime1))
        
        # 计算使用率
        local disk_usage=0
        if [ $time_diff -gt 0 ]; then
            # 1000ms = 100% (因为采样间隔是1000ms)
            disk_usage=$((time_diff * 100 / 1000))
            [ $disk_usage -gt 100 ] && disk_usage=100
        elif [ $io_diff -gt 0 ]; then
            # 有IO操作但时间统计为0（某些虚拟设备）
            disk_usage=$((io_diff > 100 ? 100 : io_diff))
        fi
        
        total_usage=$((total_usage + disk_usage))
        count=$((count + 1))
    done
    
    if [[ $count -gt 0 ]]; then
        local avg_usage=$((total_usage / count))
        echo $avg_usage
    else
        echo 0
    fi
}

# 获取资源使用情况
get_resource_usage() {
    echo -e "\n\033[1;34m================ 资源使用情况 ================\033[0m"
    
    # CPU使用率
    cpu_usage=$(get_cpu_usage)
    if [[ $cpu_usage -gt ${THRESHOLD_CPU:-85} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "CPU Usage" "$cpu_usage"
    
    # 内存使用率
    mem_usage=$(get_mem_usage)
    if [[ $mem_usage -gt ${THRESHOLD_MEM:-85} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Memory Usage" "$mem_usage"
    
    # 磁盘使用率（多分区）
    echo -e "\033[1;36mDisk Usage:\033[0m"
    for partition in $MONITOR_PARTITIONS; do
        disk_usage=$(get_disk_usage "$partition")
        if [[ -z "$disk_usage" ]]; then
            printf "  %-15s : \033[1;33m分区不存在\033[0m\n" "$partition"
        else
            if [[ $disk_usage -gt ${THRESHOLD_DISK:-85} ]]; then
                color="\033[1;31m"
            else
                color="\033[1;32m"
            fi
            printf "  %-15s : ${color}%d%%\033[0m\n" "$partition" "$disk_usage"
        fi
    done
    
    # 网络使用率
    net_usage=$(get_network_usage)
    if [[ $net_usage -gt ${THRESHOLD_NET:-80} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Network Usage" "$net_usage"
    
    # 磁盘IO使用率
    io_usage=$(get_disk_io_usage)
    if [[ $io_usage -gt ${THRESHOLD_IO:-80} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Disk IO Usage" "$io_usage"
    
    # 添加负载信息
    if [ -f /proc/loadavg ]; then
        load=$(awk '{print $1,$2,$3}' /proc/loadavg)
        printf "\033[1;36m%-20s : \033[0m%s\n" "System Load" "$load (${cpu_cores:-?}核)"
    else
        printf "\033[1;36m%-20s : \033[0m%s\n" "System Load" "无法获取"
    fi
}

# 发送告警邮件 (增强SMTP支持)
send_alert() {
    local resource=$1
    local usage=$2
    local threshold=$3
    
    if [ -z "$EMAIL" ]; then
        log "WARN" "未配置邮箱，无法发送邮件告警"
        return 1
    fi
    
    local timestamp=$(date +%s)
    local last_alert=$(grep "ALERT:${resource}" $LOG_FILE 2>/dev/null | tail -1 | awk '{print $1,$2}')
    local last_timestamp=$(date -d "${last_alert}" +%s 2>/dev/null)
    
    # 检查冷却时间
    if [[ -n "$last_timestamp" && $((timestamp - last_timestamp)) -lt $ALERT_COOLDOWN ]]; then
        log "INFO" "邮件告警冷却中: ${resource} (${ALERT_COOLDOWN}秒内不再发送)"
        return 2
    fi
    
    local subject="[系统告警] ${resource}使用率过高 - $(hostname)"
    local message="告警时间: $(date +'%Y-%m-%d %H:%M:%S')\n"
    message+="主机名称: $(hostname)\n"
    message+="资源类型: ${resource}\n"
    message+="当前使用率: ${usage}%\n"
    message+="设定阈值: ${threshold}%\n\n"
    message+="系统信息:\n"
    message+="----------------------------------------\n"
    message+="操作系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || cat /etc/*release 2>/dev/null | head -n1)\n"
    message+="运行时长: $(awk -v t=$(awk '{print $1}' /proc/uptime) 'BEGIN {d=int(t/86400);h=int((t%86400)/3600); printf "%d天%d小时", d, h}')\n"
    
    if [ -f /proc/loadavg ]; then
        message+="系统负载: $(awk '{print $1,$2,$3}' /proc/loadavg)\n"
    fi
    
    message+="----------------------------------------\n"
    
    # 尝试多种邮件发送方式
    local mail_sent=0
    
    # 1. 尝试使用msmtp (支持多种协议和认证)
    if command_exists msmtp; then
        (
        echo "From: resource_monitor@$(hostname)"
        echo "To: $EMAIL"
        echo "Subject: $subject"
        echo ""
        echo -e "$message"
        ) | msmtp --read-recipients
        
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过msmtp)"
            mail_sent=1
        fi
    fi
    
    # 2. 尝试使用sendmail
    if [ $mail_sent -eq 0 ] && command_exists sendmail; then
        (
        echo "Subject: $subject"
        echo "To: $EMAIL"
        echo ""
        echo -e "$message"
        ) | sendmail -t
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过sendmail)"
            mail_sent=1
        fi
    fi
    
    # 3. 尝试使用mail命令
    if [ $mail_sent -eq 0 ] && command_exists mail; then
        echo -e "$message" | mail -s "$subject" "$EMAIL"
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过mail)"
            mail_sent=1
        fi
    fi
    
    # 如果都失败，提供详细配置指南
    if [ $mail_sent -eq 0 ]; then
        log "ERROR" "邮件发送失败! 解决方案:"
        log "ERROR" "1. 推荐安装配置msmtp (支持多协议):"
        log "ERROR" "   # 安装"
        log "ERROR" "   sudo yum install msmtp"
        log "ERROR" "   "
        log "ERROR" "   # 配置 ~/.msmtprc"
        log "ERROR" "   account default"
        log "ERROR" "   host your.smtp.server"
        log "ERROR" "   port 587"
        log "ERROR" "   tls on"
        log "ERROR" "   tls_starttls on"
        log "ERROR" "   auth on"
        log "ERROR" "   user your-email@domain.com"
        log "ERROR" "   password your-password"
        log "ERROR" "   from resource-monitor@$(hostname)"
        
        log "ERROR" "2. 或者配置本地邮件服务:"
        log "ERROR" "   sudo yum install postfix"
        log "ERROR" "   sudo systemctl enable --now postfix"
        
        log "ERROR" "3. 查看日志: $LOG_FILE"
        return 1
    fi
    
    return 0
}

# 用户友好的日志轮转
user_friendly_log_rotation() {
    local rotated_log="$1"
    
    # 尝试压缩
    if command_exists gzip; then
        gzip "$rotated_log" >/dev/null 2>&1 && {
            log "INFO" "日志已压缩: ${rotated_log}.gz"
            return
        }
    fi
    
    # 如果压缩失败，使用简单归档
    mv "$rotated_log" "${rotated_log}.archive" && \
    log "INFO" "日志归档: ${rotated_log}.archive"
}

# 日志轮转检查
check_log_rotation() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    # 检查日志目录权限
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -w "$log_dir" ]; then
        log "WARN" "日志目录不可写，跳过日志轮转"
        return
    fi
    
    local log_size=$(du -k "$LOG_FILE" | cut -f1)
    local disk_usage=$(df -P "$log_dir" | awk 'NR==2{print $5}' | tr -d '%')
    
    # 当日志超过10MB且磁盘空间>20%时进行轮转
    if [[ $log_size -gt 10240 ]] && [[ $disk_usage -lt 80 ]]; then
        local timestamp=$(date +%Y%m%d%H%M%S)
        local rotated_log="${LOG_FILE}.${timestamp}"
        
        # 尝试轮转
        if cp "$LOG_FILE" "$rotated_log" 2>/dev/null; then
            > "$LOG_FILE"
            log "INFO" "日志文件已轮转: $rotated_log"
            
            # 在后台执行用户友好的轮转处理
            (user_friendly_log_rotation "$rotated_log") &
        else
            log "WARN" "日志轮转失败，可能磁盘空间不足"
        fi
    fi
}

# 资源检查逻辑
check_resources() {
    # 检查日志轮转
    check_log_rotation
    
    load_config
    log "INFO" "开始系统资源检查"
    
    # 检查CPU
    cpu_usage=$(get_cpu_usage)
    if [[ -n "$THRESHOLD_CPU" && $cpu_usage -gt $THRESHOLD_CPU ]]; then
        log "ALERT" "CPU使用率过高: ${cpu_usage}% > ${THRESHOLD_CPU}%"
        send_alert "CPU" $cpu_usage $THRESHOLD_CPU
    fi
    
    # 检查内存 (使用整数比较)
    mem_usage=$(get_mem_usage)
    if [[ $mem_usage -gt ${THRESHOLD_MEM:-0} ]]; then
        log "ALERT" "内存使用率过高: ${mem_usage}% > ${THRESHOLD_MEM}%"
        send_alert "Memory" $mem_usage $THRESHOLD_MEM
    fi
    
    # 检查磁盘分区
    for partition in $MONITOR_PARTITIONS; do
        disk_usage=$(get_disk_usage "$partition")
        if [[ -n "$disk_usage" && $disk_usage -gt ${THRESHOLD_DISK:-0} ]]; then
            log "ALERT" "磁盘使用率过高[${partition}]: ${disk_usage}% > ${THRESHOLD_DISK}%"
            send_alert "Disk($partition)" $disk_usage $THRESHOLD_DISK
        fi
    done
    
    # 检查网络使用率
    net_usage=$(get_network_usage)
    if [[ -n "$THRESHOLD_NET" && $net_usage -gt $THRESHOLD_NET ]]; then
        log "ALERT" "网络使用率过高: ${net_usage}% > ${THRESHOLD_NET}%"
        send_alert "Network" $net_usage $THRESHOLD_NET
    fi
    
    # 检查磁盘IO使用率
    io_usage=$(get_disk_io_usage)
    if [[ -n "$THRESHOLD_IO" && $io_usage -gt $THRESHOLD_IO ]]; then
        log "ALERT" "磁盘IO使用率过高: ${io_usage}% > ${THRESHOLD_IO}%"
        send_alert "Disk IO" $io_usage $THRESHOLD_IO
    fi
    
    log "INFO" "资源检查完成"
}

# 验证阈值输入
validate_threshold() {
    local value=$1
    local type=$2
    
    if [[ -z "$value" ]]; then
        echo -e "\033[1;33m使用默认阈值配置\033[0m"
        return 1
    fi
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo -e "\033[1;31m错误：$type 必须为0-100之间的整数\033[0m"
        return 2
    fi
    
    if [[ $value -lt 0 || $value -gt 100 ]]; then
        echo -e "\033[1;31m错误：$type 必须为0-100之间的整数\033[0m"
        return 3
    fi
    
    return 0
}

# 配置定时任务
setup_cron() {
    load_config
    
    echo -e "\n\033[1;33m========== 配置定时监控任务 ==========\033[0m"
    echo "1) 每月 [示例: 每月1号 02:30]"
    echo "2) 每周 [示例: 每周日 03:00]"
    echo "3) 每日 [示例: 每天 04:00]"
    echo "4) 自定义cron表达式"
    echo -e "5) 返回主菜单\n"
    
    while true; do
        read -p "请选择(1-5): " schedule_type
        
        case $schedule_type in
            1)
                read -p "输入每月几号(1-31): " day
                while [[ ! "$day" =~ ^[0-9]+$ || $day -lt 1 || $day -gt 31 ]]; do
                    echo -e "\033[1;31m无效日期! 请输入1-31的整数\033[0m"
                    read -p "输入每月几号(1-31): " day
                done
                
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour $day * *"
                break
                ;;
            2)
                read -p "输入星期几(0-6, 0=周日): " weekday
                while [[ ! "$weekday" =~ ^[0-6]$ ]]; do
                    echo -e "\033[1;31m无效的星期! 请输入0-6(0代表周日)\033[0m"
                    read -p "输入星期几(0-6, 0=周日): " weekday
                done
                
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour * * $weekday"
                break
                ;;
            3)
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour * * *"
                break
                ;;
            4)
                read -p "输入完整cron表达式[分 时 日 月 周]: " CRON_SCHEDULE
                # 基本验证
                if [[ $(echo $CRON_SCHEDULE | wc -w) -lt 5 ]]; then
                    echo -e "\033[1;31m无效的cron表达式!\033[0m"
                    continue
                fi
                break
                ;;
            5)
                return
                ;;
            *)
                echo -e "\033[1;31m无效选择!\033[0m"
                ;;
        esac
    done
    
    # 保存配置
    save_config
    
    # 添加cron任务
    crontab -l > /tmp/crontab.tmp 2>/dev/null || true
    # 删除旧的任务
    sed -i "\|$(basename $0).*--check|d" /tmp/crontab.tmp
    
    # 添加新任务
    echo "$CRON_SCHEDULE $(realpath $0) --check >> $LOG_FILE 2>&1" >> /tmp/crontab.tmp
    
    # 安装crontab
    crontab /tmp/crontab.tmp
    rm -f /tmp/crontab.tmp
    
    echo -e "\n\033[1;32m定时任务已设置:\033[0m"
    echo "计划: $CRON_SCHEDULE"
    echo "命令: $(realpath $0) --check"
    echo -e "\n当前定时任务列表:"
    crontab -l 2>/dev/null || echo "无定时任务"
}

# 主配置界面
main_setup() {
    load_config
    
    echo -e "\n\033[1;36m======== 系统资源监控配置 v$VERSION ========\033[0m"
    
    # 获取邮箱
    while true; do
        read -p "请输入接收告警的邮箱 [$EMAIL]: " input_email
        if [[ -n "$input_email" ]]; then
            if [[ "$input_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                EMAIL="$input_email"
                break
            else
                echo -e "\033[1;31m无效的邮箱格式！\033[0m"
            fi
        elif [[ -n "$EMAIL" ]]; then
            break
        else
            echo -e "\033[1;33m告警邮箱是必需的配置项！\033[0m"
        fi
    done
    
    # 配置阈值
    echo -e "\n\033[1;37m配置告警阈值(1-100百分比):\033[0m"
    
    while true; do
        read -p "CPU使用率阈值(当前:${THRESHOLD_CPU}%) [85-90建议]: " th_cpu
        validate_threshold "$th_cpu" "CPU阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_cpu" ]] && THRESHOLD_CPU=$th_cpu
    
    while true; do
        read -p "内存使用率阈值(当前:${THRESHOLD_MEM}%) [85-90建议]: " th_mem
        validate_threshold "$th_mem" "内存阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_mem" ]] && THRESHOLD_MEM=$th_mem
    
    while true; do
        read -p "磁盘使用率阈值(当前:${THRESHOLD_DISK}%) [85-90建议]: " th_disk
        validate_threshold "$th_disk" "磁盘阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_disk" ]] && THRESHOLD_DISK=$th_disk
    
    while true; do
        read -p "网络使用率阈值(当前:${THRESHOLD_NET}%) [80-90建议]: " th_net
        validate_threshold "$th_net" "网络阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_net" ]] && THRESHOLD_NET=$th_net
    
    while true; do
        read -p "磁盘IO使用率阈值(当前:${THRESHOLD_IO}%) [80-90建议]: " th_io
        validate_threshold "$th_io" "IO阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_io" ]] && THRESHOLD_IO=$th_io
    
    # 配置监控分区
    read -p "输入要监控的磁盘分区(空格分隔) [$MONITOR_PARTITIONS]: " input_partitions
    if [[ -n "$input_partitions" ]]; then
        MONITOR_PARTITIONS="$input_partitions"
    fi
    
    # 配置告警冷却时间
    read -p "告警冷却时间(秒) [$ALERT_COOLDOWN]: " input_cooldown
    if [[ -n "$input_cooldown" && "$input_cooldown" =~ ^[0-9]+$ ]]; then
        ALERT_COOLDOWN=$input_cooldown
    fi
    
    # 保存配置
    save_config
    
    # 设置定时任务
    setup_cron
    
    # 测试邮件
    if [ -n "$EMAIL" ]; then
        echo -e "\n\033[1;37m发送测试邮件...\033[0m"
        send_alert "测试资源" "100" "99"
    fi
    
    echo -e "\n\033[1;42m 配置完成！监控服务已启动 \033[0m"
}

# 帮助信息
show_help() {
    echo -e "\033[1;36m系统资源监控脚本 v$VERSION\033[0m"
    echo "修复:"
    echo "  - Kylin系统bc依赖问题"
    echo "  - 非25端口SMTP支持"
    echo "  - 磁盘满日志处理"
    echo "  - 磁盘IO计算偏差"
    echo "  - 日志权限问题"
    echo "  - Kylin告警延时"
    echo "  - 虚拟化环境IO统计"
    echo "  - 用户级日志轮转"
    echo ""
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  --setup       初始配置向导"
    echo "  --check       执行资源检查"
    echo "  --report      显示系统信息和资源使用情况"
    echo "  --cron        配置定时任务"
    echo "  --help        显示帮助信息"
    echo ""
    echo "日志文件: $LOG_FILE"
}

# 主入口
init_log_file  # 初始化日志文件路径

case "$1" in
    "--setup")
        main_setup
        ;;
    "--check")
        check_resources
        ;;
    "--report")
        get_system_info
        get_resource_usage
        ;;
    "--cron")
        setup_cron
        ;;
    "--help")
        show_help
        ;;
    *)
        # 彩色标题
        echo -e "\n\033[1;35m    系统资源监控 v$VERSION    \033[0m"
        echo -e "\033[1;35m==============================\033[0m"
        
        get_system_info
        get_resource_usage
        echo -e "\n\033[1;33m提示: 使用 $0 --setup 进行完整配置"
        echo "提示: 使用 $0 --report 查看资源报告"
        echo -e "提示: 使用 $0 --help 查看帮助\033[0m"
        echo -e "\033[1;33m日志文件: $LOG_FILE\033[0m"
        ;;
esac

exit 0
#!/bin/bash

# 系统资源监控脚本 - 专业离线版
# 修复问题: 
#   1. bc依赖问题 (Kylin兼容)
#   2. SMTP非25端口支持
#   3. 磁盘满日志处理
#   4. 磁盘IO计算偏差问题
#   5. 日志权限问题
#   6. Kylin系统告警延时
#   7. 虚拟化环境IO统计异常
#   8. 用户级日志轮转
# 支持: CentOS, Ubuntu, Kylin, 麒麟系统

VERSION="3.5.0"
CONFIG_FILE="/etc/resource_monitor.conf"
LOG_FILE="/var/log/resource_monitor.log"

# 初始化日志文件路径
init_log_file() {
    local alt_log="$HOME/resource_monitor.log"
    
    # 检查默认路径权限
    if touch "$LOG_FILE" 2>/dev/null; then
        # 默认路径可用
        return
    fi
    
    # 尝试创建日志目录
    local log_dir=$(dirname "$LOG_FILE")
    if mkdir -p "$log_dir" 2>/dev/null; then
        return
    fi
    
    # 使用备选路径
    LOG_FILE="$alt_log"
    echo -e "\033[1;33m警告: 使用备选日志路径: $LOG_FILE\033[0m"
}

# 初始化配置
init_config() {
    cat > $CONFIG_FILE <<- EOF
# 系统资源监控配置
THRESHOLD_CPU=85
THRESHOLD_MEM=85
THRESHOLD_DISK=85
THRESHOLD_NET=80
THRESHOLD_IO=80
EMAIL=""
CRON_SCHEDULE=""
MONITOR_PARTITIONS="/ /boot /home"
ALERT_COOLDOWN=3600
EOF
    chmod 644 $CONFIG_FILE
    echo -e "\033[1;32m配置文件已创建: $CONFIG_FILE\033[0m"
}

# 加载配置
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m配置文件不存在，创建默认配置...\033[0m"
        init_config
    fi
    source $CONFIG_FILE >/dev/null 2>&1 || {
        echo -e "\033[1;31m错误：配置文件加载失败！请检查格式\033[0m"
        exit 1
    }
}

# 保存配置
save_config() {
    cat > $CONFIG_FILE <<- EOF
# 系统资源监控配置
THRESHOLD_CPU=$THRESHOLD_CPU
THRESHOLD_MEM=$THRESHOLD_MEM
THRESHOLD_DISK=$THRESHOLD_DISK
THRESHOLD_NET=$THRESHOLD_NET
THRESHOLD_IO=$THRESHOLD_IO
EMAIL="$EMAIL"
CRON_SCHEDULE="$CRON_SCHEDULE"
MONITOR_PARTITIONS="$MONITOR_PARTITIONS"
ALERT_COOLDOWN=$ALERT_COOLDOWN
EOF
    echo -e "\033[1;32m配置已保存到 $CONFIG_FILE\033[0m"
}

# 检查命令是否存在
command_exists() {
    type "$1" &>/dev/null
}

# 日志记录函数 (增强磁盘满处理)
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color=""
    
    # 日志消息格式
    local log_entry="[$timestamp] [$level] $message"
    
    # 终端输出
    case $level in
        "INFO") color="\033[1;37m" ;;
        "WARN") color="\033[1;33m" ;;
        "ERROR") color="\033[1;31m" ;;
        "ALERT") color="\033[1;35m" ;;
        *) color="\033[0m" ;;
    esac
    
    echo -e "${color}${log_entry}\033[0m"
    
    # 磁盘空间检查 (避免磁盘满时写入失败)
    local log_dir=$(dirname "$LOG_FILE")
    local disk_usage=$(df -P "$log_dir" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    
    # 当磁盘使用率 > 95% 时启用保护模式
    if [[ -z "$disk_usage" ]] || [[ $disk_usage -ge 95 ]]; then
        # 内存日志缓冲 (最后30行)
        if ! [[ -v MEM_LOG_BUFFER ]]; then
            declare -g -a MEM_LOG_BUFFER
            # 尝试从文件加载现有日志
            if [[ -f "$LOG_FILE" ]]; then
                mapfile -t MEM_LOG_BUFFER < <(tail -30 "$LOG_FILE" 2>/dev/null)
            fi
        fi
        
        # 添加到内存缓冲 (保持最多30行)
        MEM_LOG_BUFFER+=("$log_entry")
        if [[ ${#MEM_LOG_BUFFER[@]} -gt 30 ]]; then
            MEM_LOG_BUFFER=("${MEM_LOG_BUFFER[@]:1}")
        fi
        
        # 每3条日志尝试写入一次 (优化Kylin刷新频率)
        if [[ $((${#MEM_LOG_BUFFER[@]} % 3)) -eq 0 ]]; then
            if [[ -z "$disk_usage" ]] || [[ $disk_usage -lt 99 ]]; then
                printf "%s\n" "${MEM_LOG_BUFFER[@]}" > "$LOG_FILE" 2>/dev/null && unset MEM_LOG_BUFFER
            fi
        fi
        
        # 特殊处理磁盘满警报
        if [[ "$message" == *"磁盘使用率过高"* ]]; then
            echo -e "\033[1;31m[紧急] 磁盘空间不足，日志使用内存缓冲! 请立即清理磁盘空间!\033[0m"
        fi
        return
    fi
    
    # 正常写入日志
    echo "$log_entry" >> "$LOG_FILE"
    
    # 如果存在内存缓冲，先写入缓冲内容
    if [[ -v MEM_LOG_BUFFER ]]; then
        printf "%s\n" "${MEM_LOG_BUFFER[@]}" >> "$LOG_FILE"
        unset MEM_LOG_BUFFER
    fi
}

# 获取系统信息
get_system_info() {
    echo -e "\n\033[1;34m================ 系统信息 ================\033[0m"
    
    # 获取发行版信息
    if [ -f /etc/os-release ]; then
        distro_info=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    elif [ -f /etc/centos-release ]; then
        distro_info=$(cat /etc/centos-release)
    elif [ -f /etc/kylin-release ]; then
        distro_info="Kylin $(cat /etc/kylin-release)"
    elif [ -f /etc/redhat-release ]; then
        distro_info=$(cat /etc/redhat-release)
    else
        distro_info=$(cat /etc/*release | head -n1 2>/dev/null || echo "Unknown OS")
    fi
    
    # 系统信息
    printf "\033[1;36m%-20s : \033[0m%s\n" "OS" "${distro_info:-无法获取}"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Hostname" "$(hostname)"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Kernel" "$(uname -r)"
    printf "\033[1;36m%-20s : \033[0m%s\n" "Architecture" "$(uname -m)"
    
    # CPU信息
    if command_exists lscpu; then
        cpu_model=$(lscpu | grep 'Model name' | cut -d':' -f2 | sed 's/^ *//')
    else
        cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
    fi
    printf "\033[1;36m%-20s : \033[0m%s\n" "CPU Model" "$cpu_model"
    
    if command_exists nproc; then
        cpu_cores=$(nproc)
    else
        cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
    fi
    printf "\033[1;36m%-20s : \033[0m%s\n" "CPU Cores" "$cpu_cores"
    
    # 内存信息
    total_mem=$(grep MemTotal /proc/meminfo | awk '{printf "%.1fG", $2/1024/1024}')
    printf "\033[1;36m%-20s : \033[0m%s\n" "Memory" "${total_mem} Total"
    
    # Uptime信息
    if [ -f /proc/uptime ]; then
        uptime_raw=$(awk '{print $1}' /proc/uptime)
        days=$(awk -v t=$uptime_raw 'BEGIN {printf "%d", t/86400}')
        hours=$(awk -v t=$uptime_raw 'BEGIN {printf "%d", (t%86400)/3600}')
        printf "\033[1;36m%-20s : \033[0m%d天 %d小时\n" "Uptime" "$days" "$hours"
    else
        printf "\033[1;36m%-20s : \033[0m%s\n" "Uptime" "无法获取"
    fi
}

# 获取CPU使用率
get_cpu_usage() {
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total1=$((user+system+nice+idle+iowait+irq+softirq+steal))
    idle1=$((idle+iowait))
    
    sleep 1
    
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    total2=$((user+system+nice+idle+iowait+irq+softirq+steal))
    idle2=$((idle+iowait))
    
    total=$((total2-total1))
    idle=$((idle2-idle1))
    
    if [[ $total -eq 0 ]]; then
        echo 0
    else
        echo $((100 - 100*idle/total))
    fi
}

# 获取内存使用率 (返回整数)
get_mem_usage() {
    total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    available_mem=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    if [ -z "$total_mem" ] || [ -z "$available_mem" ] || [ "$total_mem" -eq 0 ]; then
        echo 0
        return
    fi
    
    used_mem=$((total_mem - available_mem))
    usage=$((used_mem * 100 / total_mem))
    
    echo $usage
}

# 获取磁盘使用率
get_disk_usage() {
    local partition=$1
    df -P "$partition" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%'
}

# 获取网络使用率
get_network_usage() {
    # 获取主要网络接口
    local interface="eth0"
    if [ -f /proc/net/route ]; then
        interface=$(awk '{if ($2 == "00000000") print $1}' /proc/net/route | head -1)
    fi
    
    # 检查接口是否存在
    if [ ! -d /sys/class/net/$interface ]; then
        echo 0
        return
    fi
    
    # 获取当前流量
    rx1=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx1=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)
    
    sleep 1
    
    # 获取1秒后流量
    rx2=$(cat /sys/class/net/$interface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx2=$(cat /sys/class/net/$interface/statistics/tx_bytes 2>/dev/null || echo 0)
    
    # 计算速度 (字节/秒)
    rx_speed=$((rx2 - rx1))
    tx_speed=$((tx2 - tx1))
    
    # 转换为Mbps
    rx_mbps=$((rx_speed * 8 / 1000000))
    tx_mbps=$((tx_speed * 8 / 1000000))
    
    # 默认速度1000Mbps (1G)
    max_speed=1000
    
    # 尝试获取实际接口速度
    if [ -f /sys/class/net/$interface/speed ]; then
        speed=$(cat /sys/class/net/$interface/speed 2>/dev/null)
        [[ $speed =~ ^[0-9]+$ ]] && max_speed=$speed
    fi
    
    # 计算使用率
    local usage=$(( (rx_mbps > tx_mbps ? rx_mbps : tx_mbps) * 100 / max_speed ))
    
    # 确保使用率在0-100范围内
    if [[ $usage -gt 100 ]]; then
        echo 100
    elif [[ $usage -lt 0 ]]; then
        echo 0
    else
        echo $usage
    fi
}

# 获取磁盘IO使用率（增强虚拟化支持）
get_disk_io_usage() {
    local total_usage=0
    local count=0
    local virtual_env=0
    
    # 检测是否在虚拟化环境中运行
    if command_exists systemd-detect-virt; then
        if [ "$(systemd-detect-virt)" != "none" ]; then
            virtual_env=1
            log "INFO" "检测到虚拟化环境: $(systemd-detect-virt)"
        fi
    elif [ -f /proc/cpuinfo ] && grep -q "hypervisor" /proc/cpuinfo; then
        virtual_env=1
        log "INFO" "检测到虚拟化环境: 基于/proc/cpuinfo"
    fi
    
    # 获取所有磁盘设备
    disks=$(ls /sys/block/ 2>/dev/null | grep -E '^[sv]d[a-z]+$|^nvme\d+n\d+$|^mmcblk\d+$')
    
    for disk in $disks; do
        # 跳过只读设备
        [ -f /sys/block/$disk/ro ] && [ $(cat /sys/block/$disk/ro) -eq 1 ] && continue
        
        # 获取第一次统计
        local stats1
        stats1=$(grep "$disk " /proc/diskstats 2>/dev/null)
        [ -z "$stats1" ] && continue
        
        # 获取字段数量
        local num_fields=$(echo $stats1 | awk '{print NF}')
        
        # 根据字段数量决定读取哪些字段
        local read1 write1 iotime1
        read1=$(echo $stats1 | awk '{print $4}')    # 读完成次数
        write1=$(echo $stats1 | awk '{print $8}')   # 写完成次数
        iotime1=0
        
        # 虚拟化环境中字段可能不足
        if [ $num_fields -ge 14 ]; then
            iotime1=$(echo $stats1 | awk '{print $13}') # 设备繁忙时间(毫秒)
        elif [ $virtual_env -eq 1 ]; then
            log "WARN" "虚拟化环境中磁盘统计字段不足($num_fields)，使用IOPS估算"
        else
            log "WARN" "磁盘统计字段不足($num_fields)，使用IOPS估算"
        fi
        
        sleep 1
        
        # 获取第二次统计
        local stats2
        stats2=$(grep "$disk " /proc/diskstats 2>/dev/null)
        [ -z "$stats2" ] && continue
        
        # 获取第二次统计的字段
        local read2 write2 iotime2
        read2=$(echo $stats2 | awk '{print $4}')
        write2=$(echo $stats2 | awk '{print $8}')
        iotime2=0
        if [ $num_fields -ge 14 ]; then
            iotime2=$(echo $stats2 | awk '{print $13}')
        fi
        
        # 计算差值
        local io_diff=$(( (read2 - read1) + (write2 - write1) ))
        local time_diff=$((iotime2 - iotime1))
        
        # 计算使用率
        local disk_usage=0
        if [ $time_diff -gt 0 ]; then
            # 1000ms = 100% (因为采样间隔是1000ms)
            disk_usage=$((time_diff * 100 / 1000))
            [ $disk_usage -gt 100 ] && disk_usage=100
        elif [ $io_diff -gt 0 ]; then
            # 有IO操作但时间统计为0（某些虚拟设备）
            disk_usage=$((io_diff > 100 ? 100 : io_diff))
        fi
        
        total_usage=$((total_usage + disk_usage))
        count=$((count + 1))
    done
    
    if [[ $count -gt 0 ]]; then
        local avg_usage=$((total_usage / count))
        echo $avg_usage
    else
        echo 0
    fi
}

# 获取资源使用情况
get_resource_usage() {
    echo -e "\n\033[1;34m================ 资源使用情况 ================\033[0m"
    
    # CPU使用率
    cpu_usage=$(get_cpu_usage)
    if [[ $cpu_usage -gt ${THRESHOLD_CPU:-85} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "CPU Usage" "$cpu_usage"
    
    # 内存使用率
    mem_usage=$(get_mem_usage)
    if [[ $mem_usage -gt ${THRESHOLD_MEM:-85} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Memory Usage" "$mem_usage"
    
    # 磁盘使用率（多分区）
    echo -e "\033[1;36mDisk Usage:\033[0m"
    for partition in $MONITOR_PARTITIONS; do
        disk_usage=$(get_disk_usage "$partition")
        if [[ -z "$disk_usage" ]]; then
            printf "  %-15s : \033[1;33m分区不存在\033[0m\n" "$partition"
        else
            if [[ $disk_usage -gt ${THRESHOLD_DISK:-85} ]]; then
                color="\033[1;31m"
            else
                color="\033[1;32m"
            fi
            printf "  %-15s : ${color}%d%%\033[0m\n" "$partition" "$disk_usage"
        fi
    done
    
    # 网络使用率
    net_usage=$(get_network_usage)
    if [[ $net_usage -gt ${THRESHOLD_NET:-80} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Network Usage" "$net_usage"
    
    # 磁盘IO使用率
    io_usage=$(get_disk_io_usage)
    if [[ $io_usage -gt ${THRESHOLD_IO:-80} ]]; then
        color="\033[1;31m"
    else
        color="\033[1;32m"
    fi
    printf "\033[1;36m%-20s : ${color}%d%%\033[0m\n" "Disk IO Usage" "$io_usage"
    
    # 添加负载信息
    if [ -f /proc/loadavg ]; then
        load=$(awk '{print $1,$2,$3}' /proc/loadavg)
        printf "\033[1;36m%-20s : \033[0m%s\n" "System Load" "$load (${cpu_cores:-?}核)"
    else
        printf "\033[1;36m%-20s : \033[0m%s\n" "System Load" "无法获取"
    fi
}

# 发送告警邮件 (增强SMTP支持)
send_alert() {
    local resource=$1
    local usage=$2
    local threshold=$3
    
    if [ -z "$EMAIL" ]; then
        log "WARN" "未配置邮箱，无法发送邮件告警"
        return 1
    fi
    
    local timestamp=$(date +%s)
    local last_alert=$(grep "ALERT:${resource}" $LOG_FILE 2>/dev/null | tail -1 | awk '{print $1,$2}')
    local last_timestamp=$(date -d "${last_alert}" +%s 2>/dev/null)
    
    # 检查冷却时间
    if [[ -n "$last_timestamp" && $((timestamp - last_timestamp)) -lt $ALERT_COOLDOWN ]]; then
        log "INFO" "邮件告警冷却中: ${resource} (${ALERT_COOLDOWN}秒内不再发送)"
        return 2
    fi
    
    local subject="[系统告警] ${resource}使用率过高 - $(hostname)"
    local message="告警时间: $(date +'%Y-%m-%d %H:%M:%S')\n"
    message+="主机名称: $(hostname)\n"
    message+="资源类型: ${resource}\n"
    message+="当前使用率: ${usage}%\n"
    message+="设定阈值: ${threshold}%\n\n"
    message+="系统信息:\n"
    message+="----------------------------------------\n"
    message+="操作系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || cat /etc/*release 2>/dev/null | head -n1)\n"
    message+="运行时长: $(awk -v t=$(awk '{print $1}' /proc/uptime) 'BEGIN {d=int(t/86400);h=int((t%86400)/3600); printf "%d天%d小时", d, h}')\n"
    
    if [ -f /proc/loadavg ]; then
        message+="系统负载: $(awk '{print $1,$2,$3}' /proc/loadavg)\n"
    fi
    
    message+="----------------------------------------\n"
    
    # 尝试多种邮件发送方式
    local mail_sent=0
    
    # 1. 尝试使用msmtp (支持多种协议和认证)
    if command_exists msmtp; then
        (
        echo "From: resource_monitor@$(hostname)"
        echo "To: $EMAIL"
        echo "Subject: $subject"
        echo ""
        echo -e "$message"
        ) | msmtp --read-recipients
        
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过msmtp)"
            mail_sent=1
        fi
    fi
    
    # 2. 尝试使用sendmail
    if [ $mail_sent -eq 0 ] && command_exists sendmail; then
        (
        echo "Subject: $subject"
        echo "To: $EMAIL"
        echo ""
        echo -e "$message"
        ) | sendmail -t
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过sendmail)"
            mail_sent=1
        fi
    fi
    
    # 3. 尝试使用mail命令
    if [ $mail_sent -eq 0 ] && command_exists mail; then
        echo -e "$message" | mail -s "$subject" "$EMAIL"
        if [ $? -eq 0 ]; then
            log "ALERT" "邮件告警已发送: ${resource} ${usage}% > ${threshold}% (通过mail)"
            mail_sent=1
        fi
    fi
    
    # 如果都失败，提供详细配置指南
    if [ $mail_sent -eq 0 ]; then
        log "ERROR" "邮件发送失败! 解决方案:"
        log "ERROR" "1. 推荐安装配置msmtp (支持多协议):"
        log "ERROR" "   # 安装"
        log "ERROR" "   sudo yum install msmtp"
        log "ERROR" "   "
        log "ERROR" "   # 配置 ~/.msmtprc"
        log "ERROR" "   account default"
        log "ERROR" "   host your.smtp.server"
        log "ERROR" "   port 587"
        log "ERROR" "   tls on"
        log "ERROR" "   tls_starttls on"
        log "ERROR" "   auth on"
        log "ERROR" "   user your-email@domain.com"
        log "ERROR" "   password your-password"
        log "ERROR" "   from resource-monitor@$(hostname)"
        
        log "ERROR" "2. 或者配置本地邮件服务:"
        log "ERROR" "   sudo yum install postfix"
        log "ERROR" "   sudo systemctl enable --now postfix"
        
        log "ERROR" "3. 查看日志: $LOG_FILE"
        return 1
    fi
    
    return 0
}

# 用户友好的日志轮转
user_friendly_log_rotation() {
    local rotated_log="$1"
    
    # 尝试压缩
    if command_exists gzip; then
        gzip "$rotated_log" >/dev/null 2>&1 && {
            log "INFO" "日志已压缩: ${rotated_log}.gz"
            return
        }
    fi
    
    # 如果压缩失败，使用简单归档
    mv "$rotated_log" "${rotated_log}.archive" && \
    log "INFO" "日志归档: ${rotated_log}.archive"
}

# 日志轮转检查
check_log_rotation() {
    [[ ! -f "$LOG_FILE" ]] && return
    
    # 检查日志目录权限
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -w "$log_dir" ]; then
        log "WARN" "日志目录不可写，跳过日志轮转"
        return
    fi
    
    local log_size=$(du -k "$LOG_FILE" | cut -f1)
    local disk_usage=$(df -P "$log_dir" | awk 'NR==2{print $5}' | tr -d '%')
    
    # 当日志超过10MB且磁盘空间>20%时进行轮转
    if [[ $log_size -gt 10240 ]] && [[ $disk_usage -lt 80 ]]; then
        local timestamp=$(date +%Y%m%d%H%M%S)
        local rotated_log="${LOG_FILE}.${timestamp}"
        
        # 尝试轮转
        if cp "$LOG_FILE" "$rotated_log" 2>/dev/null; then
            > "$LOG_FILE"
            log "INFO" "日志文件已轮转: $rotated_log"
            
            # 在后台执行用户友好的轮转处理
            (user_friendly_log_rotation "$rotated_log") &
        else
            log "WARN" "日志轮转失败，可能磁盘空间不足"
        fi
    fi
}

# 资源检查逻辑
check_resources() {
    # 检查日志轮转
    check_log_rotation
    
    load_config
    log "INFO" "开始系统资源检查"
    
    # 检查CPU
    cpu_usage=$(get_cpu_usage)
    if [[ -n "$THRESHOLD_CPU" && $cpu_usage -gt $THRESHOLD_CPU ]]; then
        log "ALERT" "CPU使用率过高: ${cpu_usage}% > ${THRESHOLD_CPU}%"
        send_alert "CPU" $cpu_usage $THRESHOLD_CPU
    fi
    
    # 检查内存 (使用整数比较)
    mem_usage=$(get_mem_usage)
    if [[ $mem_usage -gt ${THRESHOLD_MEM:-0} ]]; then
        log "ALERT" "内存使用率过高: ${mem_usage}% > ${THRESHOLD_MEM}%"
        send_alert "Memory" $mem_usage $THRESHOLD_MEM
    fi
    
    # 检查磁盘分区
    for partition in $MONITOR_PARTITIONS; do
        disk_usage=$(get_disk_usage "$partition")
        if [[ -n "$disk_usage" && $disk_usage -gt ${THRESHOLD_DISK:-0} ]]; then
            log "ALERT" "磁盘使用率过高[${partition}]: ${disk_usage}% > ${THRESHOLD_DISK}%"
            send_alert "Disk($partition)" $disk_usage $THRESHOLD_DISK
        fi
    done
    
    # 检查网络使用率
    net_usage=$(get_network_usage)
    if [[ -n "$THRESHOLD_NET" && $net_usage -gt $THRESHOLD_NET ]]; then
        log "ALERT" "网络使用率过高: ${net_usage}% > ${THRESHOLD_NET}%"
        send_alert "Network" $net_usage $THRESHOLD_NET
    fi
    
    # 检查磁盘IO使用率
    io_usage=$(get_disk_io_usage)
    if [[ -n "$THRESHOLD_IO" && $io_usage -gt $THRESHOLD_IO ]]; then
        log "ALERT" "磁盘IO使用率过高: ${io_usage}% > ${THRESHOLD_IO}%"
        send_alert "Disk IO" $io_usage $THRESHOLD_IO
    fi
    
    log "INFO" "资源检查完成"
}

# 验证阈值输入
validate_threshold() {
    local value=$1
    local type=$2
    
    if [[ -z "$value" ]]; then
        echo -e "\033[1;33m使用默认阈值配置\033[0m"
        return 1
    fi
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo -e "\033[1;31m错误：$type 必须为0-100之间的整数\033[0m"
        return 2
    fi
    
    if [[ $value -lt 0 || $value -gt 100 ]]; then
        echo -e "\033[1;31m错误：$type 必须为0-100之间的整数\033[0m"
        return 3
    fi
    
    return 0
}

# 配置定时任务
setup_cron() {
    load_config
    
    echo -e "\n\033[1;33m========== 配置定时监控任务 ==========\033[0m"
    echo "1) 每月 [示例: 每月1号 02:30]"
    echo "2) 每周 [示例: 每周日 03:00]"
    echo "3) 每日 [示例: 每天 04:00]"
    echo "4) 自定义cron表达式"
    echo -e "5) 返回主菜单\n"
    
    while true; do
        read -p "请选择(1-5): " schedule_type
        
        case $schedule_type in
            1)
                read -p "输入每月几号(1-31): " day
                while [[ ! "$day" =~ ^[0-9]+$ || $day -lt 1 || $day -gt 31 ]]; do
                    echo -e "\033[1;31m无效日期! 请输入1-31的整数\033[0m"
                    read -p "输入每月几号(1-31): " day
                done
                
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour $day * *"
                break
                ;;
            2)
                read -p "输入星期几(0-6, 0=周日): " weekday
                while [[ ! "$weekday" =~ ^[0-6]$ ]]; do
                    echo -e "\033[1;31m无效的星期! 请输入0-6(0代表周日)\033[0m"
                    read -p "输入星期几(0-6, 0=周日): " weekday
                done
                
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour * * $weekday"
                break
                ;;
            3)
                read -p "输入时间(HH:MM): " time
                while [[ ! "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; do
                    echo -e "\033[1;31m无效时间格式! 请输入HH:MM格式\033[0m"
                    read -p "输入时间(HH:MM): " time
                done
                
                hour=${time%%:*}
                minute=${time##*:}
                CRON_SCHEDULE="$minute $hour * * *"
                break
                ;;
            4)
                read -p "输入完整cron表达式[分 时 日 月 周]: " CRON_SCHEDULE
                # 基本验证
                if [[ $(echo $CRON_SCHEDULE | wc -w) -lt 5 ]]; then
                    echo -e "\033[1;31m无效的cron表达式!\033[0m"
                    continue
                fi
                break
                ;;
            5)
                return
                ;;
            *)
                echo -e "\033[1;31m无效选择!\033[0m"
                ;;
        esac
    done
    
    # 保存配置
    save_config
    
    # 添加cron任务
    crontab -l > /tmp/crontab.tmp 2>/dev/null || true
    # 删除旧的任务
    sed -i "\|$(basename $0).*--check|d" /tmp/crontab.tmp
    
    # 添加新任务
    echo "$CRON_SCHEDULE $(realpath $0) --check >> $LOG_FILE 2>&1" >> /tmp/crontab.tmp
    
    # 安装crontab
    crontab /tmp/crontab.tmp
    rm -f /tmp/crontab.tmp
    
    echo -e "\n\033[1;32m定时任务已设置:\033[0m"
    echo "计划: $CRON_SCHEDULE"
    echo "命令: $(realpath $0) --check"
    echo -e "\n当前定时任务列表:"
    crontab -l 2>/dev/null || echo "无定时任务"
}

# 主配置界面
main_setup() {
    load_config
    
    echo -e "\n\033[1;36m======== 系统资源监控配置 v$VERSION ========\033[0m"
    
    # 获取邮箱
    while true; do
        read -p "请输入接收告警的邮箱 [$EMAIL]: " input_email
        if [[ -n "$input_email" ]]; then
            if [[ "$input_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                EMAIL="$input_email"
                break
            else
                echo -e "\033[1;31m无效的邮箱格式！\033[0m"
            fi
        elif [[ -n "$EMAIL" ]]; then
            break
        else
            echo -e "\033[1;33m告警邮箱是必需的配置项！\033[0m"
        fi
    done
    
    # 配置阈值
    echo -e "\n\033[1;37m配置告警阈值(1-100百分比):\033[0m"
    
    while true; do
        read -p "CPU使用率阈值(当前:${THRESHOLD_CPU}%) [85-90建议]: " th_cpu
        validate_threshold "$th_cpu" "CPU阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_cpu" ]] && THRESHOLD_CPU=$th_cpu
    
    while true; do
        read -p "内存使用率阈值(当前:${THRESHOLD_MEM}%) [85-90建议]: " th_mem
        validate_threshold "$th_mem" "内存阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_mem" ]] && THRESHOLD_MEM=$th_mem
    
    while true; do
        read -p "磁盘使用率阈值(当前:${THRESHOLD_DISK}%) [85-90建议]: " th_disk
        validate_threshold "$th_disk" "磁盘阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_disk" ]] && THRESHOLD_DISK=$th_disk
    
    while true; do
        read -p "网络使用率阈值(当前:${THRESHOLD_NET}%) [80-90建议]: " th_net
        validate_threshold "$th_net" "网络阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_net" ]] && THRESHOLD_NET=$th_net
    
    while true; do
        read -p "磁盘IO使用率阈值(当前:${THRESHOLD_IO}%) [80-90建议]: " th_io
        validate_threshold "$th_io" "IO阈值"
        [[ $? -eq 0 || $? -eq 1 ]] && break
    done
    [[ -n "$th_io" ]] && THRESHOLD_IO=$th_io
    
    # 配置监控分区
    read -p "输入要监控的磁盘分区(空格分隔) [$MONITOR_PARTITIONS]: " input_partitions
    if [[ -n "$input_partitions" ]]; then
        MONITOR_PARTITIONS="$input_partitions"
    fi
    
    # 配置告警冷却时间
    read -p "告警冷却时间(秒) [$ALERT_COOLDOWN]: " input_cooldown
    if [[ -n "$input_cooldown" && "$input_cooldown" =~ ^[0-9]+$ ]]; then
        ALERT_COOLDOWN=$input_cooldown
    fi
    
    # 保存配置
    save_config
    
    # 设置定时任务
    setup_cron
    
    # 测试邮件
    if [ -n "$EMAIL" ]; then
        echo -e "\n\033[1;37m发送测试邮件...\033[0m"
        send_alert "测试资源" "100" "99"
    fi
    
    echo -e "\n\033[1;42m 配置完成！监控服务已启动 \033[0m"
}

# 帮助信息
show_help() {
    echo -e "\033[1;36m系统资源监控脚本 v$VERSION\033[0m"
    echo "修复:"
    echo "  - Kylin系统bc依赖问题"
    echo "  - 非25端口SMTP支持"
    echo "  - 磁盘满日志处理"
    echo "  - 磁盘IO计算偏差"
    echo "  - 日志权限问题"
    echo "  - Kylin告警延时"
    echo "  - 虚拟化环境IO统计"
    echo "  - 用户级日志轮转"
    echo ""
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  --setup       初始配置向导"
    echo "  --check       执行资源检查"
    echo "  --report      显示系统信息和资源使用情况"
    echo "  --cron        配置定时任务"
    echo "  --help        显示帮助信息"
    echo ""
    echo "日志文件: $LOG_FILE"
}

# 主入口
init_log_file  # 初始化日志文件路径

case "$1" in
    "--setup")
        main_setup
        ;;
    "--check")
        check_resources
        ;;
    "--report")
        get_system_info
        get_resource_usage
        ;;
    "--cron")
        setup_cron
        ;;
    "--help")
        show_help
        ;;
    *)
        # 彩色标题
        echo -e "\n\033[1;35m    系统资源监控 v$VERSION    \033[0m"
        echo -e "\033[1;35m==============================\033[0m"
        
        get_system_info
        get_resource_usage
        echo -e "\n\033[1;33m提示: 使用 $0 --setup 进行完整配置"
        echo "提示: 使用 $0 --report 查看资源报告"
        echo -e "提示: 使用 $0 --help 查看帮助\033[0m"
        echo -e "\033[1;33m日志文件: $LOG_FILE\033[0m"
        ;;
esac

exit 0