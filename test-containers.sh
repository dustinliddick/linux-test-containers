#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/container-test.log"

# Default options
VERBOSE=false
QUIET=false
BUILD_ONLY=false
TEST_ONLY=false
NO_CLEANUP=false
TIMEOUT=10
TARGET_DISTROS=()

log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "$level" in
        "ERROR"|"WARNING")
            echo "$timestamp - $level: $message" | tee -a "$LOG_FILE"
            ;;
        "INFO")
            if [[ "$QUIET" == "false" ]]; then
                echo "$timestamp - $message" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - $message" >> "$LOG_FILE"
            fi
            ;;
        "DEBUG")
            if [[ "$VERBOSE" == "true" ]]; then
                echo "$timestamp - DEBUG: $message" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - DEBUG: $message" >> "$LOG_FILE"
            fi
            ;;
        *)
            # Backward compatibility - treat as INFO
            if [[ "$QUIET" == "false" ]]; then
                echo "$timestamp - $level" | tee -a "$LOG_FILE"
            else
                echo "$timestamp - $level" >> "$LOG_FILE"
            fi
            ;;
    esac
}

show_help() {
    cat << EOF
Container Build and Test Automation Script

USAGE:
    $0 [OPTIONS] [DISTRO] [VERSION]

OPTIONS:
    -h, --help              Show this help message
    -l, --list              List available containers
    -d, --distro DISTRO     Target specific distribution(s) (can be used multiple times)
    -v, --verbose           Enable verbose output
    -q, --quiet             Quiet mode (errors only)
    --build-only            Build containers only, skip tests
    --test-only             Test only, skip builds (assumes images exist)
    --no-cleanup            Skip cleanup of test containers
    --timeout SECONDS       Custom test timeout (default: 10)
    --log-file PATH         Custom log file path (default: container-test.log)

EXAMPLES:
    $0                          # Test all containers
    $0 alpine 3.19              # Test specific container (legacy format)
    $0 -d alpine               # Test all Alpine containers
    $0 -d alpine -d ubuntu      # Test Alpine and Ubuntu containers
    $0 --build-only -v          # Build all containers with verbose output
    $0 --list                   # List available containers
    $0 --test-only -d fedora    # Test existing Fedora containers only

DISTRIBUTIONS:
    The script auto-discovers containers from subdirectories containing Dockerfiles.
    Common distributions: alpine, ubuntu, debian, fedora, amazon, el

EOF
}

list_containers() {
    log "INFO" "Available containers:"
    local containers=()
    
    while IFS= read -r -d '' dockerfile; do
        local rel_path="${dockerfile#$SCRIPT_DIR/}"
        local distro=$(dirname "$rel_path" | cut -d'/' -f1)
        local version=$(dirname "$rel_path" | cut -d'/' -f2)
        containers+=("$distro/$version")
    done < <(find "$SCRIPT_DIR" -name "Dockerfile" -type f -print0 | sort -z)
    
    for container in "${containers[@]}"; do
        echo "  $container"
    done
    
    echo
    echo "Total: ${#containers[@]} containers"
}

cleanup() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        log "DEBUG" "Skipping cleanup due to --no-cleanup flag"
        return
    fi
    
    log "INFO" "Cleaning up test containers..."
    docker ps -aq --filter "label=test-container" | xargs -r docker rm -f
}

trap cleanup EXIT

build_and_test_container() {
    local distro="$1"
    local version="$2"
    local dockerfile_path="$SCRIPT_DIR/$distro/$version/Dockerfile"
    local image_name="test-$distro-$version"
    local container_name="test-container-$distro-$version"
    
    if [[ ! -f "$dockerfile_path" ]]; then
        log "ERROR" "Dockerfile not found at $dockerfile_path"
        return 1
    fi
    
    # Build phase
    if [[ "$TEST_ONLY" == "false" ]]; then
        log "INFO" "Building $image_name from $dockerfile_path"
        log "DEBUG" "Build context: $SCRIPT_DIR/$distro/$version/"
        
        if ! docker build -t "$image_name" "$SCRIPT_DIR/$distro/$version/"; then
            log "ERROR" "Failed to build $image_name"
            return 1
        fi
        log "DEBUG" "Successfully built $image_name"
    else
        log "DEBUG" "Skipping build phase for $image_name (test-only mode)"
        # Check if image exists
        if ! docker image inspect "$image_name" > /dev/null 2>&1; then
            log "ERROR" "Image $image_name not found (required for test-only mode)"
            return 1
        fi
    fi
    
    # Skip testing if build-only mode
    if [[ "$BUILD_ONLY" == "true" ]]; then
        log "INFO" "Build completed for $image_name (build-only mode)"
        return 0
    fi
    
    # Test phase
    log "INFO" "Running container $container_name"
    log "DEBUG" "Container options: --privileged --tmpfs /tmp --tmpfs /run -v /sys/fs/cgroup:/sys/fs/cgroup:ro"
    
    if ! docker run -d --name "$container_name" --label "test-container" \
        --privileged --tmpfs /tmp --tmpfs /run \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        "$image_name"; then
        log "ERROR" "Failed to start container $container_name"
        return 1
    fi
    
    log "DEBUG" "Waiting 5 seconds for container to initialize..."
    sleep 5
    
    log "INFO" "Testing container $container_name"
    
    # Test 1: Container is running
    log "DEBUG" "Test 1: Checking if container is running"
    if ! docker ps --filter "name=$container_name" --filter "status=running" | grep -q "$container_name"; then
        log "ERROR" "Container $container_name is not running"
        return 1
    fi
    log "INFO" "✓ Container $container_name is running"
    
    # Test 2: Basic command execution
    log "DEBUG" "Test 2: Testing basic command execution"
    if ! docker exec "$container_name" /bin/sh -c "echo 'Hello World'" > /dev/null 2>&1; then
        log "ERROR" "Cannot execute commands in container $container_name"
        return 1
    fi
    log "INFO" "✓ Command execution works in $container_name"
    
    # Test 3: Network connectivity (if curl is available)
    log "DEBUG" "Test 3: Testing network connectivity"
    if docker exec "$container_name" which curl > /dev/null 2>&1; then
        if timeout "$TIMEOUT" docker exec "$container_name" curl -s --connect-timeout "$TIMEOUT" https://httpbin.org/ip > /dev/null 2>&1; then
            log "INFO" "✓ Network connectivity works in $container_name"
        else
            log "WARNING" "Network connectivity test failed in $container_name"
        fi
    else
        log "DEBUG" "curl not available in $container_name, skipping network test"
    fi
    
    # Test 4: File system operations
    log "DEBUG" "Test 4: Testing file system operations"
    if docker exec "$container_name" /bin/sh -c "touch /tmp/test-file && rm /tmp/test-file"; then
        log "INFO" "✓ File system operations work in $container_name"
    else
        log "ERROR" "File system operations failed in $container_name"
        return 1
    fi
    
    # Test 5: Package manager availability (distro-specific)
    log "DEBUG" "Test 5: Testing package manager availability"
    case "$distro" in
        alpine)
            if docker exec "$container_name" which apk > /dev/null 2>&1; then
                log "INFO" "✓ Package manager (apk) available in $container_name"
            else
                log "WARNING" "Package manager (apk) not found in $container_name"
            fi
            ;;
        ubuntu|debian)
            if docker exec "$container_name" which apt > /dev/null 2>&1; then
                log "INFO" "✓ Package manager (apt) available in $container_name"
            else
                log "WARNING" "Package manager (apt) not found in $container_name"
            fi
            ;;
        fedora)
            if docker exec "$container_name" which dnf > /dev/null 2>&1; then
                log "INFO" "✓ Package manager (dnf) available in $container_name"
            else
                log "WARNING" "Package manager (dnf) not found in $container_name"
            fi
            ;;
        amazon)
            if docker exec "$container_name" which yum > /dev/null 2>&1; then
                log "INFO" "✓ Package manager (yum) available in $container_name"
            else
                log "WARNING" "Package manager (yum) not found in $container_name"
            fi
            ;;
        el)
            if docker exec "$container_name" which dnf > /dev/null 2>&1 || docker exec "$container_name" which yum > /dev/null 2>&1; then
                log "INFO" "✓ Package manager available in $container_name"
            else
                log "WARNING" "Package manager not found in $container_name"
            fi
            ;;
    esac
    
    log "INFO" "✓ All tests passed for $container_name"
    
    log "DEBUG" "Stopping and removing container $container_name"
    docker stop "$container_name" > /dev/null 2>&1
    docker rm "$container_name" > /dev/null 2>&1
    
    return 0
}

should_process_distro() {
    local distro="$1"
    
    # If no target distros specified, process all
    if [[ ${#TARGET_DISTROS[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Check if distro is in target list
    for target in "${TARGET_DISTROS[@]}"; do
        if [[ "$distro" == "$target" ]]; then
            return 0
        fi
    done
    
    return 1
}

main() {
    log "INFO" "Starting container build and test automation"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log "DEBUG" "Configuration:"
        log "DEBUG" "  VERBOSE=$VERBOSE"
        log "DEBUG" "  QUIET=$QUIET"
        log "DEBUG" "  BUILD_ONLY=$BUILD_ONLY"
        log "DEBUG" "  TEST_ONLY=$TEST_ONLY"
        log "DEBUG" "  NO_CLEANUP=$NO_CLEANUP"
        log "DEBUG" "  TIMEOUT=$TIMEOUT"
        log "DEBUG" "  LOG_FILE=$LOG_FILE"
        log "DEBUG" "  TARGET_DISTROS=(${TARGET_DISTROS[*]})"
    fi
    
    > "$LOG_FILE"
    
    local failed_builds=()
    local successful_builds=()
    local processed_count=0
    
    # Discover all Dockerfiles
    while IFS= read -r -d '' dockerfile; do
        local rel_path="${dockerfile#$SCRIPT_DIR/}"
        local distro=$(dirname "$rel_path" | cut -d'/' -f1)
        local version=$(dirname "$rel_path" | cut -d'/' -f2)
        
        # Skip if distro not in target list
        if ! should_process_distro "$distro"; then
            log "DEBUG" "Skipping $distro/$version (not in target distros)"
            continue
        fi
        
        log "INFO" "Processing $distro/$version"
        ((processed_count++))
        
        if build_and_test_container "$distro" "$version"; then
            successful_builds+=("$distro/$version")
        else
            failed_builds+=("$distro/$version")
        fi
        
        if [[ "$QUIET" == "false" ]]; then
            echo "---"
        fi
    done < <(find "$SCRIPT_DIR" -name "Dockerfile" -type f -print0 | sort -z)
    
    if [[ $processed_count -eq 0 ]]; then
        log "WARNING" "No containers found to process"
        if [[ ${#TARGET_DISTROS[@]} -gt 0 ]]; then
            log "INFO" "Target distros: ${TARGET_DISTROS[*]}"
        fi
        exit 1
    fi
    
    log "INFO" "Build and test summary:"
    log "INFO" "Processed: $processed_count containers"
    log "INFO" "Successful: ${#successful_builds[@]}"
    for build in "${successful_builds[@]}"; do
        log "INFO" "  ✓ $build"
    done
    
    if [[ ${#failed_builds[@]} -gt 0 ]]; then
        log "INFO" "Failed: ${#failed_builds[@]}"
        for build in "${failed_builds[@]}"; do
            log "ERROR" "  ✗ $build"
        done
        log "ERROR" "Check $LOG_FILE for detailed error information"
        exit 1
    else
        log "INFO" "All container builds and tests completed successfully!"
    fi
}

# Parse command line arguments
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
            if [[ -z "$2" ]]; then
                echo "Error: --distro requires a value" >&2
                exit 1
            fi
            TARGET_DISTROS+=("$2")
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --test-only)
            TEST_ONLY=true
            shift
            ;;
        --no-cleanup)
            NO_CLEANUP=true
            shift
            ;;
        --timeout)
            if [[ -z "$2" ]] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --timeout requires a numeric value" >&2
                exit 1
            fi
            TIMEOUT="$2"
            shift 2
            ;;
        --log-file)
            if [[ -z "$2" ]]; then
                echo "Error: --log-file requires a value" >&2
                exit 1
            fi
            LOG_FILE="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            # Support legacy format: script.sh distro version
            if [[ $# -eq 2 ]] && [[ ${#TARGET_DISTROS[@]} -eq 0 ]]; then
                build_and_test_container "$1" "$2"
                exit $?
            else
                echo "Error: Invalid argument $1" >&2
                echo "Use --help for usage information" >&2
                exit 1
            fi
            ;;
    esac
done

# Validate conflicting options
if [[ "$BUILD_ONLY" == "true" && "$TEST_ONLY" == "true" ]]; then
    echo "Error: Cannot specify both --build-only and --test-only" >&2
    exit 1
fi

if [[ "$VERBOSE" == "true" && "$QUIET" == "true" ]]; then
    echo "Error: Cannot specify both --verbose and --quiet" >&2
    exit 1
fi

# Run main function
main