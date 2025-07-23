#!/bin/bash

# install_docker.sh
# ------------------
# 
# 一键安装 Docker CE 现代版，支持 CentOS 和 Ubuntu 系统。
# 当前只支持该两系统，其他系统不支持。
# 
# 用法：
#   bash install_docker.sh
#   如果输入取不对的参数将给出用法示例。
# 
# 作者：AI 运维助手
# 更新时间：2025-07-06

# ===================== 参数校验 =====================
if [ "$#" -ne 0 ]; then
  echo "参数错误！本脚本不接受任何参数。"
  echo "用法示例："
  echo "  bash install_docker.sh"
  exit 1
fi

# ===================== 系统检测 =====================
PKG_MGR=""
OS=""

if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "$ID" in
    centos|rhel)
      OS="centos"
      if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
      else
        PKG_MGR="yum"
      fi
      ;;
    ubuntu)
      OS="ubuntu"
      PKG_MGR="apt-get"
      ;;
    *)
      echo "当前系统 $ID 暂不支持。只支持 CentOS 和 Ubuntu。"
      exit 1
      ;;
  esac
else
  echo "/etc/os-release 不存在，无法识别系统类型。"
  exit 1
fi

# 检查 root 权限
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "请以 root 用户执行此脚本或先安装 sudo。"
    exit 1
  fi
fi

# ===================== 工具函数 =====================
check_and_install() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "测试到缺少命令 $cmd，正在尝试自动安装..."
    case "$PKG_MGR" in
      apt-get)
        $SUDO apt-get update -y
        $SUDO apt-get install -y "$pkg"
        ;;
      yum|dnf)
        $SUDO $PKG_MGR install -y "$pkg"
        ;;
      *)
        echo "未知的包管理器 $PKG_MGR，请手动安装 $pkg"
        exit 2
        ;;
    esac
  fi
}

# 确保 curl 已安装
check_and_install curl curl

# 检测能否访问 docker 官网
if ! curl -I -s --connect-timeout 5 https://download.docker.com >/dev/null; then
  echo "无法访问 https://download.docker.com，请检查网络或以后再试。"
  exit 1
fi

# ===================== 安装函数 =====================
install_docker_ubuntu() {
  $SUDO apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl gnupg
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
  $SUDO docker --version
}

install_docker_centos() {
  $SUDO $PKG_MGR remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null
  check_and_install yum-config-manager yum-utils
  $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  $SUDO $PKG_MGR install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
  $SUDO docker --version
}

# ===================== 执行安装 =====================
case "$OS" in
  ubuntu)
    install_docker_ubuntu
    ;;
  centos)
    install_docker_centos
    ;;
  *)
    echo "未知的系统类型，断开。"
    exit 1
    ;;
 esac

 echo "Docker 安装完成。"

