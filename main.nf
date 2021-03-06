#!/usr/bin/env nextflow
/*
 * Copyright (c) 2020, Oklahoma Medical Research Foundation (OMRF).
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * This Source Code Form is "Incompatible With Secondary Licenses", as
 * defined by the Mozilla Public License, v. 2.0.
 *
 */

// Nextflow pipeline for processing PacBio IsoSeq runs
// Author: Miles Smith <miles-smith@omrf.org>
// Date: 2020/09/04
// Version: 0.1.0

// File locations and program parameters

def helpMessage() {
    log.info nfcoreHeader()
    log.info """
    Usage:

      The typical command for running the pipeline is as follows:
 
      nextflow run milescsmith/nf-rnaseq \\
        --project /path/to/project \\
        --profile slurm

    Mandatory arguments:
      --project             Directory to use as a base where raw files are 
                            located and results and logs will be written
      --profile             Configuration profile to use for processing.
                            Available: slurm, gcp, standard
      
    Optional parameters:

    Reference locations:
      --species             By default, uses "chimera" for a mixed human/viral
                            index.
      --genome
      --truseq_adapter
      --truseq_rna_adapter
      --rRNAs
      --polyA
      --salmon_index
    
    Results locations:      If not specified, these will be created relative to
                            the `project` argument
                            Note: if undefined, the pipeline expects the raw BAM
                            file to be located in `/path/to/project/01_raw`
      --logs                Default: project/logs
      --raw_data            Default: project/data/raw_data
      --bcls                Default: project/data/raw_data/bcls
      --raw_fastqs          Default: project/data/raw_data/fastqs
      --results             Default: project/data/raw_data/data/results
      --qc                  Default: project/data/raw_data/data/results/qc
      --trimmed             Default: project/data/raw_data/data/results/trimmed
      --aligned             Default: project/data/raw_data/data/results/aligned

    Other:
      --help                Show this message
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

params.input = "${params.raw_fastqs}/*_S*_L00*_R{1,2}_00*.fastq.gz"

Channel
    .fromFilePairs( params.reads, checkIfExists: true, flat: true )
    .set{ raw_fastq_fastqc_reads_ch }

Channel
    .fromFilePairs( params.reads, checkIfExists: true, flat: true )
    .set{ raw_fastq_to_trim_ch }

Channel
    .fromPath( params.polyA, checkIfExists: true)
    .set{ polyA_ref }

Channel
    .fromPath( params.truseq_adapter, checkIfExists: true)
    .set{ truseq_adapter_ref }

Channel
    .fromPath( params.truseq_rna_adapter, checkIfExists: true)
    .set{ truseq_rna_adapter_ref }

Channel
    .fromPath( params.rRNAs, checkIfExists: true)
    .set{ rRNA_ref }

process initial_qc {
    //Use Fastqc to examine fastq quality

    tag "FastQC"
    // container "registry.gitlab.com/milothepsychic/rnaseq_pipeline/fastqc:0.11.9"
    
    publishDir "${params.qc}/${sample_id}", mode: "copy", pattern: "*.html", overwrite: false
    publishDir "${params.qc}/${sample_id}", mode: "copy", pattern: "*.zip", overwrite: false

    input:
        tuple val(sample_id), file(read1), file(read2) from raw_fastq_fastqc_reads_ch

    output:
         file "*.html" into fastqc_results_ch

    script:
        """
        fastqc \
            --noextract \
            --format fastq \
            --threads ${task.cpus} \
            ${read1} ${read2}
        """
}

process perfom_trimming {
    /* Use BBmap to trim known adaptors, low quality reads, and
       polyadenylated sequences and filter out ribosomal reads */

    tag "trim"
    // container "registry.gitlab.com/milothepsychic/rnaseq_pipeline/bbmap:38.86"

    input:
        tuple val(sample_id), file(read1), file(read2) from raw_fastq_to_trim_ch

    output:
        file "*.trimmed.R1.fq.gz" into trimmed_read1_ch
        file "*.trimmed.R2.fq.gz" into trimmed_read2_ch
        val sample_id into trimmed_sample_name_ch
        file "*.csv" into contamination_ch
    
    script:
    """
    bbduk.sh \
        in=${read1} \
        in2=${read2} \
        outu=${sample_id}.trimmed.R1.fq.gz \
        out2=${sample_id}.trimmed.R2.fq.gz \
        outm=removed_${sample_id}.R1.fq.gz \
        outm2=removed_${sample_id}.R2.fq.gz \
        ref=${params.polyA},${params.truseq_adapter},${params.truseq_rna_adapter},${params.rRNAs} \
        stats=contam_${sample_id}.csv \
        statscolumns=3 \
        k=13 \
        ktrim=r \
        useshortkmers=t \
        mink=5 \
        qtrim=r \
        trimq=10 \
        minlength=20
    """
}

process salmon_quant {
    tag "salmon quant"
    maxErrors 10
    errorStrategy "ignore"
    // container "combinelab/salmon:1.3.0"
    publishDir path: "${params.aligned}", mode: "copy", overwrite: true
    publishDir path: "${params.aligned}/${sample_id}", mode: "copy", pattern: "*.json", overwrite: true
    publishDir path: "${params.aligned}/${sample_id}", mode: "copy", pattern: "*.tsv", overwrite: true
    publishDir path: "${params.aligned}/${sample_id}", mode: "copy", pattern: "*.gz", overwrite: true
    publishDir path: "${params.aligned}/${sample_id}", mode: "copy", pattern: "*.txt", overwrite: true

    input:
        val sample_id from trimmed_sample_name_ch
        file trimmed_read1 from trimmed_read1_ch
        file trimmed_read2 from trimmed_read2_ch

    output:
        file "${sample_id}/quant.sf" into pseudoquant_ch, pseudoquant_to_compress_ch
        file "${sample_id}/logs/salmon_quant.log" into pseudoquant_log_ch
        val sample_id into pseudoquant_name, pseudoquant_name2

    script:
    """
    salmon quant \
        --libType A \
        --threads ${task.cpus} \
        --index ${params.salmon_index} \
        --seqBias \
        --gcBias \
        --dumpEq \
        --validateMappings \
        --mates1 ${trimmed_read1} \
        --mates2 ${trimmed_read2} \
        --output ${sample_id} \
    """
}

process multiqc {
    /* collect all qc metrics into one report */
    
    tag "multiqc"
    // container "ewels/multiqc:1.9"
    
    input:
        val sample_id from pseudoquant_name2
        file ("${sample_id}/quant.sf") from pseudoquant_ch.collect().ifEmpty([])
        file ("${sample_id}/*_fastqc.html") from fastqc_results_ch.collect().ifEmpty([])
        file ("${sample_id}/contam.csv") from contamination_ch.collect().ifEmpty([])
        file ("${sample_id}/salmon.log") from pseudoquant_log_ch.collect().ifEmpty([])
    
    output:
        file "*.html" into multiqc_ch
    
    script:
    """
    multiqc \
        -m fastqc \
        -m bbmap \
        -m salmon \
        -d \
        -ip \
        . \
    """
}

process compress_salmon_results {
    /* No reason not to compress these results since tximport
       can read gzipped files */
    
    tag "compress results"
    // container "docker://rtibiocloud/pigz:v2.4_b243f9"

    publishDir "${params.aligned}/${sample_id}", mode: "copy", pattern: "quant.sf.gz", overwrite: false

    input:
        file quant from pseudoquant_to_compress_ch
        val sample_id from pseudoquant_name

    output:
        file("quant.sf.gz")

    script:
    """
    pigz -v -f -p ${task.cpus} ${quant}
    """
}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  milescsmith/rnaseq v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}
