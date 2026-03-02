#!/usr/bin/env bash
# NEEDLE CLI JSON Utilities
# JSON/JSONL formatting and output functions

# Escape a string for JSON output
# Usage: _needle_json_escape <string>
_needle_json_escape() {
    local str="$1"
    # Escape backslashes, quotes, and control characters
    str="${str//\\/\\\\}"      # Backslash
    str="${str//\"/\\\"}"      # Double quote
    str="${str//$'\n'/\\n}"    # Newline
    str="${str//$'\r'/\\r}"    # Carriage return
    str="${str//$'\t'/\\t}"    # Tab
    printf '%s' "$str"
}

# Emit a JSONL event (single line JSON)
# Usage: _needle_json_emit --type <type> [--key value]...
# Example: _needle_json_emit --type status --message "Running" --progress 50
_needle_json_emit() {
    local type=""
    local -A fields=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                type="$2"
                shift 2
                ;;
            --*)
                local key="${1#--}"
                local value="$2"
                fields["$key"]="$value"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Build JSON object
    local json="{"
    local first=true

    # Add timestamp
    json+="\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    first=false

    # Add type if provided
    if [[ -n "$type" ]]; then
        json+=",\"type\":\"$(_needle_json_escape "$type")\""
    fi

    # Add all fields
    for key in "${!fields[@]}"; do
        local value="${fields[$key]}"

        # Detect value type (number, boolean, or string)
        if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            # Number - no quotes
            json+=",\"$key\":$value"
        elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
            # Boolean - no quotes
            json+=",\"$key\":$value"
        elif [[ "$value" == "null" ]]; then
            # Null - no quotes
            json+=",\"$key\":null"
        else
            # String - escape and quote
            json+=",\"$key\":\"$(_needle_json_escape "$value")\""
        fi
    done

    json+="}"

    printf '%s\n' "$json"
}

# Emit a structured event with standard fields
# Usage: _needle_emit_event <event_type> <message> [extra_key=value...]
# Example: _needle_emit_event "progress" "Processing files" "percent=50" "files=10"
_needle_emit_event() {
    local event_type="$1"
    local message="$2"
    shift 2

    local args=(
        --type "$event_type"
        --message "$message"
    )

    # Parse extra key=value pairs
    for pair in "$@"; do
        if [[ "$pair" == *=* ]]; then
            local key="${pair%%=*}"
            local value="${pair#*=}"
            args+=("--$key" "$value")
        fi
    done

    _needle_json_emit "${args[@]}"
}

# Emit a status event
# Usage: _needle_emit_status <status> [message]
_needle_emit_status() {
    local status="$1"
    local message="${2:-}"
    _needle_emit_event "status" "$message" "status=$status"
}

# Emit a progress event
# Usage: _needle_emit_progress <current> <total> [message]
_needle_emit_progress() {
    local current="$1"
    local total="$2"
    local message="${3:-Progress}"

    local percent=0
    if [[ $total -gt 0 ]]; then
        percent=$((current * 100 / total))
    fi

    _needle_emit_event "progress" "$message" "current=$current" "total=$total" "percent=$percent"
}

# Emit an error event
# Usage: _needle_emit_error <message> [code]
_needle_emit_error() {
    local message="$1"
    local code="${2:-1}"
    _needle_emit_event "error" "$message" "code=$code" "success=false"
}

# Emit a completion event
# Usage: _needle_emit_complete <message> [result]
_needle_emit_complete() {
    local message="$1"
    local result="${2:-success}"
    _needle_emit_event "complete" "$message" "result=$result" "success=true"
}

# Create a JSON array from arguments
# Usage: _needle_json_array "item1" "item2" "item3"
_needle_json_array() {
    local items=("$@")
    local json="["
    local first=true

    for item in "${items[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json+=","
        fi

        # Detect if it's a number or string
        if [[ "$item" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            json+="$item"
        else
            json+="\"$(_needle_json_escape "$item")\""
        fi
    done

    json+="]"
    printf '%s' "$json"
}

# Create a JSON object from key=value pairs
# Usage: _needle_json_object "key1=value1" "key2=value2"
_needle_json_object() {
    local json="{"
    local first=true

    for pair in "$@"; do
        if [[ "$pair" == *=* ]]; then
            local key="${pair%%=*}"
            local value="${pair#*=}"

            if [[ "$first" == "true" ]]; then
                first=false
            else
                json+=","
            fi

            # Detect value type
            if [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
                json+="\"$key\":$value"
            elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
                json+="\"$key\":$value"
            elif [[ "$value" == "null" ]]; then
                json+="\"$key\":null"
            else
                json+="\"$key\":\"$(_needle_json_escape "$value")\""
            fi
        fi
    done

    json+="}"
    printf '%s' "$json"
}
