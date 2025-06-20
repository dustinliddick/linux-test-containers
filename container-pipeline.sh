#!/bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/container-test.log"

# Default configuration using individual variables
CONFIG_VERBOSE=false
CONFIG_QUIET=false
CONFIG_BUILD_ONLY=false
CONFIG_TEST_ONLY=false
CONFIG_PUSH_ONLY=false
CONFIG_NO_CLEANUP=false
CONFIG_TIMEOUT=10
CONFIG_REGISTRY=""
CONFIG_REGISTRY_PREFIX=""
CONFIG_TAG_LATEST=false
CONFIG_DRY_RUN=false
CONFIG_PARALLEL_JOBS=1

# Arrays using space-separated strings
TARGET_DISTROS=""
FAILED_OPERATIONS=""
SUCCESSFUL_OPERATIONS=""

# Logging functions
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        "ERROR"|"FATAL")
            echo "$timestamp - $level: $message" | tee -a "$LOG_FILE" >&2
            ;;
        "WARNING")
            echo "$timestamp - $level: $message" | tee -a "$LOG_FILE"
            ;;
        "INFO")
            if [ "$CONFIG_QUIET" = "false" ]; then
                echo "$timestamp - $message" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - $message" >> "$LOG_FILE"
            fi
            ;;
        "DEBUG")
            if [ "$CONFIG_VERBOSE" = "true" ]; then
                echo "$timestamp - DEBUG: $message" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - DEBUG: $message" >> "$LOG_FILE"
            fi
            ;;
        "SUCCESS")
            if [ "$CONFIG_QUIET" = "false" ]; then
                echo "$timestamp - ✓ $message" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - ✓ $message" >> "$LOG_FILE"
            fi
            ;;
        *)
            # Backward compatibility - treat as INFO
            if [ "$CONFIG_QUIET" = "false" ]; then
                echo "$timestamp - $level" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - $level" >> "$LOG_FILE"
            fi
            ;;
    esac
}

log_error() { log "ERROR" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_info() { log "INFO" "$1"; }
log_debug() { log "DEBUG" "$1"; }
log_success() { log "SUCCESS" "$1"; }

# Utility functions
die() {
    log "FATAL" "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Helper functions for POSIX array handling
add_to_list() {
    list_name="$1"
    value="$2"
    eval "current_value=\$$list_name"
    if [ -z "$current_value" ]; then
        eval "$list_name='$value'"
    else
        eval "$list_name='$current_value $value'"
    fi
}

list_contains() {
    list="$1"
    item="$2"
    for list_item in $list; do
        if [ "$list_item" = "$item" ]; then
            return 0
        fi
    done
    return 1
}

count_list_items() {
    list="$1"
    count=0
    for item in $list; do
        count=$((count + 1))
    done
    echo $count
}

validate_dependencies() {
    missing_deps=""
    
    if ! command_exists docker; then
        missing_deps="docker"
    fi
    
    if [ -n "$CONFIG_REGISTRY" ] && ! command_exists docker; then
        missing_deps="$missing_deps docker (for registry operations)"
    fi
    
    if [ -n "$missing_deps" ]; then
        die "Missing required dependencies: $missing_deps"
    fi
}

show_help() {
    cat << 'EOF'
Container Build, Test, and Registry Push Automation Script

USAGE:
    ./container-test.sh [OPTIONS] [DISTRO] [VERSION]

BUILD OPTIONS:
    -h, --help              Show this help message
    -l, --list              List available containers
    -d, --distro DISTRO     Target specific distribution(s) (can be used multiple times)
    -v, --verbose           Enable verbose output
    -q, --quiet             Quiet mode (errors only)
    --build-only            Build containers only, skip tests and push
    --test-only             Test only, skip builds and push (assumes images exist)
    --push-only             Push only, skip builds and tests (assumes images exist)
    --no-cleanup            Skip cleanup of test containers
    --timeout SECONDS       Custom test timeout (default: 10)
    --log-file PATH         Custom log file path (default: container-test.log)
    --parallel JOBS         Number of parallel operations (default: 1)
    --dry-run               Show what would be done without executing

REGISTRY OPTIONS:
    --registry REGISTRY     Target registry (e.g., docker.io, ghcr.io, registry.company.com)
    --prefix PREFIX         Registry prefix/namespace (e.g., mycompany, username)
    --tag-latest            Also tag and push as 'latest'

EXAMPLES:
    # Basic operations
    ./container-test.sh                          # Test all containers
    ./container-test.sh alpine 3.19              # Test specific container (legacy format)
    ./container-test.sh -d alpine               # Test all Alpine containers
    ./container-test.sh -d alpine -d ubuntu      # Test Alpine and Ubuntu containers
    
    # Build and test
    ./container-test.sh --build-only -v          # Build all containers with verbose output
    ./container-test.sh --test-only -d fedora    # Test existing Fedora containers only
    
    # Registry operations
    ./container-test.sh --registry docker.io --prefix myuser -d alpine
    ./container-test.sh --registry ghcr.io --prefix myorg --tag-latest --build-only
    ./container-test.sh --push-only --registry myregistry.com --prefix myteam
    
    # Advanced usage
    ./container-test.sh --parallel 4 --registry docker.io --prefix myuser
    ./container-test.sh --dry-run --registry ghcr.io --prefix myorg --tag-latest

REGISTRY FORMATS:
    Images will be tagged as: REGISTRY/PREFIX/DISTRO:VERSION
    Examples:
    - docker.io/myuser/alpine:3.19
    - ghcr.io/myorg/ubuntu:22.04
    - registry.company.com/team/fedora:39

DISTRIBUTIONS:
    The script auto-discovers containers from subdirectories containing Dockerfiles.
    Common distributions: alpine, ubuntu, debian, fedora, amazon, el, rocky, centos

EOF
}

list_containers() {
    log_info "Scanning for available containers..."
    
    # Create a temporary file to collect containers since POSIX doesn't support process substitution
    temp_file="$(mktemp)"
    find "$SCRIPT_DIR" -name "Dockerfile" -type f | sort > "$temp_file"
    
    containers=""
    container_count=0
    
    while read -r dockerfile; do
        if [ -n "$dockerfile" ]; then
            rel_path="${dockerfile#$SCRIPT_DIR/}"
            distro=$(dirname "$rel_path" | cut -d'/' -f1)
            version=$(dirname "$rel_path" | cut -d'/' -f2)
            containers="$containers $distro/$version"
            container_count=$((container_count + 1))
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"

    if [ "$container_count" -eq 0 ]; then
        log_warning "No containers found in $SCRIPT_DIR"
        return 1
    fi

    echo "Available containers:"
    for container in $containers; do
        echo "  $container"
    done
    echo
    echo "Total: $container_count containers"
}

get_image_name() {
    distro="$1"
    version="$2"
    base_name="$distro-$version"
    
    if [ -n "$CONFIG_REGISTRY" ] && [ -n "$CONFIG_REGISTRY_PREFIX" ]; then
        echo "$CONFIG_REGISTRY/$CONFIG_REGISTRY_PREFIX/$base_name"
    elif [ -n "$CONFIG_REGISTRY_PREFIX" ]; then
        echo "$CONFIG_REGISTRY_PREFIX/$base_name"
    else
        echo "test-$base_name"
    fi
}

get_container_name() {
    distro="$1"
    version="$2"
    echo "test-container-$distro-$version-$$"
}

registry_login() {
    if [ -z "$CONFIG_REGISTRY" ]; then
        return 0
    fi
    
    log_debug "Checking registry authentication for $CONFIG_REGISTRY"
    
    # Check if already logged in by trying to get auth info
    if ! docker system info 2>/dev/null | grep -q "Registry:"; then
        log_warning "Docker registry authentication may be required"
        log_info "Please ensure you're logged in with: docker login $CONFIG_REGISTRY"
    fi
}

build_container() {
    distro="$1"
    version="$2"
    dockerfile_path="$SCRIPT_DIR/$distro/$version/Dockerfile"
    image_name=$(get_image_name "$distro" "$version")

    if [ ! -f "$dockerfile_path" ]; then
        log_error "Dockerfile not found at $dockerfile_path"
        return 1
    fi

    log_info "Building $image_name"
    log_debug "Build context: $SCRIPT_DIR/$distro/$version/"
    log_debug "Dockerfile: $dockerfile_path"

    if [ "$CONFIG_DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would build: docker build -t '$image_name' '$SCRIPT_DIR/$distro/$version/'"
        return 0
    fi

    # Build command parts
    build_cmd="docker build -t '$image_name'"
    
    # Add latest tag if requested and we have registry info
    if [ "$CONFIG_TAG_LATEST" = "true" ] && [ -n "$CONFIG_REGISTRY" ]; then
        if [ -n "$CONFIG_REGISTRY_PREFIX" ]; then
            latest_tag="$CONFIG_REGISTRY/$CONFIG_REGISTRY_PREFIX/$distro:latest"
        else
            latest_tag="$CONFIG_REGISTRY/$distro:latest"
        fi
        build_cmd="$build_cmd -t '$latest_tag'"
        log_debug "Also tagging as: $latest_tag"
    fi

    build_cmd="$build_cmd '$SCRIPT_DIR/$distro/$version/'"

    if ! eval "$build_cmd"; then
        log_error "Failed to build $image_name"
        return 1
    fi
    
    log_success "Built $image_name"
    return 0
}

test_container() {
    local distro="$1"
    local version="$2"
    local image_name
    local container_name
    image_name=$(get_image_name "$distro" "$version")
    container_name=$(get_container_name "$distro" "$version")

    # Verify image exists
    if ! docker image inspect "$image_name" > /dev/null 2>&1; then
        log_error "Image $image_name not found (required for testing)"
        return 1
    fi

    if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
        log_info "[DRY RUN] Would test container: $image_name"
        return 0
    fi

    log_info "Testing container $container_name"
    log_debug "Image: $image_name"

    # Start container
    local run_args=(
        "-d" "--name" "$container_name" 
        "--label" "test-container=true"
        "--label" "test-script-pid=$$"
        "--privileged" 
        "--tmpfs" "/tmp" 
        "--tmpfs" "/run"
        "-v" "/sys/fs/cgroup:/sys/fs/cgroup:ro"
    )

    if ! docker run "${run_args[@]}" "$image_name"; then
        log_error "Failed to start container $container_name"
        return 1
    fi

    # Wait for container to initialize
    log_debug "Waiting 5 seconds for container to initialize..."
    sleep 5

    local test_failed=false

    # Test 1: Container is running
    log_debug "Test 1: Checking if container is running"
    if ! docker ps --filter "name=$container_name" --filter "status=running" | grep -q "$container_name"; then
        log_error "Container $container_name is not running"
        test_failed=true
    else
        log_debug "✓ Container is running"
    fi

    # Test 2: Basic command execution
    if [[ "$test_failed" == "false" ]]; then
        log_debug "Test 2: Testing basic command execution"
        if ! docker exec "$container_name" /bin/sh -c "echo 'Hello World'" > /dev/null 2>&1; then
            log_error "Cannot execute commands in container $container_name"
            test_failed=true
        else
            log_debug "✓ Command execution works"
        fi
    fi

    # Test 3: File system operations
    if [[ "$test_failed" == "false" ]]; then
        log_debug "Test 3: Testing file system operations"
        if ! docker exec "$container_name" /bin/sh -c "touch /tmp/test-file && rm /tmp/test-file" > /dev/null 2>&1; then
            log_error "File system operations failed in $container_name"
            test_failed=true
        else
            log_debug "✓ File system operations work"
        fi
    fi

    # Test 4: Package manager availability (distro-specific)
    if [[ "$test_failed" == "false" ]]; then
        log_debug "Test 4: Testing package manager availability"
        test_package_manager "$container_name" "$distro"
    fi

    # Test 5: Network connectivity (optional)
    if [[ "$test_failed" == "false" ]]; then
        log_debug "Test 5: Testing network connectivity (optional)"
        test_network_connectivity "$container_name"
    fi

    # Cleanup container
    log_debug "Stopping and removing test container $container_name"
    docker stop "$container_name" > /dev/null 2>&1 || true
    docker rm "$container_name" > /dev/null 2>&1 || true

    if [[ "$test_failed" == "true" ]]; then
        return 1
    fi

    log_success "All tests passed for $distro/$version"
    return 0
}

test_package_manager() {
    local container_name="$1"
    local distro="$2"

    case "$distro" in
        alpine)
            if docker exec "$container_name" which apk > /dev/null 2>&1; then
                log_debug "✓ Package manager (apk) available"
            else
                log_warning "Package manager (apk) not found"
            fi
            ;;
        ubuntu|debian)
            if docker exec "$container_name" which apt > /dev/null 2>&1; then
                log_debug "✓ Package manager (apt) available"
            else
                log_warning "Package manager (apt) not found"
            fi
            ;;
        fedora|rocky|centos)
            if docker exec "$container_name" which dnf > /dev/null 2>&1; then
                log_debug "✓ Package manager (dnf) available"
            elif docker exec "$container_name" which yum > /dev/null 2>&1; then
                log_debug "✓ Package manager (yum) available"
            else
                log_warning "Package manager (dnf/yum) not found"
            fi
            ;;
        amazon)
            if docker exec "$container_name" which yum > /dev/null 2>&1; then
                log_debug "✓ Package manager (yum) available"
            else
                log_warning "Package manager (yum) not found"
            fi
            ;;
        el)
            if docker exec "$container_name" which dnf > /dev/null 2>&1 || docker exec "$container_name" which yum > /dev/null 2>&1; then
                log_debug "✓ Package manager available"
            else
                log_warning "Package manager not found"
            fi
            ;;
        *)
            log_debug "Unknown distro '$distro', skipping package manager test"
            ;;
    esac
}

test_network_connectivity() {
    local container_name="$1"
    
    if docker exec "$container_name" which curl > /dev/null 2>&1; then
        if timeout "${CONFIG[TIMEOUT]}" docker exec "$container_name" curl -s --connect-timeout "${CONFIG[TIMEOUT]}" https://httpbin.org/ip > /dev/null 2>&1; then
            log_debug "✓ Network connectivity works"
        else
            log_warning "Network connectivity test failed (this may be expected in restricted environments)"
        fi
    else
        log_debug "curl not available, skipping network test"
    fi
}

push_container() {
    local distro="$1"
    local version="$2"
    local image_name
    image_name=$(get_image_name "$distro" "$version")

    if [[ -z "${CONFIG[REGISTRY]}" ]]; then
        log_warning "No registry specified, skipping push for $distro/$version"
        return 0
    fi

    # Verify image exists
    if ! docker image inspect "$image_name" > /dev/null 2>&1; then
        log_error "Image $image_name not found (required for pushing)"
        return 1
    fi

    if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
        log_info "[DRY RUN] Would push: $image_name"
        if [[ "${CONFIG[TAG_LATEST]}" == "true" ]]; then
            local latest_tag="${CONFIG[REGISTRY]}/${CONFIG[REGISTRY_PREFIX]}/$distro:latest"
            log_info "[DRY RUN] Would also push: $latest_tag"
        fi
        return 0
    fi

    log_info "Pushing $image_name to registry"
    
    if ! docker push "$image_name"; then
        log_error "Failed to push $image_name"
        return 1
    fi

    # Push latest tag if requested
    if [[ "${CONFIG[TAG_LATEST]}" == "true" ]]; then
        local latest_tag="${CONFIG[REGISTRY]}/${CONFIG[REGISTRY_PREFIX]}/$distro:latest"
        log_info "Pushing latest tag: $latest_tag"
        if ! docker push "$latest_tag"; then
            log_error "Failed to push $latest_tag"
            return 1
        fi
    fi

    log_success "Pushed $image_name"
    return 0
}

should_process_distro() {
    distro="$1"

    # If no target distros specified, process all
    if [ -z "$TARGET_DISTROS" ]; then
        return 0
    fi

    # Check if distro is in target list
    if list_contains "$TARGET_DISTROS" "$distro"; then
        return 0
    fi

    return 1
}

cleanup_containers() {
    if [[ "${CONFIG[NO_CLEANUP]}" == "true" ]]; then
        log_debug "Skipping cleanup due to --no-cleanup flag"
        return
    fi

    log_info "Cleaning up test containers..."
    
    # Clean up containers created by this script instance
    local cleanup_filter="label=test-script-pid=$$"
    local containers
    containers=$(docker ps -aq --filter "$cleanup_filter" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | xargs docker rm -f > /dev/null 2>&1 || true
        log_debug "Cleaned up containers from this script run"
    fi
    
    # Also clean up any containers with the general test-container label
    containers=$(docker ps -aq --filter "label=test-container=true" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        echo "$containers" | xargs docker rm -f > /dev/null 2>&1 || true
        log_debug "Cleaned up orphaned test containers"
    fi
}

process_container() {
    local distro="$1"
    local version="$2"
    local operation_count=0
    local failed_operations=()

    log_info "Processing $distro/$version"

    # Build phase
    if [[ "${CONFIG[BUILD_ONLY]}" == "true" || ("${CONFIG[TEST_ONLY]}" == "false" && "${CONFIG[PUSH_ONLY]}" == "false") ]]; then
        ((operation_count++))
        if ! build_container "$distro" "$version"; then
            failed_operations+=("build")
        fi
    fi

    # Test phase
    if [[ "${CONFIG[TEST_ONLY]}" == "true" || ("${CONFIG[BUILD_ONLY]}" == "false" && "${CONFIG[PUSH_ONLY]}" == "false") ]]; then
        ((operation_count++))
        if ! test_container "$distro" "$version"; then
            failed_operations+=("test")
        fi
    fi

    # Push phase
    if [[ "${CONFIG[PUSH_ONLY]}" == "true" || (("${CONFIG[BUILD_ONLY]}" == "false" && "${CONFIG[TEST_ONLY]}" == "false") && -n "${CONFIG[REGISTRY]}") ]]; then
        ((operation_count++))
        if ! push_container "$distro" "$version"; then
            failed_operations+=("push")
        fi
    fi

    # Record results
    if [[ ${#failed_operations[@]} -gt 0 ]]; then
        FAILED_OPERATIONS+=("$distro/$version (${failed_operations[*]})")
        return 1
    else
        SUCCESSFUL_OPERATIONS+=("$distro/$version")
        return 0
    fi
}

# Helper function to check if string is a positive integer
is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

validate_configuration() {
    # Validate conflicting options
    exclusive_count=0
    [ "$CONFIG_BUILD_ONLY" = "true" ] && exclusive_count=$((exclusive_count + 1))
    [ "$CONFIG_TEST_ONLY" = "true" ] && exclusive_count=$((exclusive_count + 1))
    [ "$CONFIG_PUSH_ONLY" = "true" ] && exclusive_count=$((exclusive_count + 1))

    if [ $exclusive_count -gt 1 ]; then
        die "Cannot specify multiple exclusive options: --build-only, --test-only, --push-only"
    fi

    if [ "$CONFIG_VERBOSE" = "true" ] && [ "$CONFIG_QUIET" = "true" ]; then
        die "Cannot specify both --verbose and --quiet"
    fi

    # Validate registry configuration
    if [ -n "$CONFIG_REGISTRY" ] && [ -z "$CONFIG_REGISTRY_PREFIX" ]; then
        log_warning "Registry specified without prefix. Images will be tagged directly under registry root."
    fi

    # Validate timeout
    if ! is_positive_integer "$CONFIG_TIMEOUT"; then
        die "Timeout must be a positive integer"
    fi

    # Validate parallel jobs
    if ! is_positive_integer "$CONFIG_PARALLEL_JOBS"; then
        die "Parallel jobs must be a positive integer"
    fi
}

main() {
    validate_dependencies
    validate_configuration

    log_info "Starting container automation pipeline"

    if [[ "${CONFIG[VERBOSE]}" == "true" ]]; then
        log_debug "Configuration:"
        for key in "${!CONFIG[@]}"; do
            log_debug "  $key=${CONFIG[$key]}"
        done
        log_debug "  TARGET_DISTROS=(${TARGET_DISTROS[*]})"
    fi

    # Initialize log file
    > "$LOG_FILE"

    # Registry authentication check
    if [[ -n "${CONFIG[REGISTRY]}" ]]; then
        registry_login
    fi

    processed_count=0
    containers_to_process=""

    # Discover containers to process
    temp_file="$(mktemp)"
    find "$SCRIPT_DIR" -name "Dockerfile" -type f | sort > "$temp_file"
    
    while read -r dockerfile; do
        if [ -n "$dockerfile" ]; then
            rel_path="${dockerfile#$SCRIPT_DIR/}"
            distro=$(dirname "$rel_path" | cut -d'/' -f1)
            version=$(dirname "$rel_path" | cut -d'/' -f2)

            if should_process_distro "$distro"; then
                add_to_list containers_to_process "$distro/$version"
            else
                log_debug "Skipping $distro/$version (not in target distros)"
            fi
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"

    container_count=$(count_list_items "$containers_to_process")
    if [ "$container_count" -eq 0 ]; then
        log_warning "No containers found to process"
        if [ -n "$TARGET_DISTROS" ]; then
            log_info "Target distros: $TARGET_DISTROS"
        fi
        exit 1
    fi

    log_info "Found $container_count containers to process"

    # Process containers
    for container_spec in $containers_to_process; do
        distro="${container_spec%/*}"
        version="${container_spec#*/}"
        
        processed_count=$((processed_count + 1))
        
        if process_container "$distro" "$version"; then
            log_debug "Successfully processed $container_spec"
        else
            log_debug "Failed to process $container_spec"
        fi

        if [ "$CONFIG_QUIET" = "false" ] && [ $processed_count -lt $container_count ]; then
            echo "---"
        fi
    done

    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [[ ${#FAILED_OPERATIONS[@]} -gt 0 ]]; then
        exit 1
    fi
}

print_summary() {
    log_info "=== EXECUTION SUMMARY ==="
    log_info "Processed: ${#SUCCESSFUL_OPERATIONS[@]} successful, ${#FAILED_OPERATIONS[@]} failed"
    
    if [[ ${#SUCCESSFUL_OPERATIONS[@]} -gt 0 ]]; then
        log_info "Successful operations:"
        for success in "${SUCCESSFUL_OPERATIONS[@]}"; do
            log_success "$success"
        done
    fi

    if [[ ${#FAILED_OPERATIONS[@]} -gt 0 ]]; then
        log_info "Failed operations:"
        for failure in "${FAILED_OPERATIONS[@]}"; do
            log_error "$failure"
        done
        log_error "Check $LOG_FILE for detailed error information"
    else
        log_success "All operations completed successfully!"
    fi

    if [[ -n "${CONFIG[REGISTRY]}" && "${CONFIG[PUSH_ONLY]}" != "true" ]]; then
        log_info "Registry: ${CONFIG[REGISTRY]}"
        if [[ -n "${CONFIG[REGISTRY_PREFIX]}" ]]; then
            log_info "Prefix: ${CONFIG[REGISTRY_PREFIX]}"
        fi
    fi
}

# Cleanup trap
trap cleanup_containers EXIT

# Command line argument parsing
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_containers
                exit 0
                ;;
            -d|--distro)
                [ -z "$2" ] && die "Error: --distro requires a value"
                TARGET_DISTROS="$TARGET_DISTROS $2"
                shift 2
                ;;
            -v|--verbose)
                CONFIG_VERBOSE=true
                shift
                ;;
            -q|--quiet)
                CONFIG_QUIET=true
                shift
                ;;
            --build-only)
                CONFIG_BUILD_ONLY=true
                shift
                ;;
            --test-only)
                CONFIG_TEST_ONLY=true
                shift
                ;;
            --push-only)
                CONFIG_PUSH_ONLY=true
                shift
                ;;
            --no-cleanup)
                CONFIG_NO_CLEANUP=true
                shift
                ;;
            --timeout)
                [ -z "$2" ] && die "Error: --timeout requires a value"
                CONFIG_TIMEOUT="$2"
                shift 2
                ;;
            --log-file)
                [ -z "$2" ] && die "Error: --log-file requires a value"
                LOG_FILE="$2"
                shift 2
                ;;
            --registry)
                [ -z "$2" ] && die "Error: --registry requires a value"
                CONFIG_REGISTRY="$2"
                shift 2
                ;;
            --prefix)
                [ -z "$2" ] && die "Error: --prefix requires a value"
                CONFIG_REGISTRY_PREFIX="$2"
                shift 2
                ;;
            --tag-latest)
                CONFIG_TAG_LATEST=true
                shift
                ;;
            --parallel)
                [ -z "$2" ] && die "Error: --parallel requires a value"
                CONFIG_PARALLEL_JOBS="$2"
                shift 2
                ;;
            --dry-run)
                CONFIG_DRY_RUN=true
                shift
                ;;
            -*)
                die "Error: Unknown option $1. Use --help for usage information"
                ;;
            *)
                # Support legacy format: script.sh distro version
                if [[ $# -eq 2 && ${#TARGET_DISTROS[@]} -eq 0 ]]; then
                    if process_container "$1" "$2"; then
                        exit 0
                    else
                        exit 1
                    fi
                else
                    die "Error: Invalid argument $1. Use --help for usage information"
                fi
                ;;
        esac
    done
}

# Script entry point
parse_arguments "$@"
main
