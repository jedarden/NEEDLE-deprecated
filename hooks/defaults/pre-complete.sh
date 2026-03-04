#!/usr/bin/env bash
# ============================================================================
# NEEDLE Hook: pre-complete
# ============================================================================
#
# PURPOSE:
#   Runs BEFORE marking a bead as complete. Use this hook as a quality gate
#   to verify that work meets acceptance criteria before completion.
#
# WHEN CALLED:
#   After successful execution but before the bead is marked as complete.
#   This is your last chance to prevent completion if requirements aren't met.
#
# EXIT CODES:
#   0 - Success: Mark bead as complete
#   1 - Warning: Log warning but still complete
#   2 - Abort: Do NOT complete, keep bead in progress for rework
#   3 - Skip: Skip remaining pre-complete hooks but still complete
#
# ============================================================================
# AVAILABLE ENVIRONMENT VARIABLES
# ============================================================================
#
# NEEDLE_HOOK          - Name of this hook ("pre_complete")
# NEEDLE_BEAD_ID       - ID of the bead to complete
# NEEDLE_BEAD_TITLE    - Title of the bead
# NEEDLE_BEAD_PRIORITY - Priority level (0-4)
# NEEDLE_BEAD_TYPE     - Type of bead
# NEEDLE_BEAD_LABELS   - Comma-separated labels
# NEEDLE_WORKSPACE     - Path to workspace
# NEEDLE_SESSION       - Worker session ID
# NEEDLE_PID           - Process ID
# NEEDLE_WORKER        - Worker identifier
# NEEDLE_EXIT_CODE     - Exit code from execution
# NEEDLE_DURATION_MS   - Duration of execution
#
# ============================================================================
# EXAMPLE USE CASES
# ============================================================================
#
# 1. Run tests before allowing completion
# 2. Verify code coverage thresholds
# 3. Check for linting/type errors
# 4. Validate that required files exist
# 5. Ensure documentation is updated
# 6. Require code review before completion
#
# ============================================================================

set -euo pipefail

# ============================================================================
# QUALITY GATE EXAMPLES (Uncomment to enable)
# ============================================================================

echo "pre-complete hook called for bead: ${NEEDLE_BEAD_ID:-unknown}"
echo "  Title: ${NEEDLE_BEAD_TITLE:-}"
echo "  Exit code from execution: ${NEEDLE_EXIT_CODE:-unknown}"

# ----------------------------------------------------------------------------
# Example 1: Require tests to pass
# ----------------------------------------------------------------------------
# Uncomment to require passing tests:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# # Node.js/JavaScript project
# if [[ -f "package.json" ]]; then
#     echo "Running tests before completion..."
#     if npm test 2>&1; then
#         echo "Tests passed"
#     else
#         echo "Error: Tests failed - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi
#
# # Python project
# if [[ -f "pytest.ini" ]] || [[ -f "setup.py" ]] || [[ -f "pyproject.toml" ]]; then
#     echo "Running pytest before completion..."
#     if pytest --tb=short 2>&1; then
#         echo "Tests passed"
#     else
#         echo "Error: Tests failed - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi
#
# # Rust project
# if [[ -f "Cargo.toml" ]]; then
#     echo "Running cargo test before completion..."
#     if cargo test --quiet 2>&1; then
#         echo "Tests passed"
#     else
#         echo "Error: Tests failed - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 2: Require minimum code coverage
# ----------------------------------------------------------------------------
# Uncomment to enforce coverage threshold:
#
# MIN_COVERAGE=80
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if [[ -f "package.json" ]]; then
#     echo "Checking code coverage..."
#     coverage_output=$(npm run coverage 2>&1 || true)
#     coverage_percent=$(echo "$coverage_output" | grep -oP 'All files.*?(\d+\.?\d*)' | tail -1 | grep -oP '\d+\.?\d*$' || echo "0")
#
#     if (( $(echo "$coverage_percent < $MIN_COVERAGE" | bc -l) )); then
#         echo "Error: Code coverage ($coverage_percent%) below threshold ($MIN_COVERAGE%)"
#         exit 2  # Abort completion
#     fi
#     echo "Coverage check passed: $coverage_percent%"
# fi

# ----------------------------------------------------------------------------
# Example 3: Check for linting errors
# ----------------------------------------------------------------------------
# Uncomment to enforce lint-free code:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# # ESLint for JavaScript/TypeScript
# if [[ -f ".eslintrc.js" ]] || [[ -f ".eslintrc.json" ]]; then
#     echo "Running ESLint..."
#     if npx eslint . --max-warnings=0 2>&1; then
#         echo "No linting errors"
#     else
#         echo "Error: Linting errors found - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi
#
# # Ruff for Python
# if [[ -f "pyproject.toml" ]] && command -v ruff > /dev/null 2>&1; then
#     echo "Running Ruff linter..."
#     if ruff check . 2>&1; then
#         echo "No linting errors"
#     else
#         echo "Error: Linting errors found - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi
#
# # Clippy for Rust
# if [[ -f "Cargo.toml" ]]; then
#     echo "Running Clippy..."
#     if cargo clippy -- -D warnings 2>&1; then
#         echo "No Clippy warnings"
#     else
#         echo "Error: Clippy warnings found - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 4: Validate required deliverables exist
# ----------------------------------------------------------------------------
# Uncomment to verify files exist:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# REQUIRED_FILES=()
#
# # Add required files based on bead labels
# if [[ "${NEEDLE_BEAD_LABELS:-}" == *"api"* ]]; then
#     REQUIRED_FILES+=("docs/api.md")
# fi
#
# if [[ "${NEEDLE_BEAD_LABELS:-}" == *"feature"* ]]; then
#     REQUIRED_FILES+=("CHANGELOG.md")
# fi
#
# if [[ "${NEEDLE_BEAD_LABELS:-}" == *"database"* ]]; then
#     REQUIRED_FILES+=("migrations/")
# fi
#
# # Check each required file
# missing_files=()
# for file in "${REQUIRED_FILES[@]}"; do
#     if [[ ! -e "$file" ]]; then
#         missing_files+=("$file")
#     fi
# done
#
# if [[ ${#missing_files[@]} -gt 0 ]]; then
#     echo "Error: Missing required files: ${missing_files[*]}"
#     exit 2  # Abort completion
# fi

# ----------------------------------------------------------------------------
# Example 5: Check for uncommitted changes
# ----------------------------------------------------------------------------
# Uncomment to require clean git state:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if git rev-parse --git-dir > /dev/null 2>&1; then
#     if ! git diff --quiet 2>/dev/null || ! git diff --staged --quiet 2>/dev/null; then
#         echo "Error: Uncommitted changes detected"
#         echo "Please commit or stash changes before completing"
#         git status --short
#         exit 2  # Abort completion
#     fi
# fi

# ----------------------------------------------------------------------------
# Example 6: Verify build succeeds
# ----------------------------------------------------------------------------
# Uncomment to require successful build:
#
# cd "${NEEDLE_WORKSPACE:-.}" 2>/dev/null || exit 0
#
# if [[ -f "package.json" ]] && grep -q '"build"' package.json; then
#     echo "Running build..."
#     if npm run build 2>&1; then
#         echo "Build succeeded"
#     else
#         echo "Error: Build failed - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi
#
# if [[ -f "Cargo.toml" ]]; then
#     echo "Running cargo build..."
#     if cargo build --release 2>&1; then
#         echo "Build succeeded"
#     else
#         echo "Error: Build failed - cannot complete bead"
#         exit 2  # Abort completion
#     fi
# fi

# ============================================================================
# Default: Allow completion
# ============================================================================
echo "Quality gate passed for bead: ${NEEDLE_BEAD_ID:-unknown}"
exit 0
