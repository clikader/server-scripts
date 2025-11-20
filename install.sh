#!/bin/bash

# Clikader Installer - Installs clikader as a system command

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This installer must be run as root${NC}"
    echo "Please run: sudo bash install.sh"
    exit 1
fi

echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Clikader Installer                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="$INSTALL_DIR/clikader"
GITHUB_URL="https://raw.githubusercontent.com/clikader/server-scripts/refs/heads/main/clikader.sh"

# Check if already installed
if [[ -f "$INSTALL_PATH" ]]; then
    echo -e "${YELLOW}→${NC} CLiKader is already installed"
    
    # Extract current version
    CURRENT_VERSION=$(grep '^CLIKADER_VERSION=' "$INSTALL_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2)
    if [[ -n "$CURRENT_VERSION" ]]; then
        echo -e "${BLUE}→${NC} Current version: ${CURRENT_VERSION}"
    fi
    
    echo -e "${BLUE}→${NC} Reinstalling..."
fi

# Download clikader.sh
echo -e "${GREEN}→${NC} Downloading clikader..."
if curl -fsSL "$GITHUB_URL" -o "$INSTALL_PATH"; then
    echo -e "${GREEN}✅${NC} Downloaded successfully"
else
    echo -e "${RED}❌ Failed to download clikader${NC}"
    echo "Please check your internet connection and try again"
    exit 1
fi

# Make it executable
chmod +x "$INSTALL_PATH"
echo -e "${GREEN}✅${NC} Made executable"

# Extract version from installed file
INSTALLED_VERSION=$(grep '^CLIKADER_VERSION=' "$INSTALL_PATH" | head -n1 | cut -d'"' -f2)

# Verify installation
if command -v clikader &> /dev/null; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Installation Successful!            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    if [[ -n "$INSTALLED_VERSION" ]]; then
        echo -e "Installed version: ${BOLD}${INSTALLED_VERSION}${NC}"
        echo ""
    fi
    echo "You can now run clikader from anywhere:"
    echo -e "  ${BLUE}sudo clikader${NC}"
    echo ""
else
    echo -e "${YELLOW}⚠${NC} Installation completed but 'clikader' command not found in PATH"
    echo "You may need to restart your shell or add $INSTALL_DIR to your PATH"
fi
