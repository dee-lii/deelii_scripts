#!/bin/bash

#===============================================================================
# 硬盘挂载脚本 (通用版)
# 功能：检测未使用的硬盘，格式化并挂载到指定路径
# 兼容：CentOS/RHEL 6+, Ubuntu 14.04+, Debian 8+, Alpine, SUSE 等主流发行版
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        OS_NAME="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    elif [[ -f /etc/debian_version ]]; then
        OS_NAME="debian"
        OS_VERSION=$(cat /etc/debian_version)
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
    fi
    print_info "检测到系统: $OS_NAME $OS_VERSION"
}

check_dependencies() {
    print_info "检查依赖工具..."
    
    local missing_tools=()
    local required_tools=("lsblk" "blkid" "mkfs.ext4" "mount" "grep" "awk")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if ! command -v parted &> /dev/null && ! command -v fdisk &> /dev/null; then
        missing_tools+=("parted 或 fdisk")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_error "缺少以下工具: ${missing_tools[*]}"
        echo ""
        print_info "请根据您的系统安装缺失的工具:"
        echo ""
        echo "  CentOS/RHEL:  yum install -y util-linux e2fsprogs parted"
        echo "  Ubuntu/Debian: apt install -y util-linux e2fsprogs parted"
        echo "  Alpine:        apk add util-linux e2fsprogs parted"
        echo "  SUSE:          zypper install -y util-linux e2fsprogs parted"
        echo ""
        exit 1
    fi
    
    if command -v parted &> /dev/null; then
        USE_PARTED=true
    else
        USE_PARTED=false
        print_warning "未找到 parted，将使用 fdisk (仅支持 MBR 分区表)"
    fi
    
    print_success "依赖检查通过"
}

get_unmounted_disks() {
    if lsblk --help 2>&1 | grep -q "\-\-output"; then
        lsblk -dpno NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk" {print $1, $2}' | while read disk size; do
            if ! lsblk "$disk" -no MOUNTPOINT 2>/dev/null | grep -q .; then
                local has_mounted_part=false
                for part in $(lsblk "$disk" -lno NAME 2>/dev/null | tail -n +2); do
                    if [[ -n $(lsblk "/dev/$part" -no MOUNTPOINT 2>/dev/null) ]]; then
                        has_mounted_part=true
                        break
                    fi
                done
                if [[ "$has_mounted_part" == "false" ]]; then
                    echo "$disk $size"
                fi
            fi
        done
    else
        for disk in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]n[0-9]; do
            if [[ -b "$disk" ]]; then
                if ! mount | grep -q "^$disk"; then
                    local size=$(blockdev --getsize64 "$disk" 2>/dev/null)
                    if [[ -n "$size" ]]; then
                        local size_gb=$((size / 1024 / 1024 / 1024))
                        echo "$disk ${size_gb}G"
                    fi
                fi
            fi
        done
    fi
}

show_disk_info() {
    echo ""
    print_info "========== 系统磁盘信息 =========="
    echo ""
    if command -v lsblk &> /dev/null; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || lsblk
    else
        fdisk -l 2>/dev/null | grep -E "^Disk /dev/[a-z]"
        echo ""
        df -h
    fi
    echo ""
}

select_disk() {
    print_info "正在检测未使用的磁盘..."
    echo ""
    
    local unmounted_disks=$(get_unmounted_disks)
    
    if [[ -z "$unmounted_disks" ]]; then
        print_warning "未检测到未使用的磁盘"
        print_info "所有磁盘可能已经挂载或正在使用中"
        show_disk_info
        exit 1
    fi
    
    echo "检测到以下未使用的磁盘："
    echo "----------------------------------------"
    
    local i=1
    local disk_array=()
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local disk_name=$(echo "$line" | awk '{print $1}')
            local disk_size=$(echo "$line" | awk '{print $2}')
            echo "  $i) $disk_name - 大小: $disk_size"
            disk_array+=("$disk_name")
            ((i++))
        fi
    done <<< "$unmounted_disks"
    
    if [[ ${#disk_array[@]} -eq 0 ]]; then
        print_warning "未检测到可用的未使用磁盘"
        exit 1
    fi
    
    echo "----------------------------------------"
    echo ""
    
    local max_choice=$((i-1))
    read -p "请选择要挂载的磁盘 [1-$max_choice]: " choice
    
    if ! echo "$choice" | grep -qE '^[0-9]+$' || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$max_choice" ]]; then
        print_error "无效的选择"
        exit 1
    fi
    
    SELECTED_DISK="${disk_array[$((choice-1))]}"
    print_success "已选择磁盘: $SELECTED_DISK"
}

get_mount_path() {
    echo ""
    read -p "请输入挂载路径 [默认: /data]: " mount_path
    
    if [[ -z "$mount_path" ]]; then
        MOUNT_PATH="/data"
    else
        MOUNT_PATH="$mount_path"
    fi
    
    print_info "挂载路径: $MOUNT_PATH"
}

confirm_operation() {
    echo ""
    print_warning "========== 操作确认 =========="
    echo ""
    echo "  磁盘设备: $SELECTED_DISK"
    echo "  挂载路径: $MOUNT_PATH"
    echo "  文件系统: ext4"
    echo ""
    print_warning "警告: 此操作将格式化磁盘，所有数据将被清除！"
    echo ""
    
    read -p "确认执行? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        print_info "操作已取消"
        exit 0
    fi
}

format_disk() {
    print_info "正在格式化磁盘 $SELECTED_DISK ..."
    
    if command -v wipefs &> /dev/null; then
        wipefs -a "$SELECTED_DISK" 2>/dev/null || true
    else
        dd if=/dev/zero of="$SELECTED_DISK" bs=512 count=1 2>/dev/null || true
    fi
    
    if [[ "$USE_PARTED" == "true" ]]; then
        print_info "使用 parted 创建 GPT 分区表..."
        parted -s "$SELECTED_DISK" mklabel gpt
        parted -s "$SELECTED_DISK" mkpart primary ext4 0% 100%
    else
        print_info "使用 fdisk 创建 MBR 分区表..."
        echo -e "o\nn\np\n1\n\n\nw" | fdisk "$SELECTED_DISK" 2>/dev/null || true
    fi
    
    sleep 2
    
    if command -v partprobe &> /dev/null; then
        partprobe "$SELECTED_DISK" 2>/dev/null || true
    fi
    
    sleep 1
    
    if [[ "$SELECTED_DISK" =~ nvme ]]; then
        PARTITION="${SELECTED_DISK}p1"
    else
        PARTITION="${SELECTED_DISK}1"
    fi
    
    if [[ ! -b "$PARTITION" ]]; then
        sleep 2
        if [[ ! -b "$PARTITION" ]]; then
            print_error "分区 $PARTITION 未创建成功"
            exit 1
        fi
    fi
    
    print_info "格式化为 ext4 文件系统..."
    mkfs.ext4 -F "$PARTITION"
    
    print_success "磁盘格式化完成"
}

mount_disk() {
    print_info "创建挂载点: $MOUNT_PATH"
    
    if [[ ! -d "$MOUNT_PATH" ]]; then
        mkdir -p "$MOUNT_PATH"
        print_success "挂载目录已创建"
    else
        print_warning "挂载目录已存在"
    fi
    
    print_info "正在挂载磁盘..."
    mount "$PARTITION" "$MOUNT_PATH"
    
    print_success "磁盘已挂载到 $MOUNT_PATH"
}

setup_fstab() {
    print_info "配置开机自动挂载..."
    
    local uuid=$(blkid -s UUID -o value "$PARTITION" 2>/dev/null)
    
    if [[ -z "$uuid" ]]; then
        print_warning "无法获取 UUID，使用设备路径配置 fstab"
        local fstab_entry="$PARTITION  $MOUNT_PATH  ext4  defaults,noatime  0  2"
        local check_pattern="$PARTITION"
    else
        print_info "分区 UUID: $uuid"
        local fstab_entry="UUID=$uuid  $MOUNT_PATH  ext4  defaults,noatime  0  2"
        local check_pattern="$uuid"
    fi
    
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
    print_info "已备份 /etc/fstab"
    
    if grep -q "$check_pattern" /etc/fstab; then
        print_warning "fstab 中已存在该条目"
    else
        echo "" >> /etc/fstab
        echo "# 自动添加 - $(date)" >> /etc/fstab
        echo "$fstab_entry" >> /etc/fstab
        print_success "已添加到 /etc/fstab"
    fi
}

show_result() {
    echo ""
    print_success "========== 挂载完成 =========="
    echo ""
    echo "磁盘信息："
    df -h "$MOUNT_PATH"
    echo ""
    echo "挂载详情："
    mount | grep "$MOUNT_PATH"
    echo ""
    print_info "磁盘已成功挂载并配置开机自动挂载"
    print_info "挂载路径: $MOUNT_PATH"
    echo ""
}

main() {
    echo ""
    echo "=========================================="
    echo "       Linux 硬盘挂载脚本 (通用版)"
    echo "=========================================="
    echo ""
    
    check_root
    detect_os
    check_dependencies
    show_disk_info
    select_disk
    get_mount_path
    confirm_operation
    format_disk
    mount_disk
    setup_fstab
    show_result
}

main "$@"
