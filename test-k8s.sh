#!/bin/bash
set -e

export TERM=xterm-256color

PROJECT_ROOT="$(pwd)"
TEST_ROOT="${PROJECT_ROOT}/tests/integration"
TIMEOUT_SECONDS=180
RUN_ID="$(date +%y%m%d_%H%M%S)"
LOG_DIR="${PROJECT_ROOT}/logs/${RUN_ID}"
while [ -d "$LOG_DIR" ]; do
    tmp_id="$((tmp_id + 1))"
    new_run="${RUN_ID}_${tmp_id}"
    LOG_DIR="${PROJECT_ROOT}/logs/${RUN_ID}"
done
RUN_ID=''

mkdir -p "${PROJECT_ROOT}/logs"
mkdir "$LOG_DIR"

BUILD_LOG="${LOG_DIR}/build.log"
RUN_LOG="${LOG_DIR}/run_master.log"
TEST_LOG="${LOG_DIR}/test.log"
WORKER_LOG_DIR="/tmp/jasminegraph"
rm -rf "${WORKER_LOG_DIR}"
mkdir -p "${WORKER_LOG_DIR}"

build_and_run_on_k8s() {
    cd "$PROJECT_ROOT"
    docker build -t jasminegraph . |& tee "$BUILD_LOG"
    build_status="${PIPESTATUS[0]}"
    if [ "$build_status" != '0' ]; then
        set +ex
        echo
        echo -e '\e[31;1mERROR: Build failed\e[0m'
        rm -rf "${TEST_ROOT}/env"
        exit "$build_status"
    fi

    metadb_path="${TEST_ROOT}/env/databases/metadb"\
    performancedb_path="${TEST_ROOT}/env/databases/performancedb"\
    data_path="${TEST_ROOT}/env/data"\
    log_path="${LOG_DIR}"\
    envsubst < "${PROJECT_ROOT}/k8s/volumes.yaml" | kubectl apply -f -

    kubectl apply -f "${PROJECT_ROOT}/k8s/master-deployment.yaml"
}

clear_resources() {
    kubectl delete deployments jasminegraph-master-deployment jasminegraph-worker1-deployment \
    jasminegraph-worker0-deployment
    kubectl delete services jasminegraph-master-service jasminegraph-worker0-service jasminegraph-worker1-service
    kubectl delete -f "${PROJECT_ROOT}/k8s/volumes.yaml"
}

cd "$TEST_ROOT"
rm -rf env
cp -r env_init env
cd "$PROJECT_ROOT"
build_and_run_on_k8s

timeout "$TIMEOUT_SECONDS" python3 -u "${TEST_ROOT}/test-k8s.py" |& tee "$TEST_LOG"
exit_code="${PIPESTATUS[0]}"
set +ex
if [ "$exit_code" = '124' ]; then
    echo
    echo -e '\e[31;1mERROR: Test Timeout\e[0m'
    echo
    clear_resources
fi

print_log() {
    sed -e 's/^integration-jasminegraph-1  | //g' \
        -e 's/ \[logger\]//g' \
        -e 's/ \[info\] / ['$'\033''[32minfo'$'\033''[0m] /g' \
        -e 's/ \[warn\] / ['$'\033''[1;33mwarn'$'\033''[0m] /g' \
        -e 's/ \[error\] / ['$'\033''[1;31merror'$'\033''[0m] /g' \
        -e 's/ \[INFO\] / ['$'\033''[32mINFO'$'\033''[0m] /g' \
        -e 's/ \[WARNING\] / ['$'\033''[1;33mWARNING'$'\033''[0m] /g' "$1"
}

cd "$TEST_ROOT"
for d in "${WORKER_LOG_DIR}"/worker_*; do
    echo
    worker_name="$(basename ${d})"
    cp -r "$d" "${LOG_DIR}/${worker_name}"
done

cd "$LOG_DIR"
if [ "$exit_code" != '0' ]; then
    echo
    echo -e '\e[33;1mMaster log:\e[0m'
    print_log "$RUN_LOG"

    for d in worker_*; do
        cd "${LOG_DIR}/${d}"
        echo
        echo -e '\e[33;1m'"${d}"' log:\e[0m'
        print_log worker.log

        for f in merge_*.log; do
            echo
            echo -e '\e[33;1m'"${d} ${f::-4}"' log:\e[0m'
            print_log "$f"
        done

        for f in fl_client_*.log; do
            echo
            echo -e '\e[33;1m'"${d} ${f::-4}"' log:\e[0m'
            print_log "$f"
        done

        for f in fl_server_*.log; do
            echo
            echo -e '\e[33;1m'"${d} ${f::-4}"' log:\e[0m'
            print_log "$f"
        done
    done
fi

rm -rf "${TEST_ROOT}/env" "${WORKER_LOG_DIR}"
exit "$exit_code"
