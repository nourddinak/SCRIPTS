#!/bin/bash

################################################################################
# Dev Tools Installer
# Installs and updates Node.js, npm, PM2, Python, Rust, Go, Docker, Git, etc.
# Automatically detects what's missing and installs the latest versions.
# Safe to run multiple times - won't reinstall if already present.
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Detect package manager
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        UPDATE_CMD="sudo apt-get update"
        INSTALL_CMD="sudo apt-get install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        UPDATE_CMD="sudo dnf check-update || true"
        INSTALL_CMD="sudo dnf install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        UPDATE_CMD="sudo yum check-update || true"
        INSTALL_CMD="sudo yum install -y"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        UPDATE_CMD="sudo pacman -Sy"
        INSTALL_CMD="sudo pacman -S --noconfirm"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        UPDATE_CMD="sudo zypper refresh"
        INSTALL_CMD="sudo zypper install -y"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
        UPDATE_CMD="sudo apk update"
        INSTALL_CMD="sudo apk add"
    else
        log_error "No supported package manager found (apt, dnf, yum, pacman, zypper, apk)"
        exit 1
    fi
    log_info "Detected package manager: $PKG_MANAGER"
}

# Update package lists (first time only)
update_packages() {
    if [ "$PACKAGES_UPDATED" != "true" ]; then
        log_info "Updating package lists..."
        eval $UPDATE_CMD || true
        PACKAGES_UPDATED="true"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

################################################################################
# GIT
################################################################################
install_git() {
    if command_exists git; then
        log_success "Git is already installed ($(git --version))"
    else
        log_info "Installing Git..."
        update_packages
        eval $INSTALL_CMD git
        log_success "Git installed"
    fi
}

################################################################################
# CURL
################################################################################
install_curl() {
    if command_exists curl; then
        log_success "curl is already installed"
    else
        log_info "Installing curl..."
        update_packages
        eval $INSTALL_CMD curl
        log_success "curl installed"
    fi
}

################################################################################
# NODE.JS & NPM
################################################################################
install_nodejs() {
    if command_exists node; then
        log_success "Node.js is already installed ($(node --version))"
    else
        log_info "Installing Node.js and npm..."
        update_packages
        
        if [ "$PKG_MANAGER" = "apt" ]; then
            curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
            eval $INSTALL_CMD nodejs
        elif [ "$PKG_MANAGER" = "dnf" ]; then
            eval $INSTALL_CMD nodejs npm
        elif [ "$PKG_MANAGER" = "yum" ]; then
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
            eval $INSTALL_CMD nodejs
        elif [ "$PKG_MANAGER" = "pacman" ]; then
            eval $INSTALL_CMD nodejs npm
        elif [ "$PKG_MANAGER" = "zypper" ]; then
            eval $INSTALL_CMD nodejs npm
        elif [ "$PKG_MANAGER" = "apk" ]; then
            eval $INSTALL_CMD nodejs npm
        fi
        log_success "Node.js installed ($(node --version))"
    fi
}

################################################################################
# NPM (Global update)
################################################################################
install_npm() {
    if command_exists npm; then
        log_info "Updating npm to latest version..."
        npm install -g npm@latest || log_warn "npm update failed, continuing..."
        log_success "npm is ready ($(npm --version))"
    else
        log_error "npm not found - install Node.js first"
    fi
}

################################################################################
# PM2
################################################################################
install_pm2() {
    if command_exists pm2; then
        log_success "PM2 is already installed ($(pm2 --version))"
    else
        if command_exists npm; then
            log_info "Installing PM2 globally..."
            sudo npm install -g pm2
            pm2 startup || true
            log_success "PM2 installed"
        else
            log_error "npm not found - cannot install PM2"
        fi
    fi
}

################################################################################
# PYTHON
################################################################################
install_python() {
    if command_exists python3; then
        log_success "Python 3 is already installed ($(python3 --version))"
    else
        log_info "Installing Python 3..."
        update_packages
        eval $INSTALL_CMD python3 python3-pip python3-venv
        log_success "Python 3 installed"
    fi
}

################################################################################
# RUST
################################################################################
install_rust() {
    if command_exists rustc; then
        log_success "Rust is already installed ($(rustc --version))"
    else
        log_info "Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source $HOME/.cargo/env
        log_success "Rust installed ($(rustc --version))"
    fi
}

################################################################################
# GO
################################################################################
install_go() {
    if command_exists go; then
        log_success "Go is already installed ($(go version))"
    else
        log_info "Installing Go..."
        update_packages
        
        if [ "$PKG_MANAGER" = "apt" ]; then
            eval $INSTALL_CMD golang-go
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            eval $INSTALL_CMD golang
        elif [ "$PKG_MANAGER" = "pacman" ]; then
            eval $INSTALL_CMD go
        elif [ "$PKG_MANAGER" = "zypper" ]; then
            eval $INSTALL_CMD go
        elif [ "$PKG_MANAGER" = "apk" ]; then
            eval $INSTALL_CMD go
        fi
        log_success "Go installed"
    fi
}

################################################################################
# DOCKER
################################################################################
install_docker() {
    if command_exists docker; then
        log_success "Docker is already installed ($(docker --version))"
    else
        log_info "Installing Docker..."
        
        if [ "$PKG_MANAGER" = "apt" ]; then
            update_packages
            eval $INSTALL_CMD apt-transport-https ca-certificates curl gnupg lsb-release
            curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            update_packages
            eval $INSTALL_CMD docker-ce docker-ce-cli containerd.io
        else
            update_packages
            eval $INSTALL_CMD docker
        fi
        
        sudo systemctl start docker || true
        sudo systemctl enable docker || true
        log_success "Docker installed"
    fi
}

################################################################################
# GIT LFS
################################################################################
install_git_lfs() {
    if command_exists git-lfs; then
        log_success "Git LFS is already installed"
    else
        log_info "Installing Git LFS..."
        update_packages
        
        if [ "$PKG_MANAGER" = "apt" ]; then
            curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | sudo bash
            eval $INSTALL_CMD git-lfs
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | sudo bash
            eval $INSTALL_CMD git-lfs
        else
            eval $INSTALL_CMD git-lfs || log_warn "Git LFS not available via package manager"
        fi
    fi
}

################################################################################
# BUILD TOOLS
################################################################################
install_build_tools() {
    log_info "Installing build tools..."
    update_packages
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        eval $INSTALL_CMD build-essential
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        eval $INSTALL_CMD gcc gcc-c++ make
    elif [ "$PKG_MANAGER" = "pacman" ]; then
        eval $INSTALL_CMD base-devel
    elif [ "$PKG_MANAGER" = "zypper" ]; then
        eval $INSTALL_CMD gcc gcc-c++ make
    elif [ "$PKG_MANAGER" = "apk" ]; then
        eval $INSTALL_CMD build-base
    fi
    
    log_success "Build tools installed"
}

################################################################################
# MAIN MENU
################################################################################
show_menu() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}  Dev Tools Installer${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo "Select tools to install:"
    echo "1. Everything (recommended)"
    echo "2. Git + curl"
    echo "3. Node.js + npm"
    echo "4. PM2"
    echo "5. Python 3"
    echo "6. Rust"
    echo "7. Go"
    echo "8. Docker"
    echo "9. Git LFS"
    echo "10. Build tools (gcc, make, etc)"
    echo "0. Exit"
    echo ""
    read -p "Enter your choice [0-10]: " choice
}

################################################################################
# INSTALLATION SUMMARY
################################################################################
print_summary() {
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  Installation Summary${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    
    if command_exists git; then
        echo -e "${GREEN}✓${NC} Git:      $(git --version)"
    fi
    
    if command_exists node; then
        echo -e "${GREEN}✓${NC} Node.js:  $(node --version)"
    fi
    
    if command_exists npm; then
        echo -e "${GREEN}✓${NC} npm:      $(npm --version)"
    fi
    
    if command_exists pm2; then
        echo -e "${GREEN}✓${NC} PM2:      $(pm2 --version)"
    fi
    
    if command_exists python3; then
        echo -e "${GREEN}✓${NC} Python:   $(python3 --version)"
    fi
    
    if command_exists rustc; then
        echo -e "${GREEN}✓${NC} Rust:     $(rustc --version)"
    fi
    
    if command_exists go; then
        echo -e "${GREEN}✓${NC} Go:       $(go version)"
    fi
    
    if command_exists docker; then
        echo -e "${GREEN}✓${NC} Docker:   $(docker --version)"
    fi
    
    echo ""
}

################################################################################
# MAIN
################################################################################
main() {
    log_info "Starting Dev Tools Installer"
    
    # Detect package manager
    detect_package_manager
    
    # Show menu if no argument provided
    if [ $# -eq 0 ]; then
        show_menu
    else
        choice="$1"
    fi
    
    case $choice in
        1)
            log_info "Installing all development tools..."
            install_git
            install_curl
            install_build_tools
            install_nodejs
            install_npm
            install_pm2
            install_python
            install_rust
            install_go
            install_docker
            install_git_lfs
            ;;
        2)
            install_git
            install_curl
            ;;
        3)
            install_nodejs
            install_npm
            ;;
        4)
            install_pm2
            ;;
        5)
            install_python
            ;;
        6)
            install_rust
            ;;
        7)
            install_go
            ;;
        8)
            install_docker
            ;;
        9)
            install_git_lfs
            ;;
        10)
            install_build_tools
            ;;
        0)
            log_info "Exiting..."
            exit 0
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_summary
    log_success "Installation complete!"
}

# Run main function with all arguments
main "$@"
