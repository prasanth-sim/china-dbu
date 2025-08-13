k#!/bin/bash
set -Eeuo pipefail

# Trap command that removes the build directory on script failure.
trap 'if [ -d "$BUILD_DIR" ]; then rm -rf "$BUILD_DIR"; echo "[❌ CLEANUP] Removed temporary build directory: $BUILD_DIR"; fi; exit 1' ERR

# === Script Arguments ===
# ENV: Environment name (e.g., dev, qa, prasanth)
ENV="${1:-}"
# BRANCH: Git branch to checkout
BRANCH="${2:-main}"
# BASE_DIR: Base directory for repos, builds, and logs
BASE_DIR="${3:-$HOME/automation_workspace}"

# === Input Validation ===
if [[ -z "$ENV" || -z "$BRANCH" || -z "$BASE_DIR" ]]; then
    echo "❌ Missing required arguments. Usage: $0 <env_name> <branch_name> <base_dir>"
    exit 1
fi

# Check for npx command
command -v npx >/dev/null || { echo "❌ 'npx' not found. Install Node.js first."; exit 1; }

# === Path Definitions ===
REPO="spriced-ui"
REPO_DIR="$BASE_DIR/repos/$REPO"
BUILD_OUTPUT_ROOT_DIR="$BASE_DIR/builds/$REPO/$ENV"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BUILD_DIR="$BUILD_OUTPUT_ROOT_DIR/$TIMESTAMP"

# Paths to the spriced-pipeline repository files
PIPELINE_DIR="$BASE_DIR/spriced-pipeline"
CONFIG_PIPELINE_BASE="$PIPELINE_DIR/framework/frontend/nrp-$ENV"
MANIFEST_SOURCE="$CONFIG_PIPELINE_BASE/module-federation.manifest.json"

# List of microfrontends
MICROFRONTENDS=(
    "spriced-container"
    "spriced-data"
    "spriced-data-definition"
    "spriced-reports"
    "spriced-user-management"
)

# === Script Execution Start ===
echo "Starting UI build for ENV='$ENV', BRANCH='$BRANCH'..."
echo "Build directory: $BUILD_DIR"

# Step 1: Prepare the repository
echo "[📦] Preparing '$REPO' repository..."
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "  - Cloning from https://github.com/simaiserver/$REPO.git"
    git clone "https://github.com/simaiserver/$REPO.git" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin
echo "  - Checking out branch: $BRANCH"
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"

# Step 2: Inject .env files for the build process
echo "[🔧] Injecting environment files from spriced-pipeline into repository..."
if [ ! -d "$CONFIG_PIPELINE_BASE" ]; then
    echo "❌ Missing environment configuration directory: $CONFIG_PIPELINE_BASE"
    exit 1
fi
for mf in "${MICROFRONTENDS[@]}"; do
    SRC_ENV_FILE="$CONFIG_PIPELINE_BASE/$mf/.env"
    DEST_ENV_FILE="$REPO_DIR/apps/$mf/.env"

    if [[ -f "$SRC_ENV_FILE" ]]; then
        mkdir -p "$(dirname "$DEST_ENV_FILE")"
        cp "$SRC_ENV_FILE" "$DEST_ENV_FILE"
        echo "  - Applied env for '$mf'."
    else
        echo "  - [⚠️] Missing .env for '$mf': $SRC_ENV_FILE"
    fi
done

# Step 3: Install Node dependencies
echo "[🧩] Installing Node dependencies..."
npm install

# Step 4: Build projects using Nx
echo "[🏗️] Building projects with Nx..."
rm -rf dist/
npx nx run-many --target=build --projects=$(IFS=,; echo "${MICROFRONTENDS[*]}") --configuration=production

# Step 5: Copy build artifacts to final destination and create symlink
echo "[📂] Copying build artifacts to final destination..."
mkdir -p "$BUILD_DIR"
if [ ! -d "$REPO_DIR/dist/apps" ]; then
    echo "❌ Nx build output not found. The build may have failed."
    exit 1
fi

# Copy all the built applications
cp -r "$REPO_DIR/dist/apps/"* "$BUILD_DIR/"

# Copy .env files to the final build output directory AND update their URLs
echo "[🔧] Processing and copying .env files to final build directories..."
for mf in "${MICROFRONTENDS[@]}"; do
    SRC_ENV_FILE="$CONFIG_PIPELINE_BASE/$mf/.env"
    if [[ -f "$SRC_ENV_FILE" ]]; then
        # Use sed to replace the dev environment URL with the chosen one and save to the build directory
        sed "s/\.\(dev\)\.simadvisory\.com/\.${ENV}\.simadvisory\.com/g" "$SRC_ENV_FILE" > "$BUILD_DIR/$mf/.env"
        echo "  - Processed and copied .env for '$mf' to final output."
    else
        echo "  - [⚠️] .env file not found for '$mf'. Skipping copy to final build."
    fi
done

# Process and copy the module federation manifest file
echo "[📜] Processing and copying module-federation.manifest.json..."
if [ ! -f "$MANIFEST_SOURCE" ]; then
    echo "❌ Manifest not found at $MANIFEST_SOURCE. Build artifacts may be incomplete."
    exit 1
fi
sed "s/\.\(dev\)\.simadvisory\.com/\.${ENV}\.simadvisory\.com/g" "$MANIFEST_SOURCE" > "$BUILD_DIR/module-federation.manifest.json"
echo "  - Manifest processed and copied."

# Create a symlink to the latest build
LATEST_LINK="$BUILD_OUTPUT_ROOT_DIR/latest"
if [ -e "$LATEST_LINK" ]; then
    rm "$LATEST_LINK"
fi
ln -s "$BUILD_DIR" "$LATEST_LINK"

echo "🎉 Build of spriced-ui completed successfully."
echo "Final build output available at: $BUILD_DIR"
echo "Symbolic link 'latest' created at: $LATEST_LINK"
exit 0

