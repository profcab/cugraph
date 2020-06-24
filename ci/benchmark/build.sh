#!/usr/bin/env bash
# Copyright (c) 2018, NVIDIA CORPORATION.
##########################################
# cuGraph Benchmark test script for CI   #
##########################################

set -e
set -o pipefail
NUMARGS=$#
ARGS=$*

function logger {
  echo -e "\n>>>> $@\n"
}

function hasArg {
    (( ${NUMARGS} != 0 )) && (echo " ${ARGS} " | grep -q " $1 ")
}

function cleanup {
  logger "Removing datasets and temp files..."
  rm -rf $WORKSPACE/datasets/test
  rm -rf $WORKSPACE/datasets/benchmark
  rm -f testoutput.txt
}

# Set cleanup trap for Jenkins
if [ ! -z "$JENKINS_HOME" ] ; then
  logger "Jenkins environment detected, setting cleanup trap..."
  trap cleanup EXIT
fi

# Set path, build parallel level, and CUDA version
cd $WORKSPACE
export PATH=/conda/bin:/usr/local/cuda/bin:$PATH
export PARALLEL_LEVEL=4
export CUDA_REL=${CUDA_VERSION%.*}
export HOME=$WORKSPACE
export GIT_DESCRIBE_TAG=`git describe --tags`
export MINOR_VERSION=`echo $GIT_DESCRIBE_TAG | grep -o -E '([0-9]+\.[0-9]+)'`

# Set Benchmark Vars
export DATASETS_DIR=${WORKSPACE}/datasets
export ASVRESULT_DIR=${WORKSPACE}/asvresults

##########################################
# Pull Build Artifacts from S3           #
##########################################

# TODO: Implement once gpuCI supports


##########################################
# Environment Setup                      #
##########################################

# TODO: Delete build section when artifacts are available

logger "Check environment..."
env

logger "Check GPU usage..."
nvidia-smi

logger "Activate conda env..."
source activate gdf

logger "conda install required packages"
conda install -c nvidia -c rapidsai -c rapidsai-nightly -c conda-forge -c defaults \
      "cudf=${MINOR_VERSION}" \
      "rmm=${MINOR_VERSION}" \
      "cudatoolkit=$CUDA_REL" \
      "dask-cudf=${MINOR_VERSION}" \
      "dask-cuda=${MINOR_VERSION}" \
      "ucx-py=${MINOR_VERSION}" \
      "rapids-build-env=${MINOR_VERSION}" \
      rapids-pytest-benchmark

# Install the master version of dask and distributed
logger "pip install git+https://github.com/dask/distributed.git --upgrade --no-deps"
pip install "git+https://github.com/dask/distributed.git" --upgrade --no-deps

logger "pip install git+https://github.com/dask/dask.git --upgrade --no-deps"
pip install "git+https://github.com/dask/dask.git" --upgrade --no-deps

logger "Check versions..."
python --version
$CC --version
$CXX --version
conda list

##########################################
# Build cuGraph                          #
##########################################

logger "Build libcugraph..."
$WORKSPACE/build.sh clean libcugraph cugraph

##########################################
# Run Benchmarks                         #
##########################################

cd $DATASETS_DIR

logger "Downloading Datasets for Benchmarks..."
bash ./get_test_data.sh --benchmarks
ERRORCODE=$((ERRORCODE | $?))
# Exit if dataset download failed
if (( ${ERRORCODE} != 0 )); then
    exit ${ERRORCODE}
fi

logger "Running Benchmarks..."
set +e
time pytest -v -m "small and managedmem_on and poolallocator_on" \
    --benchmark-gpu-device=0 \ # gpuCI container only sees 1 gpu, device number always 0
    --benchmark-gpu-max-rounds=3 \
    --benchmark-asv-metadata="machineName=${NODE_NAME}, commitBranch=branch-${MINOR_VERSION}" \
    --benchmark-asv-output-dir=${ASVRESULTS_DIR}

EXITCODE=$?

set -e
JOBEXITCODE=0
# TODO: Add notification based on failures this should most likely move to the Jenkins job itself
if [[ "$BUILD_MODE" = "branch" && "$SOURCE_BRANCH" = branch-* ]] ; then
    if (( ${EXITCODE} == 1 )); then
        #There were some benchmark failures, send notification
    else
        #There was a FATAL error during the benchmark runs, abort entirely and send notification
        JOBEXITCODE=${EXITCODE}
    fi
fi

##########################################
# Push Results to S3                     #
##########################################

if [[ "$BUILD_MODE" = "branch" && "$SOURCE_BRANCH" = branch-* ]] ; then
    #TODO: Move results from $ASVRESULTS_DIR to nightly S3 folder
else # PR Build
    #TODO: Move results from $ASVRESULTS_DIR to PR S3 folder
fi


exit $JOBEXITCODE
