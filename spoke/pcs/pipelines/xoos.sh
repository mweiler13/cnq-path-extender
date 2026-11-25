# Xoos (Roche SBX): the xoosnf pipeline, the xoos launcher, the public smoke dataset, and
# run-xoos-smoke.
# Options (pcs.pipeline_options): xoosnf_ref and xoos_ref (git tag, branch or commit;
# default the latest), dataset (smoke dataset release, default 1.1.0).
# Run as ec2-user by the login node setup, with its settings in the environment.
set -euo pipefail
X=$PA_SHARED/xoos
mkdir -p "$X/env" "$X/conf"

clone() {  # repository, directory, ref
  if [ -d "$2/.git" ]; then
    git -C "$2" fetch -q --tags origin  # a re-run may ask for a newer ref
  else
    git clone -q "https://github.com/Roche-AXELIOS/$1" "$2"
  fi
  [ -z "$3" ] || git -C "$2" checkout -q "$3"
  echo "$1 at $(git -C "$2" rev-parse --short HEAD)"
}
clone xoosnf "$X/xoosnf" "${APP_XOOSNF_REF:-}"
clone XOOS "$X/XOOS" "${APP_XOOS_REF:-}"

# The launcher, built from source (needs Python 3.10+), in a venv every node can use.
# Typer 0.29 dropped the click_type option the launcher uses; it only asks for >=0.9.
if ! "$X/venv/bin/xoos" --help >/dev/null 2>&1; then
  [ -x "$X/venv/bin/pip" ] || python3.12 -m venv "$X/venv"
  "$X/venv/bin/pip" install -q "typer>=0.9,<0.29" "$X/XOOS/pipeline_launcher"
  "$X/venv/bin/xoos" --help >/dev/null
fi
ln -sf "$X/venv/bin/xoos" "$PA_SHARED/bin/xoos"

if [ -z "$(find "$X" -name resources.config -path '*xoosnf-test-datasets/resources/*' -print -quit)" ]; then
  curl -fsSL "https://github.com/Roche-AXELIOS/xoosnf-test-datasets/releases/download/${APP_DATASET:-1.1.0}/xoosnf-test-datasets.tar.gz" |
    tar -xzf - -C "$X"
fi

# Launcher environment: a driver job runs Nextflow on a compute node; work under scratch_base.
cat > "$X/env/slurm_pcs.yaml" <<EOF
executor: slurm
profiles:
  - pcs
attributes:
  driver_options:
    partition: $PA_QUEUE
    time: '24:00:00'
    mem: 6g
preamble: |
  . /etc/profile.d/cnq-path-extender.sh
config_files: []
driver:
  scratch_base: $PA_SHARED/work
  singularity_cache: $PA_SHARED/apptainer-cache
  cache_mode: shared
EOF

# Smoke test parameters (germline small variants; identical for all three inputs) and
# the "pcs" profile: retries for transient failures, and per-task CPUs, memory, time and
# HaplotypeCaller options. Slurm and Apptainer: pcs.config (its node-size limits still apply).
cat > "$X/conf/smoke.config" <<'EOF'
params {
    variant_calling_mode                         = 'germline'
    aligner                                      = 'bwa'
    enable_pangenome_personalization             = false
    exclude_partial_reads                        = true
    enable_demux_strand_detect                   = false
    dedup_strategy                               = 'markdup'
    read_collapser_preset                        = 'wgs-duplex'
    read_collapser_cluster_by_umi                = false
    enable_subsample_bam                         = false
    enable_contamination_estimation              = false
    enable_alignment_metrics_autosomes           = false
    enable_alignment_metrics_targets             = false
    enable_alignment_metrics_high_confidence     = false
    enable_hp_metrics                            = false
    enable_gc_bias_metrics                       = false
    enable_hs_metrics                            = false
    enable_pre_dedup_metrics                     = false
    enable_pre_subsample_metrics                 = false
    alignment_metrics_min_base_quality_pre_dedup = 30
    alignment_metrics_min_base_quality           = 30
    enable_small_variant_caller                  = true
    use_gatk_haplotype_caller                    = true
    enable_small_variant_caller_retrain          = false
    enable_copy_number_caller                    = false
    enable_str_caller                            = false
    enable_merge_vcf                             = false
    enable_variant_calling_partitioning          = true
    enable_vcfeval                               = false
    cpu_variant_calling_partition_count          = 1
    gpu_variant_calling_partition_count          = 1
}
profiles {
    pcs {
        process {
            maxRetries    = 2
            errorStrategy = { task.exitStatus == null || task.exitStatus in (135..140) + [125, 126, 255, Integer.MAX_VALUE] ? 'retry' : 'finish' }
            cpus = 1; memory = { 2.GB * task.attempt }; time = { 4.h * task.attempt }
            withLabel:process_single      { cpus = 1; memory = { 1.GB * task.attempt };  time = { 4.h * task.attempt } }
            withLabel:process_low         { cpus = 2; memory = { 4.GB * task.attempt };  time = { 4.h * task.attempt } }
            withLabel:process_medium      { cpus = 8; memory = { 16.GB * task.attempt }; time = { 8.h * task.attempt } }
            withLabel:process_high        { cpus = 8; memory = { 28.GB * task.attempt }; time = { 16.h * task.attempt } }
            withLabel:process_long        { time = { 20.h * task.attempt } }
            withLabel:process_high_memory { cpus = 8; memory = { 28.GB * task.attempt }; time = { 16.h * task.attempt } }
            withLabel:process_gpu         { cpus = 8; memory = { 28.GB * task.attempt } }
            withName:'XOOS_DEMUX'                         { cpus = 8; memory = { 28.GB * task.attempt }; time = { 8.h * task.attempt } }
            withName:'BWA_MEM_SINGLE_END_MULTIPLE_FASTQS' { cpus = 8; memory = { 28.GB * task.attempt }; time = { 8.h * task.attempt } }
            withName:'XOOS_READ_COLLAPSER_MARK_DUPLICATES' { cpus = 8; memory = { 16.GB * task.attempt }; time = { 8.h * task.attempt } }
            withName:'XOOS_SMALL_VARIANT_CALLER_FILTER_VARIANTS_GERMLINE_WGS' { cpus = 8; memory = { 24.GB * task.attempt }; time = { 4.h * task.attempt } }
            withName:'GATK4_MERGEVCFS'                    { cpus = 1; memory = { 4.GB * task.attempt };  time = { 2.h * task.attempt } }
            withName:'GATK4_HAPLOTYPECALLER' {
                cpus = 4; memory = { 8.GB * task.attempt }; time = { 8.h * task.attempt }
                ext.args = '-OBI -OVI --bam-writer-type CALLED_HAPLOTYPES -A TandemRepeat -A AssemblyComplexity -RF MappingQualityReadFilter --activeregion-alt-multiplier 5 --adaptive-pruning --enable-dynamic-read-disqualification-for-genotyping true --mapping-quality-threshold-for-genotyping 1 --minimum-mapping-quality 1 --min-base-quality-score 6 --smith-waterman FASTEST_AVAILABLE'
            }
        }
    }
}
EOF

cat > "$PA_SHARED/bin/run-xoos-smoke" <<'EOF'
#!/bin/bash
# Submits the three Xoos smoke tests (BAM, demultiplexed FASTQ, basecall FASTQ) to Slurm.
#   run-xoos-smoke [OUTPUT_DIR]    default: $PA_DATA/results/xoos-smoke/<time> (reaches the hub)
# Each test's VCFs end up under OUTPUT_DIR/<test>/output. Watch with squeue.
set -euo pipefail
. /etc/profile.d/cnq-path-extender.sh
X=$PA_SHARED/xoos
run=$(date +%Y%m%d-%H%M%S)
out=$(realpath -m "${1:-$PA_DATA/results/xoos-smoke/$run}")
cfg=$(find "$X" -name resources.config -path '*xoosnf-test-datasets/resources/*' -print -quit)
[ -n "$cfg" ] || { echo "No smoke dataset under $X: the pipeline setup didn't finish (see /var/log/cnq-path-extender-setup.log)" >&2; exit 1; }
res=$(dirname "$cfg"); data=$(dirname "$res")
sheets=$PA_SHARED/runs/xoos-smoke/$run
mkdir -p "$sheets" "$out"
for t in bam:bam demux:demultiplexed_fastq basecall:basecall_fastq; do
  name=${t%%:*} type=${t#*:} hdr=run_name,run_type,file_type,run_dir,samplesheet extra=
  [ "$name" = bam ] && hdr=$hdr,bam_type extra=,xoos_secondary_rescue_and_markdup
  cp "$data/$type/samplesheet.csv" "$sheets/${name}_samplesheet.csv"
  printf '%s\ntest_run,SBX-D,%s,%s,%s%s\n' "$hdr" "$type" "$data/$type" "$sheets/${name}_samplesheet.csv" "$extra" \
    > "$sheets/${name}_runsheet.csv"
  echo "== $name"
  xoos run --env "$X/env/slurm_pcs" --pipeline-script "$X/xoosnf/main.nf" --resources-base "$res" \
    --analysis-dir "$out/$name" --project "smoke-$name-$run" -- \
    --input "$sheets/${name}_runsheet.csv" -profile pcs,germline_wgs_duplex \
    -c "$cfg" -c "$PA_SHARED/conf/pcs.config" -c "$X/conf/smoke.config"
done
echo "Submitted. Watch with squeue. Results: $out/<test>/output"
EOF
chmod 755 "$PA_SHARED/bin/run-xoos-smoke"
