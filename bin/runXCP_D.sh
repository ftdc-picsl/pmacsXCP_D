#!/bin/bash

module load singularity/3.8.3

cleanupTmp=1
fsDir="/appl/freesurfer-7.1.1"
templateflowHome="/project/ftdc_pipeline/templateflow"

scriptPath=$(readlink -f "$0")
scriptDir=$(dirname "${scriptPath}")
# Repo base dir under which we find bin/ and containers/
repoDir=${scriptDir%/bin}

function usage() {
  echo "Usage:
  $0 [-h] [-B src:dest,...,src:dest] [-c 1/0] [-e VAR=value] -v xcpVersion \\
    -i /path/to/bids -o /path/to/outputDir -- [prep args]

  Use the -h option to see detailed help.

"
}

function help() {
    usage
  echo "This script handles various configuration options and bind points needed to run xcp_d on the cluster.

Using the options below, specify paths on the local file system. These will be bound automatically
to locations inside the container. If needed, you can add extra mount points with '-B'.

prep args after the '--' should reference paths within the container. For example, if
you want to use '--custom-confounds DIR', DIR should be a path inside the container.

Currently installed versions:

`ls -1 ${repoDir}/containers | grep ".sif"`


Required args:

  -i /path/to/fmriprep
    Input directory on the local file system. This will normally be output from fmriprep, but
    can be from other supported pipelines (see xcp_d usage for details).

  -o /path/to/outputDir
    Output directory on the local files system. Will be bound to /data/output inside the container.

  -v version
     XCP_D version. The script will look for containers/xcp_d-[version].sif.


Options:

  -B src:dest[,src:dest,...,src:dest]
     Use this to add mount points to bind inside the container, that aren't handled by other options.
     'src' is an absolute path on the local file system and 'dest' is an absolute path inside the container.
     Several bind points are always defined inside the container including \$HOME, \$PWD (where script is
     executed from), and /tmp (more on this below). Additionally, input (-i) and output (-o) are bound
     automatically.

  -c 1/0
     Cleanup the working dir after running the prep (default = $cleanupTmp). This is different from the prep
     option '--clean-workdir', which deletes the contents of the working directory BEFORE running anything.

  -e VAR=value[,VAR=value,...,VAR=value]
     Comma-separated list of environment variables to pass to singularity.

  -h
     Prints this help message.

  -t /path/to/templateflow
     Path to a local installation of templateflow (default = ${templateflowHome}).
     The required templates must be pre-downloaded on sciget, run-time template installation will not work.
     The default path has 'tpl-MNI152NLin2009cAsym' and 'tpl-OASIS30ANTs' downloaded.


*** Hard-coded configuration ***

A shared templateflow path is passed to the container via the environment variable TEMPLATEFLOW_HOME.

The FreeSurfer license file is sourced from ${fsDir}, and then mounted into the container. The variable
FS_LICENSE_DIR is set to point to this file.

The singularity module sets the singularity temp dir to be on /scratch. To avoid conflicts with other jobs,
the script makes a temp dir specifically for this prep job under /scratch. By default it is removed after
the prep finishes, but this can be disabled with '-c 0'.

The singularity command includes '--no-home', which avoids mounting the user home directory. This prevents caching
or config files in the user home directory from conflicting with those inside the container.

The actual call to the prep is equivalent to

<aprep> \\
  --notrack \\
  --nthreads numProcs \\
  --omp-nthreads numOMPThreads \\
  --work-dir [job temp dir on /scratch] \\
  --verbose \\
  [xcp args] \\
  /data/input /data/output participant

where [xcp args] are anything following `--` in the call to this script.

*** Multi-threading and memory use ***

The number of available cores (numProcs) is derived from the environment variable \${LSB_DJOB_NUMPROC},
which is the number of slots reserved in the call to bsub. If numProcs > 1, we pass to the prep
'--nthreads numProcs --omp-nthreads numProcs'. Individual workflows may differ in performance. This default
may be overriden by passing the two options above as an argument to the prep container

The performance gains of multi-threading fall off sharply with omp-nthreads > 8. In some contexts, it may be possible
to run jobs in parallel, eg with '--nthreads 16 --omp-nthreads 8'.

Memory use is not controlled by this script, as it is not simple to parse from the job environment. The
maximum memory (in Mb) used by the preps can be controlled with '--mem-mb'. The amount of memory required will
depend on the size of the input data, the processing options selected, and the number of threads used.

"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

userBindPoints=""

containerVersion=""

singularityEvars=""

while getopts "B:c:e:f:i:m:o:t:v:h" opt; do
  case $opt in
    B) userBindPoints=$OPTARG;;
    c) cleanupTmp=$OPTARG;;
    e) singularityEvars=$OPTARG;;
    h) help; exit 1;;
    i) inputDir=$OPTARG;;
    o) outputDir=$OPTARG;;
    t) templateflowHome=$OPTARG;;
    v) containerVersion=$OPTARG;;
    \?) echo "Unknown option $OPTARG"; exit 2;;
    :) echo "Option $OPTARG requires an argument"; exit 2;;
  esac
done

shift $((OPTIND-1))

image="${repoDir}/containers/xcp_d-${containerVersion}.sif"

if [[ ! -f $image ]]; then
  echo "Cannot find requested container $image"
  exit 1
fi

if [[ -z "${LSB_JOBID}" ]]; then
  echo "This script must be run within a (batch or interactive) LSF job"
  exit 1
fi

sngl=$( which singularity ) ||
    ( echo "Cannot find singularity executable. Try module load singularity"; exit 1 )

if [[ ! -d "$inputDir" ]]; then
  echo "Cannot find input BIDS directory $inputDir"
  exit 1
fi

if [[ ! -d "$outputDir" ]]; then
  mkdir -p "$outputDir"
fi

if [[ ! -d "${outputDir}" ]]; then
  echo "Could not find or create output directory ${outputDir}"
  exit 1
fi

# Set a job-specific temp dir
if [[ ! -d "$SINGULARITY_TMPDIR" ]]; then
  echo "Setting SINGULARITY_TMPDIR=/scratch"
  export SINGULARITY_TMPDIR=/scratch
fi

jobTmpDir=$( mktemp -d -p ${SINGULARITY_TMPDIR} ${whichPrep}.${LSB_JOBID}.XXXXXXXX.tmpdir )

if [[ ! -d "$jobTmpDir" ]]; then
  echo "Could not create job temp dir ${jobTmpDir}"
  exit 1
fi


export SINGULARITYENV_TMPDIR="/tmp"

# This tells xcp to look for templateflow here inside the container
export SINGULARITYENV_TEMPLATEFLOW_HOME="/opt/templateflow"

# unlike preps, don't pass FS license dir explicitly
export SINGULARITYENV_FS_LICENSE="/freesurfer/license.txt"

if [[ ! -d "${templateflowHome}" ]]; then
  echo "Could not find templateflow at ${templateflowHome}"
  exit 1
fi

# singularity args
singularityArgs="--cleanenv \
  --no-home \
  -B ${jobTmpDir}:/tmp \
  -B ${templateflowHome}:${SINGULARITYENV_TEMPLATEFLOW_HOME} \
  -B ${fsDir}/license.txt:${SINGULARITYENV_FS_LICENSE} \
  -B ${inputDir}:/data/input \
  -B ${outputDir}:/data/output"

numProcs=$LSB_DJOB_NUMPROC
numOMPThreads=$LSB_DJOB_NUMPROC

# Script-defined args to xcp
xcpScriptArgs="--notrack \
  --nthreads $numProcs \
  --omp-nthreads $numOMPThreads \
  -w ${SINGULARITYENV_TMPDIR} \
  --verbose"

if [[ -n "$userBindPoints" ]]; then
  singularityArgs="$singularityArgs \
  -B $userBindPoints"
fi

if [[ -n "$singularityEvars" ]]; then
  singularityArgs="$singularityArgs \
  --env $singularityEvars"
fi

xcpUserArgs="$*"

echo "
--- args passed through to xcp ---
$*
---
"

echo "
--- Script options ---
XCP_D image            : $image
Input directory        : $inputDir
Output directory       : $outputDir
Cleanup temp           : $cleanupTmp
User bind points       : $userBindPoints
User environment vars  : $singularityEvars
Number of cores        : $numProcs
OMP threads            : $numOMPThreads
---
"

echo "
--- Container details ---"
singularity inspect $image
echo "---
"

cmd="singularity run \
  $singularityArgs \
  $image \
  /data/input /data/output participant \
  $xcpScriptArgs \
  $xcpUserArgs"

echo "
--- prep command ---
$cmd
---
"

# function to clean up tmp and report errors at exit
function cleanup {
  EXIT_CODE=$?
  LAST_CMD=${BASH_COMMAND}
  set +e # disable termination on error

  if [[ $cleanupTmp -gt 0 ]]; then
    echo "Removing temp dir ${jobTmpDir}"
    rm -rf ${jobTmpDir}
  else
    echo "Leaving working directory ${jobTmpDir}"
  fi

  if [[ ${EXIT_CODE} -gt 0 ]]; then
    echo "
  $0 EXITED ON ERROR - PROCESSING MAY BE INCOMPLETE"
    echo "
  The command \"${LAST_CMD}\" exited with code ${EXIT_CODE}
"
  fi

  exit $EXIT_CODE
}

trap cleanup EXIT

# Exits, triggering cleanup, on CTRL+C
function sigintCleanup {
   exit $?
}

trap sigintCleanup SIGINT

$cmd
singExit=$?

if [[ $singExit -ne 0 ]]; then
  echo "Container exited with non-zero code $singExit"
fi

if [[ $cleanupTmp -eq 1 ]]; then
  echo "Removing temp dir ${jobTmpDir}"
  rm -rf ${jobTmpDir}
else
  echo "Leaving temp dir ${jobTmpDir}"
fi

exit $singExit
