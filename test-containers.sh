#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/container-test.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

cleanup() {
    log "Cleaning up test containers..."
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
        log "ERROR: Dockerfile not found at $dockerfile_path"
        return 1
    fi
    
    log "Building $image_name from $dockerfile_path"
    if ! docker build -t "$image_name" "$SCRIPT_DIR/$distro/$version/"; then
        log "ERROR: Failed to build $image_name"
        return 1
    fi
    
    log "Running container $container_name"
    if ! docker run -d --name "$container_name" --label "test-container" \
        --privileged --tmpfs /tmp --tmpfs /run \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        "$image_name"; then
        log "ERROR: Failed to start container $container_name"
        return 1
    fi
    
    sleep 5
    
    log "Testing container $container_name"
    
    # Test 1: Container is running
    if ! docker ps --filter "name=$container_name" --filter "status=running" | grep -q "$container_name"; then
        log "ERROR: Container $container_name is not running"
        return 1
    fi
    log "✓ Container $container_name is running"
    
    # Test 2: Basic command execution
    if ! docker exec "$container_name" /bin/sh -c "echo 'Hello World'" > /dev/null 2>&1; then
        log "ERROR: Cannot execute commands in container $container_name"
        return 1
    fi
    log "✓ Command execution works in $container_name"
    
    # Test 3: Network connectivity (if curl is available)
    if docker exec "$container_name" which curl > /dev/null 2>&1; then
        if docker exec "$container_name" curl -s --connect-timeout 10 https://httpbin.org/ip > /dev/null 2>&1; then
            log "✓ Network connectivity works in $container_name"
        else
            log "WARNING: Network connectivity test failed in $container_name"
        fi
    else
        log "INFO: curl not available in $container_name, skipping network test"
    fi
    
    # Test 4: File system operations
    if docker exec "$container_name" /bin/sh -c "touch /tmp/test-file && rm /tmp/test-file"; then
        log "✓ File system operations work in $container_name"
    else
        log "ERROR: File system operations failed in $container_name"
        return 1
    fi
    
    # Test 5: Package manager availability (distro-specific)
    case "$distro" in
        alpine)
            if docker exec "$container_name" which apk > /dev/null 2>&1; then
                log "✓ Package manager (apk) available in $container_name"
            else
                log "WARNING: Package manager (apk) not found in $container_name"
            fi
            ;;
        ubuntu|debian)
            if docker exec "$container_name" which apt > /dev/null 2>&1; then
                log "✓ Package manager (apt) available in $container_name"
            else
                log "WARNING: Package manager (apt) not found in $container_name"
            fi
            ;;
        fedora)
            if docker exec "$container_name" which dnf > /dev/null 2>&1; then
                log "✓ Package manager (dnf) available in $container_name"
            else
                log "WARNING: Package manager (dnf) not found in $container_name"
            fi
            ;;
        amazon)
            if docker exec "$container_name" which yum > /dev/null 2>&1; then
                log "✓ Package manager (yum) available in $container_name"
            else
                log "WARNING: Package manager (yum) not found in $container_name"
            fi
            ;;
        el)
            if docker exec "$container_name" which dnf > /dev/null 2>&1 || docker exec "$container_name" which yum > /dev/null 2>&1; then
                log "✓ Package manager available in $container_name"
            else
                log "WARNING: Package manager not found in $container_name"
            fi
            ;;
    esac
    
    log "✓ All tests passed for $container_name"
    
    docker stop "$container_name" > /dev/null 2>&1
    docker rm "$container_name" > /dev/null 2>&1
    
    return 0
}

main() {
    log "Starting container build and test automation"
    
    > "$LOG_FILE"
    
    local failed_builds=()
    local successful_builds=()
    
    # Discover all Dockerfiles
    while IFS= read -r -d '' dockerfile; do
        local rel_path="${dockerfile#$SCRIPT_DIR/}"
        local distro=$(dirname "$rel_path" | cut -d'/' -f1)
        local version=$(dirname "$rel_path" | cut -d'/' -f2)
        
        log "Processing $distro/$version"
        
        if build_and_test_container "$distro" "$version"; then
            successful_builds+=("$distro/$version")
        else
            failed_builds+=("$distro/$version")
        fi
        
        echo "---"
    done < <(find "$SCRIPT_DIR" -name "Dockerfile" -type f -print0)
    
    log "Build and test summary:"
    log "Successful: ${#successful_builds[@]}"
    for build in "${successful_builds[@]}"; do
        log "  ✓ $build"
    done
    
    if [[ ${#failed_builds[@]} -gt 0 ]]; then
        log "Failed: ${#failed_builds[@]}"
        for build in "${failed_builds[@]}"; do
            log "  ✗ $build"
        done
        log "Check $LOG_FILE for detailed error information"
        exit 1
    else
        log "All container builds and tests completed successfully!"
    fi
}

# Allow running specific containers
if [[ $# -eq 2 ]]; then
    build_and_test_container "$1" "$2"
else
    main
fi