#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: pre-execute
# ============================================================================
#
# PURPOSE:
#   Runs BEFORE starting work on a bead. Use this hook to set up the
#   environment, prepare resources, or validate prerequisites.
#
# WHEN CALLED:
#   After claiming a bead but before the worker starts executing the task.
#   This is your last chance to prepare before work begins.
#
# EXIT CODES:
#   0 - Success: Proceed with execution
#   1 - Warning: Log warning but proceed
#   2 - Abort: Don't execute, release bead back to available
#   3 - Skip: Skip remaining pre-execute hooks but still execute
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("pre_execute")
# NEEDLE_BEAD_ID       - ID of the bead to execute
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_AGENT         - Agent name
# NEEDLE_STRAND        - Strand ID
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Verify required tools are installed
# 2. Set up environment variables for the execution
# 3. Create temporary directories or files
# 4. Pull latest code changes
# 5. Start required services (databases, containers, etc.)
# 6. Validate system resources (disk space, memory)
#
# ============================================================================

set -euo pipefail

# ============================================================================
# ENVIRONMENT SETUP EXAMPLES (Uncomment to enable)
# ============================================================================

echo "pre-execute hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Workspace: ${NEEDLE_WORKSPACE:-}"
echo "  Working directory: $(pwd)"

# ----------------------------------------------------------------------------
# Example 1: Verify required tools are installed
# ----------------------------------------------------------------------------
# Uncomment to enable tool verification:
#
# REQUIRED_TOOLS=("git" "node" "npm" "docker")
# missing_tools=()
#
# for tool in "${REQUIRED_TOOLS[@]}"; do
#     if ! command -v "$tool" > /dev/null 2>&1; then
#         missing_tools+=("$tool")
#     fi
# done
#
# if [[ ${#missing_tools[@]} -gt 0 ]]; then
#     echo "Error: Missing required tools: ${missing_tools[*]}"
#     exit 2  # Abort execution
# fi
#
# echo "All required tools verified"

# ----------------------------------------------------------------------------
# Example 2: Set up environment variables
# ----------------------------------------------------------------------------
# Uncomment to set custom environment variables:
#
# export NODE_ENV="development"
# export DEBUG="needle:*"
# export LOG_LEVEL="verbose"
#
# # Set project-specific variables based on labels
# if [[ "${NEEDLE_BEAD_LABELS:-}" == *"rust"* ]]; then
#     export CARGO_INCREMENTAL=1
#     export RUST_BACKTRACE=1
# fi
#
# if [[ "${NEEDLE_BEAD_LABELS:-}" == *"python"* ]]; then
#     export PYTHONUNBUFFERED=1
#     export PYTHONDONTWRITEBYTECODE=1
# fi

# ----------------------------------------------------------------------------
# Example 3: Create temporary directories
# ----------------------------------------------------------------------------
# Uncomment to create temp directories:
#
# TEMP_DIR="/tmp/needle-${NEEDLE_BEAD_ID:-$$}"
# mkdir -p "$TEMP_DIR"
# export NEEDLE_TEMP_DIR="$TEMP_DIR"
#
# # Create subdirectories
# mkdir -p "$TEMP_DIR/logs"
# mkdir -p "$TEMP_DIR/artifacts"
# mkdir -p "$TEMP_DIR/cache"
#
# echo "Created temp directory: $TEMP_DIR"

# ----------------------------------------------------------------------------
# Example 4: Pull latest changes from git
# ----------------------------------------------------------------------------
# Uncomment to sync git repository:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if git rev-parse --git-dir > /dev/null 2>&1; then
#     echo "Syncing git repository..."
#
#     # Stash any uncommitted changes
#     if ! git diff --quiet 2>/dev/null; then
#         echo "Stashing uncommitted changes..."
#         git stash push -m "pre-execute stash for ${NEEDLE_BEAD_ID:-}"
#     fi
#
#     # Pull latest changes
#     git fetch origin 2>/dev/null || true
#     git rebase origin/main 2>/dev/null || {
#         echo "Warning: Git rebase failed, continuing anyway"
#     }
#
#     echo "Git repository synchronized"
# fi

# ----------------------------------------------------------------------------
# Example 5: Start required services
# ----------------------------------------------------------------------------
# Uncomment to start services:
#
# # Check if Docker is available
# if command -v docker > /dev/null 2>&1; then
#     # Start a test database if needed
#     if [[ "${NEEDLE_BEAD_LABELS:-}" == *"database"* ]]; then
#         echo "Starting test database..."
#         docker run -d --name "test-db-${NEEDLE_BEAD_ID:-test}" \
#             -e POSTGRES_PASSWORD=test \
#             -p 5432:5432 \
#             postgres:15 > /dev/null 2>&1 || true
#
#         # Wait for database to be ready
#         sleep 3
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 6: Validate system resources
# ----------------------------------------------------------------------------
# Uncomment to check resources:
#
# # Check available disk space (require at least 1GB free)
# available_kb=$(df -k "${NEEDLE_WORKSPACE:-/tmp}" | awk 'NR==2 {print $4}')
# min_required_kb=$((1024 * 1024))  # 1GB
#
# if [[ "$available_kb" -lt "$min_required_kb" ]]; then
#     echo "Error: Insufficient disk space (available: ${available_kb}KB, required: ${min_required_kb}KB)"
#     exit 2  # Abort execution
# fi
#
# # Check available memory (require at least 512MB free)
# if command -v free > /dev/null 2>&1; then
#     available_mb=$(free -m | awk '/^Mem:/{print $7}')
#     min_memory_mb=512
#
#     if [[ "$available_mb" -lt "$min_memory_mb" ]]; then
#         echo "Warning: Low memory (available: ${available_mb}MB)"
#         # Continue anyway, just warn
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 7: Install project dependencies
# ----------------------------------------------------------------------------
# Uncomment to install dependencies:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# # Node.js project
# if [[ -f "package.json" ]]; then
#     echo "Ensuring npm dependencies are installed..."
#     if [[ ! -d "node_modules" ]] || [[ "package.json" -nt "node_modules" ]]; then
#         npm ci --prefer-offline 2>/dev/null || npm install 2>/dev/null || {
#             echo "Warning: npm install failed"
#         }
#     fi
# fi
#
# # Python project
# if [[ -f "requirements.txt" ]]; then
#     echo "Ensuring Python dependencies are installed..."
#     pip install -q -r requirements.txt 2>/dev/null || {
#         echo "Warning: pip install failed"
#     }
# fi
#
# # Rust project
# if [[ -f "Cargo.toml" ]]; then
#     echo "Ensuring Rust dependencies are downloaded..."
#     cargo fetch 2>/dev/null || {
#         echo "Warning: cargo fetch failed"
#     }
# fi

# ============================================================================
# Default: Proceed with execution
# ============================================================================
echo "Pre-execution setup complete for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
