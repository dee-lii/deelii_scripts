#!/usr/bin/env bash
# =============================================================================
# 通用 Linux 硬盘检测与测试脚本
# 基于 spiritlhl/ecs 脚本的硬盘检测逻辑改写
# 兼容: Debian, Ubuntu, CentOS, RHEL, Fedora, Arch, Alpine, OpenSUSE 等
# =============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"
BOLD="\033[1m"

_red()    { echo -e "${RED}$*${PLAIN}"; }
_green()  { echo -e "${GREEN}$*${PLAIN}"; }
_yellow() { echo -e "${YELLOW}$*${PLAIN}"; }
_blue()   { echo -e "${BLUE}$*${PLAIN}"; }
_bold()   { echo -e "${BOLD}$*${PLAIN}"; }

TEMP_DIR="/tmp/disk_test_$$"
declare -a DISK_DEVICES=()
declare -a DISK_MOUNT_POINTS=()
declare -a DISK_SIZES=()
declare -a DISK_USED=()
declare -a DISK_AVAIL=()
declare -a DISK_TYPES=()
declare -a SELECTED_INDEXES=()
FIO_AVAILABLE=false
TEST_MODE="fio"

cleanup() {
    echo ""
    _yellow "正在清理临时文件..."
    rm -rf "$TEMP_DIR" 2>/dev/null
    rm -rf /tmp/.disk_test_* 2>/dev/null
    exit 0
}

trap cleanup INT QUIT TERM

check_root() {
    if [[ $EUID -ne 0 ]]; then
        _red "错误: 请使用 root 用户运行此脚本!"
        _yellow "提示: 使用 sudo $0 运行"
        exit 1
    fi
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum makecache"
        PKG_INSTALL="yum install -y"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf makecache"
        PKG_INSTALL="dnf install -y"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
        PKG_UPDATE="pacman -Sy"
        PKG_INSTALL="pacman -S --noconfirm"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="zypper refresh"
        PKG_INSTALL="zypper install -y"
    else
        PKG_MANAGER=""
        PKG_UPDATE=""
        PKG_INSTALL=""
    fi
}

install_package() {
    local package="$1"
    
    if [[ -z "$PKG_MANAGER" ]]; then
        _red "无法检测到包管理器，请手动安装: $package"
        return 1
    fi
    
    _yellow "正在安装 $package ..."
    
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq &>/dev/null
            apt-get install -y "$package" &>/dev/null
            ;;
        yum)
            yum install -y "$package" &>/dev/null
            ;;
        dnf)
            dnf install -y "$package" &>/dev/null
            ;;
        pacman)
            pacman -Sy --noconfirm "$package" &>/dev/null
            ;;
        apk)
            apk add "$package" &>/dev/null
            ;;
        zypper)
            zypper install -y "$package" &>/dev/null
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        _green "✓ $package 安装成功"
        return 0
    else
        _red "✗ $package 安装失败"
        return 1
    fi
}

check_dependencies() {
    detect_package_manager
    
    _blue "检查依赖..."
    echo ""
    
    local missing_deps=()
    local basic_tools=("dd" "df" "awk" "grep" "sed")
    
    for cmd in "${basic_tools[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        _red "错误: 缺少以下基础命令: ${missing_deps[*]}"
        _red "这些是系统基础工具，请检查系统完整性"
        exit 1
    fi
    
    if command -v fio &>/dev/null; then
        FIO_AVAILABLE=true
        _green "✓ fio 已安装 - 可进行完整 IO 测试"
        
        if ! command -v jq &>/dev/null; then
            _yellow "  正在安装 jq (用于解析测试结果)..."
            install_package "jq" &>/dev/null
        fi
    else
        FIO_AVAILABLE=false
        echo ""
        _yellow "╔════════════════════════════════════════════════════════════╗"
        _yellow "║  未检测到 fio 工具                                         ║"
        _yellow "║  fio 可提供更准确的 4K/64K/512K/1M 随机读写测试             ║"
        _yellow "║  如不安装，将使用 dd 进行基础顺序读写测试                   ║"
        _yellow "╚════════════════════════════════════════════════════════════╝"
        echo ""
        
        if [[ -z "$PKG_MANAGER" ]]; then
            _red "未检测到包管理器，请手动安装 fio:"
            echo "  Debian/Ubuntu: apt install fio"
            echo "  CentOS/RHEL:   yum install fio"
            echo "  Fedora:        dnf install fio"
            echo "  Arch:          pacman -S fio"
            echo "  Alpine:        apk add fio"
            echo ""
            read -rp "是否继续使用 dd 测试? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                _yellow "用户取消，退出脚本"
                exit 0
            fi
        else
            _bold "是否现在安装 fio? (推荐)"
            echo ""
            echo "  [Y] 是，安装 fio (推荐)"
            echo "  [N] 否，使用 dd 基础测试"
            echo "  [Q] 退出脚本"
            echo ""
            
            read -rp "请选择 (默认: Y): " install_choice
            install_choice=${install_choice:-Y}
            
            case "$install_choice" in
                [Yy]|[Yy][Ee][Ss])
                    echo ""
                    if install_package "fio"; then
                        FIO_AVAILABLE=true
                        _yellow "正在安装 jq (用于解析测试结果)..."
                        install_package "jq" &>/dev/null
                    else
                        echo ""
                        _yellow "fio 安装失败，将使用 dd 进行测试"
                        read -rp "是否继续? (Y/n): " continue_choice
                        if [[ "$continue_choice" =~ ^[Nn]$ ]]; then
                            exit 0
                        fi
                    fi
                    ;;
                [Nn]|[Nn][Oo])
                    _yellow "将使用 dd 进行基础测试"
                    TEST_MODE="dd"
                    ;;
                [Qq]|[Qq][Uu][Ii][Tt])
                    _yellow "用户取消，退出脚本"
                    exit 0
                    ;;
                *)
                    echo ""
                    if install_package "fio"; then
                        FIO_AVAILABLE=true
                        install_package "jq" &>/dev/null
                    fi
                    ;;
            esac
        fi
    fi
    
    echo ""
}

print_separator() {
    printf '%72s\n' | tr ' ' '-'
}

detect_disks() {
    _blue "正在检测系统磁盘..."
    echo ""
    
    DISK_DEVICES=()
    DISK_MOUNT_POINTS=()
    DISK_SIZES=()
    DISK_USED=()
    DISK_AVAIL=()
    DISK_TYPES=()
    
    local df_output
    df_output=$(df -hP 2>/dev/null | grep -vE '^Filesystem|^tmpfs|^devtmpfs|^overlay|^squashfs|^none|^udev|^shm|^run|^/dev/loop|^cgroup|^nsfs' | grep '^/')
    
    if [[ -z "$df_output" ]]; then
        df_output=$(df -hP 2>/dev/null | grep -vE '^Filesystem|^tmpfs|^devtmpfs|^overlay|^squashfs|^none|^udev|^shm|^run|^cgroup|^nsfs' | grep -E '^/dev/')
    fi
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local device mount_point size used avail
        device=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')
        mount_point=$(echo "$line" | awk '{print $6}')
        
        [[ -z "$mount_point" ]] && continue
        [[ "$mount_point" =~ ^/snap ]] && continue
        [[ "$mount_point" =~ ^/var/lib/docker ]] && continue
        [[ "$device" =~ loop ]] && continue
        
        local disk_type="Unknown"
        local base_device=$(echo "$device" | sed 's/[0-9]*$//' | sed 's/p$//')
        
        if [[ -f /sys/block/$(basename "$base_device")/queue/rotational ]]; then
            local rotational=$(cat /sys/block/$(basename "$base_device")/queue/rotational 2>/dev/null)
            if [[ "$rotational" == "0" ]]; then
                disk_type="SSD"
            elif [[ "$rotational" == "1" ]]; then
                disk_type="HDD"
            fi
        fi
        
        [[ "$device" =~ nvme ]] && disk_type="NVMe"
        
        DISK_DEVICES+=("$device")
        DISK_MOUNT_POINTS+=("$mount_point")
        DISK_SIZES+=("$size")
        DISK_USED+=("$used")
        DISK_AVAIL+=("$avail")
        DISK_TYPES+=("$disk_type")
    done <<< "$df_output"
    
    if [[ ${#DISK_DEVICES[@]} -eq 0 ]]; then
        _red "错误: 未检测到任何已挂载的磁盘分区!"
        exit 1
    fi
}

display_disks() {
    echo ""
    _bold "==================== 检测到的磁盘分区 ===================="
    echo ""
    printf "%-4s %-20s %-15s %-8s %-8s %-8s %-6s\n" "序号" "设备" "挂载点" "总大小" "已用" "可用" "类型"
    print_separator
    
    for i in "${!DISK_DEVICES[@]}"; do
        local num=$((i + 1))
        printf "%-4s %-20s %-15s %-8s %-8s %-8s %-6s\n" \
            "[$num]" \
            "${DISK_DEVICES[$i]}" \
            "${DISK_MOUNT_POINTS[$i]}" \
            "${DISK_SIZES[$i]}" \
            "${DISK_USED[$i]}" \
            "${DISK_AVAIL[$i]}" \
            "${DISK_TYPES[$i]}"
    done
    
    print_separator
    _green "共检测到 ${#DISK_DEVICES[@]} 个磁盘分区"
    echo ""
}

select_disks() {
    local total=${#DISK_DEVICES[@]}
    
    echo ""
    _bold "请选择要测试的磁盘:"
    echo "  [A] 测试全部磁盘"
    echo "  [1-$total] 输入数字选择单个磁盘"
    echo "  [1,2,3] 逗号分隔选择多个磁盘"
    echo "  [Q] 退出"
    echo ""
    
    while true; do
        read -rp "请输入选择 (默认: A): " choice
        choice=${choice:-A}
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        
        SELECTED_INDEXES=()
        
        if [[ "$choice" == "Q" ]]; then
            _yellow "用户取消操作"
            exit 0
        elif [[ "$choice" == "A" ]]; then
            for i in "${!DISK_DEVICES[@]}"; do
                SELECTED_INDEXES+=("$i")
            done
            _green "已选择全部 ${#SELECTED_INDEXES[@]} 个磁盘"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            local idx=$((choice - 1))
            if [[ $idx -ge 0 ]] && [[ $idx -lt $total ]]; then
                SELECTED_INDEXES+=("$idx")
                _green "已选择: ${DISK_DEVICES[$idx]}"
                break
            else
                _red "无效选择"
            fi
        elif [[ "$choice" =~ ^[0-9,]+$ ]]; then
            local valid=true
            IFS=',' read -ra nums <<< "$choice"
            for num in "${nums[@]}"; do
                local idx=$((num - 1))
                if [[ $idx -ge 0 ]] && [[ $idx -lt $total ]]; then
                    SELECTED_INDEXES+=("$idx")
                else
                    _red "无效数字: $num"
                    valid=false
                    break
                fi
            done
            [[ "$valid" == true ]] && break
        else
            _red "无效输入"
        fi
    done
}

select_test_method() {
    echo ""
    _bold "请选择测试方式:"
    echo "  [1] fio 完整测试 - 4K/64K/512K/1M 块大小 (推荐，约1-2分钟)"
    echo "  [2] dd 快速测试 - 基础读写速度 (约1分钟)"
    echo "  [Q] 退出"
    echo ""
    
    while true; do
        read -rp "请选择 (默认: 1): " test_choice
        test_choice=${test_choice:-1}
        
        case "$test_choice" in
            1)
                if [[ "$FIO_AVAILABLE" == true ]]; then
                    TEST_MODE="fio"
                    break
                else
                    _red "fio 未安装，请先安装或选择 dd 测试"
                fi
                ;;
            2) TEST_MODE="dd"; break ;;
            [Qq]) exit 0 ;;
            *) _red "无效选择" ;;
        esac
    done
}

format_speed() {
    local speed_kbs=$1
    if [[ -z "$speed_kbs" ]] || [[ "$speed_kbs" == "0" ]]; then
        echo "N/A"
        return
    fi
    
    local speed_mbs=$(awk "BEGIN {printf \"%.2f\", $speed_kbs/1024}")
    
    if (( $(echo "$speed_mbs >= 1000" | bc -l 2>/dev/null || echo 0) )); then
        local speed_gbs=$(awk "BEGIN {printf \"%.2f\", $speed_mbs/1024}")
        echo "${speed_gbs} GB/s"
    else
        echo "${speed_mbs} MB/s"
    fi
}

format_iops() {
    local iops=$1
    if [[ -z "$iops" ]] || [[ "$iops" == "0" ]]; then
        echo "0"
        return
    fi
    
    local iops_int=$(printf "%.0f" "$iops" 2>/dev/null || echo "$iops")
    
    if [[ $iops_int -ge 1000 ]]; then
        local iops_k=$(awk "BEGIN {printf \"%.1f\", $iops_int/1000}")
        echo "${iops_k}k"
    else
        echo "$iops_int"
    fi
}

run_fio_single_test() {
    local mount_point="$1"
    local block_size="$2"
    local test_dir="$mount_point/.disk_test_$$"
    local test_file="$test_dir/fio_test"
    local output_file="/tmp/fio_result_$$.json"
    
    mkdir -p "$test_dir" 2>/dev/null
    
    fio --name=test --filename="$test_file" --size=128M \
        --rw=randrw --rwmixread=50 --bs="$block_size" --direct=1 --numjobs=1 \
        --time_based --runtime=15 --group_reporting --output-format=json \
        --output="$output_file" 2>/dev/null
    
    local fio_exit=$?
    rm -f "$test_file" 2>/dev/null
    rmdir "$test_dir" 2>/dev/null
    
    if [[ $fio_exit -eq 0 ]] && [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        local read_bw=0 write_bw=0 read_iops=0 write_iops=0
        
        if command -v jq &>/dev/null; then
            read_bw=$(jq -r '.jobs[0].read.bw // 0' "$output_file" 2>/dev/null)
            write_bw=$(jq -r '.jobs[0].write.bw // 0' "$output_file" 2>/dev/null)
            read_iops=$(jq -r '.jobs[0].read.iops // 0' "$output_file" 2>/dev/null)
            write_iops=$(jq -r '.jobs[0].write.iops // 0' "$output_file" 2>/dev/null)
        else
            read_bw=$(sed -n 's/.*"read".*"bw" *: *\([0-9.]*\).*/\1/p' "$output_file" | head -1)
            write_bw=$(sed -n 's/.*"write".*"bw" *: *\([0-9.]*\).*/\1/p' "$output_file" | head -1)
            read_iops=$(sed -n 's/.*"read".*"iops" *: *\([0-9.]*\).*/\1/p' "$output_file" | head -1)
            write_iops=$(sed -n 's/.*"write".*"iops" *: *\([0-9.]*\).*/\1/p' "$output_file" | head -1)
            
            if [[ -z "$read_bw" ]] || [[ "$read_bw" == "0" ]]; then
                read_bw=$(awk -F'"bw"[ ]*:[ ]*' 'NR==1{print $2}' "$output_file" 2>/dev/null | awk -F'[,}]' '{print $1}' | tr -d ' ')
                write_bw=$(awk -F'"bw"[ ]*:[ ]*' 'NR==2{print $2}' "$output_file" 2>/dev/null | awk -F'[,}]' '{print $1}' | tr -d ' ')
                read_iops=$(awk -F'"iops"[ ]*:[ ]*' 'NR==1{print $2}' "$output_file" 2>/dev/null | awk -F'[,}]' '{print $1}' | tr -d ' ')
                write_iops=$(awk -F'"iops"[ ]*:[ ]*' 'NR==2{print $2}' "$output_file" 2>/dev/null | awk -F'[,}]' '{print $1}' | tr -d ' ')
            fi
        fi
        
        [[ -z "$read_bw" || "$read_bw" == "null" ]] && read_bw=0
        [[ -z "$write_bw" || "$write_bw" == "null" ]] && write_bw=0
        [[ -z "$read_iops" || "$read_iops" == "null" ]] && read_iops=0
        [[ -z "$write_iops" || "$write_iops" == "null" ]] && write_iops=0
        
        local total_bw=$(awk "BEGIN {printf \"%.2f\", $read_bw + $write_bw}")
        local total_iops=$(awk "BEGIN {printf \"%.0f\", $read_iops + $write_iops}")
        
        rm -f "$output_file" 2>/dev/null
        echo "$read_bw $read_iops $write_bw $write_iops $total_bw $total_iops"
    else
        rm -f "$output_file" 2>/dev/null
        echo "0 0 0 0 0 0"
    fi
}

print_fio_table() {
    local mount_point="$1"
    local device="$2"
    
    echo ""
    _bold "磁盘 IO 测试结果 - $device ($mount_point)"
    echo ""
    
    _yellow "正在测试，请稍候..."
    
    echo -ne "\r测试 4K 块大小...   "
    local result_4k=$(run_fio_single_test "$mount_point" "4k")
    read r_bw_4k r_iops_4k w_bw_4k w_iops_4k t_bw_4k t_iops_4k <<< "$result_4k"
    
    echo -ne "\r测试 64K 块大小...  "
    local result_64k=$(run_fio_single_test "$mount_point" "64k")
    read r_bw_64k r_iops_64k w_bw_64k w_iops_64k t_bw_64k t_iops_64k <<< "$result_64k"
    
    echo -ne "\r测试 512K 块大小... "
    local result_512k=$(run_fio_single_test "$mount_point" "512k")
    read r_bw_512k r_iops_512k w_bw_512k w_iops_512k t_bw_512k t_iops_512k <<< "$result_512k"
    
    echo -ne "\r测试 1M 块大小...   "
    local result_1m=$(run_fio_single_test "$mount_point" "1m")
    read r_bw_1m r_iops_1m w_bw_1m w_iops_1m t_bw_1m t_iops_1m <<< "$result_1m"
    
    echo -ne "\r                              \r"
    
    rm -rf "$mount_point/.disk_test_$$" 2>/dev/null
    
    local r_speed_4k=$(format_speed "$r_bw_4k")
    local r_speed_64k=$(format_speed "$r_bw_64k")
    local r_speed_512k=$(format_speed "$r_bw_512k")
    local r_speed_1m=$(format_speed "$r_bw_1m")
    
    local w_speed_4k=$(format_speed "$w_bw_4k")
    local w_speed_64k=$(format_speed "$w_bw_64k")
    local w_speed_512k=$(format_speed "$w_bw_512k")
    local w_speed_1m=$(format_speed "$w_bw_1m")
    
    local t_speed_4k=$(format_speed "$t_bw_4k")
    local t_speed_64k=$(format_speed "$t_bw_64k")
    local t_speed_512k=$(format_speed "$t_bw_512k")
    local t_speed_1m=$(format_speed "$t_bw_1m")
    
    local r_iops_4k_fmt=$(format_iops "$r_iops_4k")
    local r_iops_64k_fmt=$(format_iops "$r_iops_64k")
    local r_iops_512k_fmt=$(format_iops "$r_iops_512k")
    local r_iops_1m_fmt=$(format_iops "$r_iops_1m")
    
    local w_iops_4k_fmt=$(format_iops "$w_iops_4k")
    local w_iops_64k_fmt=$(format_iops "$w_iops_64k")
    local w_iops_512k_fmt=$(format_iops "$w_iops_512k")
    local w_iops_1m_fmt=$(format_iops "$w_iops_1m")
    
    local t_iops_4k_fmt=$(format_iops "$t_iops_4k")
    local t_iops_64k_fmt=$(format_iops "$t_iops_64k")
    local t_iops_512k_fmt=$(format_iops "$t_iops_512k")
    local t_iops_1m_fmt=$(format_iops "$t_iops_1m")
    
    echo "Block Size | 4k            (IOPS) | 64k           (IOPS)"
    echo "  ------   | ---            ----  | ----           ---- "
    printf "Read       | %-13s (%5s) | %-13s (%5s)\n" "$r_speed_4k" "$r_iops_4k_fmt" "$r_speed_64k" "$r_iops_64k_fmt"
    printf "Write      | %-13s (%5s) | %-13s (%5s)\n" "$w_speed_4k" "$w_iops_4k_fmt" "$w_speed_64k" "$w_iops_64k_fmt"
    printf "Total      | %-13s (%5s) | %-13s (%5s)\n" "$t_speed_4k" "$t_iops_4k_fmt" "$t_speed_64k" "$t_iops_64k_fmt"
    echo "           |                      |                     "
    echo "Block Size | 512k          (IOPS) | 1m            (IOPS)"
    echo "  ------   | ---            ----  | ----           ---- "
    printf "Read       | %-13s (%5s) | %-13s (%5s)\n" "$r_speed_512k" "$r_iops_512k_fmt" "$r_speed_1m" "$r_iops_1m_fmt"
    printf "Write      | %-13s (%5s) | %-13s (%5s)\n" "$w_speed_512k" "$w_iops_512k_fmt" "$w_speed_1m" "$w_iops_1m_fmt"
    printf "Total      | %-13s (%5s) | %-13s (%5s)\n" "$t_speed_512k" "$t_iops_512k_fmt" "$t_speed_1m" "$t_iops_1m_fmt"
    echo ""
}

run_dd_test() {
    local mount_point="$1"
    local device="$2"
    
    local test_dir="$mount_point/.disk_test_$$"
    local test_file="$test_dir/testfile"
    local result_file="$TEMP_DIR/dd_result"
    
    mkdir -p "$test_dir" "$TEMP_DIR" 2>/dev/null
    
    echo ""
    _bold "磁盘 DD 测试结果 - $device ($mount_point)"
    echo ""
    
    sync
    [[ -w /proc/sys/vm/drop_caches ]] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    
    echo -n "测试 1GB 顺序写入... "
    dd if=/dev/zero of="$test_file" bs=1M count=1024 oflag=direct 2>"$result_file"
    local write_speed=$(grep -oE '[0-9.]+ [KMGT]?B/s|[0-9.]+ [KMGT]?B/秒' "$result_file" | head -1 | sed 's/秒/s/')
    echo "$write_speed"
    
    sync
    [[ -w /proc/sys/vm/drop_caches ]] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    
    echo -n "测试 1GB 顺序读取... "
    dd if="$test_file" of=/dev/null bs=1M count=1024 iflag=direct 2>"$result_file"
    local read_speed=$(grep -oE '[0-9.]+ [KMGT]?B/s|[0-9.]+ [KMGT]?B/秒' "$result_file" | head -1 | sed 's/秒/s/')
    echo "$read_speed"
    
    rm -rf "$test_dir" 2>/dev/null
    echo ""
    
    echo "+--------------+---------------+"
    echo "| 测试项目     | 速度          |"
    echo "+--------------+---------------+"
    printf "| %-12s | %-13s |\n" "顺序写入" "${write_speed:-N/A}"
    printf "| %-12s | %-13s |\n" "顺序读取" "${read_speed:-N/A}"
    echo "+--------------+---------------+"
    echo ""
}

run_tests() {
    echo ""
    _bold "========================= 开始磁盘测试 ========================="
    
    mkdir -p "$TEMP_DIR"
    
    for idx in "${SELECTED_INDEXES[@]}"; do
        local device="${DISK_DEVICES[$idx]}"
        local mount_point="${DISK_MOUNT_POINTS[$idx]}"
        local disk_type="${DISK_TYPES[$idx]}"
        local avail="${DISK_AVAIL[$idx]}"
        
        echo ""
        print_separator
        echo "设备: $device | 挂载点: $mount_point | 类型: $disk_type | 可用: $avail"
        print_separator
        
        if [[ ! -w "$mount_point" ]]; then
            _red "错误: 挂载点不可写，跳过"
            continue
        fi
        
        local avail_kb=$(df -k "$mount_point" 2>/dev/null | tail -1 | awk '{print $4}')
        if [[ -n "$avail_kb" ]] && [[ "$avail_kb" -lt 512000 ]]; then
            _red "警告: 可用空间不足 500MB，跳过"
            continue
        fi
        
        case "$TEST_MODE" in
            fio) print_fio_table "$mount_point" "$device" ;;
            dd)  run_dd_test "$mount_point" "$device" ;;
        esac
    done
    
    print_separator
    _green "所有测试完成!"
    echo ""
}

show_help() {
    echo ""
    _bold "通用 Linux 硬盘检测与测试脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help      显示帮助"
    echo "  -l, --list      仅列出磁盘"
    echo "  -a, --all       测试所有磁盘"
    echo "  -d, --dd        使用 dd 测试 (默认 fio)"
    echo ""
    exit 0
}

main() {
    local list_only=false
    local auto_all=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help ;;
            -l|--list) list_only=true; shift ;;
            -a|--all) auto_all=true; shift ;;
            -d|--dd) TEST_MODE="dd"; shift ;;
            *) _red "未知选项: $1"; exit 1 ;;
        esac
    done
    
    echo ""
    _bold "=============================================================="
    _bold "           通用 Linux 硬盘检测与测试脚本 v2.0"
    _bold "=============================================================="
    echo ""
    
    check_root
    check_dependencies
    detect_disks
    display_disks
    
    [[ "$list_only" == true ]] && exit 0
    
    if [[ "$auto_all" == true ]]; then
        for i in "${!DISK_DEVICES[@]}"; do
            SELECTED_INDEXES+=("$i")
        done
        _green "已自动选择全部磁盘"
        
        if [[ "$TEST_MODE" != "dd" ]] && [[ "$FIO_AVAILABLE" == true ]]; then
            TEST_MODE="fio"
        elif [[ "$FIO_AVAILABLE" == false ]]; then
            TEST_MODE="dd"
        fi
        
        run_tests
        cleanup
        exit 0
    fi
    
    select_disks
    select_test_method
    
    echo ""
    _yellow "即将测试:"
    for idx in "${SELECTED_INDEXES[@]}"; do
        echo "  - ${DISK_DEVICES[$idx]} (${DISK_MOUNT_POINTS[$idx]})"
    done
    echo ""
    read -rp "确认开始? (Y/n): " confirm
    [[ ! "${confirm:-Y}" =~ ^[Yy]$ ]] && exit 0
    
    run_tests
    cleanup
}

main "$@"
