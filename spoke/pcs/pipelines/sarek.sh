# nf-core/sarek: pulls the pipeline at a pinned version and installs sarek-samplesheet and
# run-sarek. Options (pcs.pipeline_options): version (default 3.7.1, as in nf-core's
# published AWS test run), genome (default GATK.GRCh38, from AWS's public iGenomes
# bucket), tools (default haplotypecaller).
# bench-summary (timings from the trace) comes with every pipeline: node/setup.sh.
# Run as ec2-user by the login node setup, with its settings in the environment.
set -euo pipefail
S=$PA_SHARED/sarek
mkdir -p "$S"
cat > "$S/defaults" <<EOF
SAREK_VERSION=${APP_VERSION:-3.7.1}
SAREK_GENOME=${APP_GENOME:-GATK.GRCh38}
SAREK_TOOLS=${APP_TOOLS:-haplotypecaller}
EOF
. "$S/defaults"
nextflow pull nf-core/sarek -r "$SAREK_VERSION"

# Requests sized to what the steps used (peak memory plus headroom, CPUs they keep busy) in
# a profiling run on c6i.4xlarge nodes (8 cores; about 28 GB schedulable by Slurm). Sarek's
# defaults ask for most of such a node even for light steps, so tasks would run one per
# node. run-sarek adds this config; retries still double the memory. SAREK_PROFILE runs
# use Sarek's own requests instead.
cat > "$PA_SHARED/conf/sarek-pcs.config" <<'EOF'
process {
    withName: 'BWAMEM1_MEM'                { cpus = 8; memory = { 14.GB * task.attempt } }
    withName: 'GATK4_MARKDUPLICATES'       { cpus = 2; memory = { 26.GB * task.attempt } }
    withName: 'GATK4_BASERECALIBRATOR|GATK4_APPLYBQSR' { cpus = 2; memory = { 6.GB * task.attempt } }
    withName: 'GATK4_HAPLOTYPECALLER'      { cpus = 4; memory = { 6.GB * task.attempt } }
    withName: 'CNNSCOREVARIANTS'           { cpus = 8; memory = { 6.GB * task.attempt } }
    withName: 'FILTERVARIANTTRANCHES'      { cpus = 1; memory = { 6.GB * task.attempt } }
    withName: 'MERGE_CRAM|MOSDEPTH|FASTQC' { cpus = 2; memory = { 4.GB * task.attempt } }
    withName: 'SAMTOOLS_STATS'             { cpus = 1; memory = { 2.GB * task.attempt } }
}
EOF

cat > "$PA_SHARED/bin/sarek-samplesheet" <<'EOF'
#!/bin/bash
# Prints a Sarek samplesheet for the paired FASTQs in a directory:
#   sarek-samplesheet DIR [SAMPLE] > samples.csv
# Pairs *_R1* or *.R1.* with R2, or *_1.fastq.gz with _2. With SAMPLE, every pair is a lane
# of that one sample (numbered 1, 2, ...). Without, the sample (and patient) is the name
# before _S<n>, _L<lane> or the read number, and the lane comes from _L00<n>_, else 1.
set -euo pipefail
dir=$(realpath "$1"); one=${2:-}; n=0
echo "patient,sample,lane,fastq_1,fastq_2"
find "$dir" -maxdepth 1 \( -name '*[._]R1[._]*f*q.gz' -o -name '*_1.f*q.gz' \) -printf '%f\n' | sort |
while read -r b; do
  b2=$(sed -E 's/([._])R1([._])/\1R2\2/; t; s/_1(\.f(ast)?q\.gz)$/_2\1/' <<< "$b")
  [ -f "$dir/$b2" ] || { echo "no mate for $b; skipped" >&2; continue; }
  n=$((n + 1))
  if [ -n "$one" ]; then
    sample=$one lane=$n
  else
    sample=$(sed -E 's/(_S[0-9]+)?(_L[0-9]{3})?([._]R1|_1)([._].*)?$//' <<< "$b")
    lane=$(sed -nE 's/.*_L0*([0-9]+)_.*/\1/p' <<< "$b")
  fi
  echo "$sample,$sample,${lane:-1},$dir/$b,$dir/$b2"
done
EOF

cat > "$PA_SHARED/bin/run-sarek" <<'EOF'
#!/bin/bash
# Runs nf-core/sarek through Slurm; Nextflow itself runs in a job on a compute node.
#   run-sarek SAMPLESHEET [OUTDIR] [-- more sarek or nextflow arguments]
# Default OUTDIR: $PA_DATA/results/sarek/<time> (on the portal path, so it reaches the hub).
# References: $PA_SHARED/references/igenomes when it exists (copy them there once), else S3.
# Timings: OUTDIR/pipeline_info (trace with per-task I/O, timeline, report).
# Work files: $PA_SHARED/work, or SAREK_WORK=DIR.
# SAREK_PROFILE=NAME runs one of nf-core's test profiles as nf-core runs it (e.g.
# test_full_germline): its tools and settings, and Sarek's own resource requests instead of
# ours (capped at one node). SAMPLESHEET can then be a URL, e.g. the profile's own.
set -euo pipefail
. /etc/profile.d/cnq-path-extender.sh
. "$PA_SHARED/sarek/defaults"
profile=${SAREK_PROFILE:-}
sheet=$1; shift
[[ $sheet == *://* ]] || sheet=$(realpath "$sheet")
run=$(date +%Y%m%d-%H%M%S)
out=$PA_DATA/results/sarek/$run
if [ $# -gt 0 ] && [ "$1" != -- ]; then out=$1; shift; fi
[ "${1:-}" = -- ] && shift
out=$(realpath -m "$out")
dir=$PA_SHARED/runs/sarek/$run
mkdir -p "$dir" "$out"
cd "$dir"
if [ -n "$profile" ]; then
  args=(nextflow run nf-core/sarek -r "$SAREK_VERSION" -profile "$profile,apptainer"
        -c "$PA_SHARED/conf/pcs.config")
else
  args=(nextflow run nf-core/sarek -r "$SAREK_VERSION" -profile apptainer -c "$PA_SHARED/conf/pcs.config"
        -c "$PA_SHARED/conf/sarek-pcs.config" --genome "$SAREK_GENOME" --tools "$SAREK_TOOLS")
fi
args+=(-w "${SAREK_WORK:-$PA_SHARED/work}/sarek-$run" --input "$sheet" --outdir "$out")
# References copied to the shared storage are used instead of S3, unless told otherwise.
refs=$PA_SHARED/references/igenomes
base=""
prev=""
for a in "$@"; do
  case $a in --igenomes_base=*) base=${a#*=} ;; esac
  [ "$prev" = --igenomes_base ] && base=$a
  prev=$a
done
if [ -z "$base" ] && [ -d "$refs" ]; then base=$refs; args+=(--igenomes_base "$refs"); fi
# Sarek 3.7 checks that every index the genome lists exists, even ones its aligner won't
# use; the copies hold only bwa's (and S3 keeps no empty folders). Empty stand-ins pass.
if [[ $base == /* ]] && [ "$SAREK_GENOME" = GATK.GRCh38 ]; then
  mkdir -p "$base"/Homo_sapiens/GATK/GRCh38/Sequence/{BWAmem2Index,dragmap}
fi
args+=("$@")
printf '%q ' "${args[@]}" > command.txt
sbatch -p "$PA_QUEUE" -J "sarek-$run" -c 2 --mem 8G -o "$dir/nextflow-%j.out" --wrap "$(cat command.txt)"
echo "Run directory: $dir"
echo "Results:       $out"
EOF
chmod 755 "$PA_SHARED/bin/sarek-samplesheet" "$PA_SHARED/bin/run-sarek"
