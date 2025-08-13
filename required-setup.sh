#!/bin/bash
set -Eeuo pipefail
trap 'echo "[❌ ERROR] Line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# ==============================================================================
# SCRIPT METADATA AND CONFIGURATION
# ==============================================================================
# This script sets up the local environment by installing necessary tools,
# configuring Git credentials, and verifying that all required dependencies
# are in place.
#
# Usage:
#   Run this script once to prepare your machine for the build process.
# ==============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="$SCRIPT_DIR/.env"
readonly GIT_CREDENTIALS_FILE="$SCRIPT_DIR/.git-credentials"
readonly LOG_PREFIX="[env-setup]"

# === Helper function to log messages ===
log() {
    echo "$LOG_PREFIX $(date +'%F %T') $*"
}

# === Function to check version and optionally install ===
# $1: Tool name (e.g., "Java")
# $2: Command to get version (e.g., "java -version")
# $3: Expected version string (e.g., "17")
# $4: Installation command string (e.g., "sudo apt-get install -y openjdk-17-jdk")
check_and_install() {
    local tool="$1"
    local version_cmd="$2"
    local expected="$3"
    local install_cmd="$4"
    local actual=""

    log "🧪 Verifying $tool version..."
    set +e
    # Run the version command and capture output
    actual=$(eval "$version_cmd" 2>&1)
    set -e

    if [[ "$actual" == *"$expected"* ]]; then
        log "✅ $tool version OK: Found '$actual' (expected to include '$expected')."
    else
        log "❌ $tool version mismatch: Found '$actual', expected to include '$expected'."
        read -rp "⚠️ Install/Update $tool? (y/N): " install_choice
        if [[ "${install_choice,,}" == "y" ]]; then
            log "📦 Installing $tool..."
            set +e
            eval "$install_cmd"
            local exit_code=$?
            set -e
            if [[ $exit_code -eq 0 ]]; then
                log "✅ $tool installed successfully."
            else
                log "❌ Failed to install $tool. Please check the output and try manually."
                read -rp "⚠️ Continue setup despite this failure? (y/N): " continue_choice
                [[ "${continue_choice,,}" == "y" ]] || exit 1
            fi
        else
            log "Skipping installation of $tool. Exiting."
            exit 1
        fi
    fi
}

# ==============================================================================
# MAIN SCRIPT EXECUTION
# ==============================================================================

log "🔧 Updating package list and installing core dependencies..."
sudo apt-get update -y
sudo apt-get install -y git curl unzip software-properties-common

# === Install and check dependencies interactively ===
check_and_install "Java" "java -version" "17" "sudo apt-get install -y openjdk-17-jdk"
check_and_install "Maven" "mvn -v" "Apache Maven 3" "sudo apt-get install -y maven"
check_and_install "Node.js" "node -v" "v18" "curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - && sudo apt-get install -y nodejs"
check_and_install "GNU Parallel" "parallel --version | head -n 1" "GNU parallel 20" "sudo apt-get install -y parallel"
check_and_install "Git" "git --version" "git version 2" "" # No install command needed for git since it was installed at the start

# === .env and Git Setup ===
log "📝 Setting up .env file for Git credentials..."
if [[ ! -f "$ENV_FILE" ]]; then
    read -rp "🔐 Enter your GitHub username: " GIT_USERNAME
    read -s -rp "🔑 Enter your GitHub personal access token (PAT): " GIT_TOKEN
    echo
    if [[ -z "$GIT_USERNAME" || -z "$GIT_TOKEN" ]]; then
        log "❌ Username or token cannot be empty. Exiting."
        exit 1
    fi
    echo "GIT_USERNAME=$GIT_USERNAME" > "$ENV_FILE"
    echo "GIT_TOKEN=$GIT_TOKEN" >> "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "✅ .env file created at $ENV_FILE"
else
    log "ℹ️ .env file already exists at $ENV_FILE. Skipping creation."
fi

# === Load .env and configure Git ===
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    log "❌ .env file not found. Git credentials cannot be configured. Exiting."
    exit 1
fi

if [[ -z "${GIT_USERNAME:-}" || -z "${GIT_TOKEN:-}" ]]; then
    log "❌ GIT_USERNAME or GIT_TOKEN not set in $ENV_FILE. Exiting."
    exit 1
fi

log "⚙️ Configuring Git credential helper..."
echo "https://${GIT_USERNAME}:${GIT_TOKEN}@github.com" > "$GIT_CREDENTIALS_FILE"
chmod 600 "$GIT_CREDENTIALS_FILE"
git config --global credential.helper "store --file=$GIT_CREDENTIALS_FILE"
git config --global user.name "$GIT_USERNAME"
log "✅ Git credential helper configured."

log "✅ Environment setup completed successfully."

