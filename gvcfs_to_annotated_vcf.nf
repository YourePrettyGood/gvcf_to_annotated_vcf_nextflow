#!/usr/bin/env nextflow
/* Pipeline for joint genotyping of many gVCFs                              *
 * Core steps:                                                              *
 *  GATK CombineGVCFs (in batches) -> GATK CombineGVCFs (merge batches) ->  *
 *  GATK GenotypeGVCFs (scattered) -> GATK VariantRecalibrator (gathered) ->*
 *  GATK ApplyVQSR (then repeat these two steps again for indels) ->        * 
 *  bcftools +scatter (by major chromosome) -> bcftools merge (archaics) -> *
 *  bcftools annotate (dbSNP)                                               *
 * QC steps:                                                                *
 *  ValidateVariants (on final VCF)                                         */

//Default paths, globs, and regexes:
params.gvcf_glob = "${projectDir}/gVCFs/*.g.vcf.gz"

//Reference-related parameters for the pipeline:
params.ref_prefix = "/gpfs/gibbs/pi/tucci/pfr8/refs"
params.ref = "${params.ref_prefix}/1kGP/hs37d5/hs37d5.fa"
//File of file names for scattering interval BED files for joint genotyping:
params.scattered_bed_fofn = "${params.ref_prefix}/1kGP/hs37d5/scatter_intervals/hs37d5_thresh_50Mbp_autosomes_scattered_BEDs.fofn"

//Databases of SNPs and INDELs for VQSR:
params.hapmap_snps = "${params.ref_prefix}/Broad/b37/hapmap_3.3.b37.vcf"
params.omni_snps = "${params.ref_prefix}/Broad/b37/1000G_omni2.5.b37.vcf"
params.tgp_snps = "${params.ref_prefix}/Broad/b37/1000G_phase1.snps.high_confidence.b37.vcf"
//params.tgp_indels = "${params.ref_prefix}/Broad/b37/1000G_phase1.indels.b37.vcf"
params.dbsnp_vqsr = "${params.ref_prefix}/Broad/b37/dbsnp_138.b37.vcf"
params.mills_indels = "${params.ref_prefix}/Broad/b37/Mills_and_1000G_gold_standard.indels.b37.vcf"

//Set up the channels of gVCFs:
sample_id = 0
Channel
   .fromPath(params.gvcf_glob, checkIfExists: true)
   .ifEmpty { error "Unable to find gVCFs matching glob: ${params.gvcf_glob}" }
   .map { gvcf -> sample_id += 1; return [sample_id, gvcf.getSimpleName(), gvcf] }
   .tap { gvcfs }
   .subscribe { println "Added ${it[1]} (${it[2]}) to gvcfs channel" }

//Set up the file channels for the ref and its various index components:
//Inspired by the IARC alignment-nf pipeline
//fai is generated by samtools faidx, and dict is generated by Picard and used by GATK
ref = file(params.ref, checkIfExists: true)
ref_dict = file(params.ref.replaceFirst("[.]fn?a(sta)?([.]gz)?", ".dict"), checkIfExists: true)
ref_fai = file(params.ref+'.fai', checkIfExists: true)

//Known sites files for VQSR:
known_hapmap = file(params.hapmap_snps, checkIfExists: true)
known_hapmap_idx = file(params.hapmap_snps+'.idx', checkIfExists: true)
known_omni = file(params.omni_snps, checkIfExists: true)
known_omni_idx = file(params.omni_snps+'.idx', checkIfExists: true)
known_tgp = file(params.tgp_snps, checkIfExists: true)
known_tgp_idx = file(params.tgp_snps+'.idx', checkIfExists: true)
known_dbsnp = file(params.dbsnp_vqsr, checkIfExists: true)
known_dbsnp_idx = file(params.dbsnp_vqsr+'.idx', checkIfExists: true)
known_mills_indels = file(params.mills_indels, checkIfExists: true)
known_mills_indels_idx = file(params.mills_indels+'.idx', checkIfExists: true)

//dbSNP VCF for bcftools annotate:
dbsnp = file(params.dbsnp, checkIfExists: true)
dbsnp_idx = file(params.dbsnp+'.tbi', checkIfExists: true)

//Default parameter values:
//Regex for parsing the reference chunk ID out from the reference chunk BED filename:
params.ref_chunk_regex = ~/^.+_region(\p{Digit}+)$/
//Regex for parsing the reference chunk ID out from the joint genotyped VCF filename:
//vcf_region_regex = ~/^.+_region(\p{Digit}+)$/
//   path("${params.run_name}_region${ref_chunk}.vcf.gz") into genotyped_vcfs
//Regex for parsing the batch ID out from the gVCF filename:
//gvcf_batch_regex = ~/^.+_batch(\p{Digit}+)_region\p{Digit}+$/
//Number of distributions to use in the mixture models for VQSR:
//Number of multivariate Normal distributions to use in the "positive" mixture
// model for SNP VQSR:
//Byrska-Bishop et al. 2021 BioRxiv uses 8, the default
params.snp_mvn_k = 8
//Number of multivariate Normal distributions to use in the "positive" mixture
// model for INDEL VQSR:
//Byrska-Bishop et al. 2021 BioRxiv uses 4, recommended when less sites are
// available for training
params.indel_mvn_k = 4

//Defaults for cpus, memory, and time for each process:
//GATK IndexFeatureFile
params.index_cpus = 1
params.index_mem = 1
params.index_timeout = '1h'
//GATK CombineGVCFs tier one
params.tierone_cpus = 1
params.tierone_mem = 16
params.tierone_timeout = '48h'
if (params.tierone_mem < 4) {
   error "Running the first tier of combining gVCFs with less than 4 GB RAM probably won't work"
}
//GATK CombineGVCFs tier two
params.tiertwo_cpus = 1
params.tiertwo_mem = 16
params.tiertwo_timeout = '48h'
if (params.tiertwo_mem < 4) {
   error "Running the second tier of combining gVCFs with less than 4 GB RAM probably won't work"
}
//GATK GenotypeGVCFs
params.jointgeno_cpus = 1
params.jointgeno_mem = 64
params.jointgeno_timeout = '24h'
//VQSR
params.vqsr_cpus = 1
params.vqsr_mem = 8
params.vqsr_timeout = '24h'
//Scatter VCF by chromosome
params.scatter_cpus = 1
params.scatter_mem = 16
params.scatter_timeout = '24h'
//Merge VCFs with archaics and PanTro from EPO
params.archaic_cpus = 20
params.archaic_mem = 32
params.archaic_timeout = '24h'
//Annotate VCF with dbSNP
params.dbsnp_cpus = 1
params.dbsnp_mem = 16
params.dbsnp_timeout = '24h'
//GATK ValidateVariants
params.vcf_check_cpus = 1
params.vcf_check_mem = 1
params.vcf_check_timeout = '24h'

//Define the list of chromosomes to scatter:
if (params.chroms == "autosomes") {
   //1-22
   params.chrom_list = params.autosomes
} else if (params.chroms == "nuclear") {
   //1-22,X,Y
   params.chrom_list = params.nuclear_chroms
} else {
   //1-22,X,Y,mtDNA
   params.chrom_list = params.major_chroms
}

//Scatter interval BED file list for gVCF scattering:
Channel
   .fromPath(params.scattered_bed_fofn, checkIfExists: true)
   .splitText()
   .map { line -> file(line.replaceAll(/[\r\n]+$/, ""), checkIfExists: true) }
   .tap { scattered_regions }
   .map { bed -> [ (bed.getSimpleName() =~ params.ref_chunk_regex)[0][1].toInteger(), bed ] }
   .tap { scattered_regions_tojoin }
   .subscribe { println "Added region ${it[0]} (${it[1]}) to scattered_regions channel" }
num_scattered = file(params.scattered_bed_fofn, checkIfExists: true)
   .readLines()
   .size()

//Set up the channels of Archaic per-chromosome VCFs and their indices:
Channel
   .fromPath(params.arcvcf_glob, checkIfExists: true)
   .ifEmpty { error "Unable to find archaic VCFs matching glob: ${params.arcvcf_glob}" }
   .map { a -> [ (a.getSimpleName() =~ params.arc_regex)[0][1], a] }
   .filter { params.chrom_list.tokenize(',').contains(it[0]) }
   .tap { arc_vcfs }
   .subscribe { println "Added ${it[1]} to arc_vcfs channel" }

Channel
   .fromPath(params.arcvcf_glob+'.tbi', checkIfExists: true)
   .ifEmpty { error "Unable to find archaic VCF indices matching glob: ${params.arcvcf_glob}.tbi" }
   .map { a -> [ (a.getSimpleName() =~ params.arc_regex)[0][1], a] }
   .filter { params.chrom_list.tokenize(',').contains(it[0]) }
   .tap { arc_vcf_indices }
   .subscribe { println "Added ${it[1]} to arc_vcf_indices channel" }

//Set up the channels of PanTro EPO per-chromosome VCFs and their indices:
Channel
   .fromPath(params.pantrovcf_glob, checkIfExists: true)
   .ifEmpty { error "Unable to find PanTro EPO VCFs matching glob: ${params.pantrovcf_glob}" }
   .map { a -> [ (a.getSimpleName() =~ params.pantro_regex)[0][1], a] }
   .filter { params.chrom_list.tokenize(',').contains(it[0]) }
   .tap { pantro_vcfs }
   .subscribe { println "Added ${it[1]} to pantro_vcfs channel" }

Channel
   .fromPath(params.pantrovcf_glob+'.tbi', checkIfExists: true)
   .ifEmpty { error "Unable to find PanTro EPO VCF indices matching glob: ${params.pantrovcf_glob}.tbi" }
   .map { a -> [ (a.getSimpleName() =~ params.pantro_regex)[0][1], a] }
   .filter { params.chrom_list.tokenize(',').contains(it[0]) }
   .tap { pantro_vcf_indices }
   .subscribe { println "Added ${it[1]} to pantro_vcf_indices channel" }

process index_gvcfs {
   tag "${sample_id}"

   cpus params.index_cpus
   memory { params.index_mem.plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 2 ? '6h' : params.index_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(sample_id), val(sample), path("${sample}.g.vcf.gz") from gvcfs

   output:
   tuple path("GATK_IndexFeatureFile_sample${sample_id}.stderr"), path("GATK_IndexFeatureFile_sample${sample_id}.stdout") into index_logs
   tuple val(batch_id), path("${sample}.g.vcf.gz") into gvcfs_tobatch
   tuple val(batch_id), path("${sample}.g.vcf.gz.tbi") into gvcf_indices_tobatch

   shell:
   batch_id = sample_id.minus(1).intdiv(params.batch_size)
   '''
   module load !{params.mod_gatk4}
   gatk IndexFeatureFile -I !{sample}.g.vcf.gz 2> GATK_IndexFeatureFile_sample!{sample_id}.stderr > GATK_IndexFeatureFile_sample!{sample_id}.stdout
   '''
}

process combine_tierone {
   tag "${batch_id}_${ref_chunk}"

   cpus params.tierone_cpus
   memory { params.tierone_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.tierone_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(batch_id), path(ingvcfs) from gvcfs_tobatch.groupTuple(by: 0, size: params.batch_size, remainder: true, sort: true)
   tuple val(idx_batch_id), path(ingvcfidx) from gvcf_indices_tobatch.groupTuple(by: 0, size: params.batch_size, remainder: true, sort: true)
   path ref
   path ref_dict
   path ref_fai
   each path(regions) from scattered_regions

   output:
   tuple path("${params.run_name}_GATK_CombineGVCFs_tierone_batch${batch_id}_region${ref_chunk}.stderr"), path("${params.run_name}_GATK_CombineGVCFs_tierone_batch${batch_id}_region${ref_chunk}.stdout") into tierone_logs
   tuple val(ref_chunk_int), path("${params.run_name}_tierone_batch${batch_id}_region${ref_chunk}.g.vcf.gz") into tierone_gvcfs
   tuple val(ref_chunk_int), path("${params.run_name}_tierone_batch${batch_id}_region${ref_chunk}.g.vcf.gz.tbi") into tierone_gvcf_indices

   shell:
   combine_retry_mem = params.tierone_mem.plus(task.attempt.minus(1).multiply(16))
   ref_chunk = (regions.getSimpleName() =~ params.ref_chunk_regex)[0][1]
   ref_chunk_int = ref_chunk.toInteger()
   ingvcf_list = ingvcfs
      .collect { ingvcf -> "-V ${ingvcf} " }
      .join()
   '''
   module load !{params.mod_gatk4}
   gatk --java-options "-Xmx!{combine_retry_mem}g -Xms!{combine_retry_mem}g" CombineGVCFs -R !{ref} -L !{regions} -O !{params.run_name}_tierone_batch!{batch_id}_region!{ref_chunk}.g.vcf.gz !{ingvcf_list} 2> !{params.run_name}_GATK_CombineGVCFs_tierone_batch!{batch_id}_region!{ref_chunk}.stderr > !{params.run_name}_GATK_CombineGVCFs_tierone_batch!{batch_id}_region!{ref_chunk}.stdout
   '''
}

process combine_final {
   tag "${ref_chunk}"

   cpus params.tiertwo_cpus
   memory { params.tiertwo_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.tiertwo_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(ref_chunk), path(ingvcfs), path(regions) from tierone_gvcfs.groupTuple(by: 0, sort: {a,b -> (a.getSimpleName() =~ ~/^.+_batch(\p{Digit}+)_region\p{Digit}+$/)[0][1].toInteger() <=> (b.getSimpleName() =~ ~/^.+_batch(\p{Digit}+)_region\p{Digit}+$/)[0][1].toInteger()}).ifEmpty( { error "groupTuple on tierone_gvcfs is empty" } ).combine(scattered_regions_tojoin, by: 0).ifEmpty( { error "combine of tierone batch gvcfs by ref region with region files was empty" } )
   tuple val(idx_ref_chunk), path(ingvcfidx) from tierone_gvcf_indices.groupTuple(by: 0)
   path ref
   path ref_dict
   path ref_fai

   output:
   tuple path("${params.run_name}_GATK_CombineGVCFs_tiertwo_region${ref_chunk}.stderr"), path("${params.run_name}_GATK_CombineGVCFs_tiertwo_region${ref_chunk}.stdout") into tiertwo_logs
   tuple val(ref_chunk), path("${params.run_name}_tiertwo_region${ref_chunk}.g.vcf.gz"), path("${regions}") into tiertwo_gvcfs
   tuple val(ref_chunk), path("${params.run_name}_tiertwo_region${ref_chunk}.g.vcf.gz.tbi") into tiertwo_gvcf_indices

   shell:
   combine_retry_mem = params.tiertwo_mem.plus(task.attempt.minus(1).multiply(16))
   ingvcf_list = ingvcfs
      .collect { ingvcf -> "-V ${ingvcf} " }
      .join()
   '''
   module load !{params.mod_gatk4}
   gatk --java-options "-Xmx!{combine_retry_mem}g -Xms!{combine_retry_mem}g" CombineGVCFs -R !{ref} -L !{regions} -O !{params.run_name}_tiertwo_region!{ref_chunk}.g.vcf.gz !{ingvcf_list} 2> !{params.run_name}_GATK_CombineGVCFs_tiertwo_region!{ref_chunk}.stderr > !{params.run_name}_GATK_CombineGVCFs_tiertwo_region!{ref_chunk}.stdout
   '''
}

process joint_genotype {
   tag "${ref_chunk}"

   cpus params.jointgeno_cpus
   memory { params.jointgeno_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.jointgeno_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(ref_chunk), path(ingvcf), path(regions) from tiertwo_gvcfs
   tuple val(idx_ref_chunk), path(ingvcfidx) from tiertwo_gvcf_indices
   path ref
   path ref_dict
   path ref_fai

   output:
   path("${params.run_name}_region${ref_chunk}.vcf.gz") into genotyped_vcfs
   path("${params.run_name}_region${ref_chunk}.vcf.gz.tbi") into genotyped_vcf_indices

   shell:
   jointgeno_retry_mem = params.jointgeno_mem.plus(task.attempt.minus(1).multiply(16))
   '''
   module load !{params.mod_gatk4}
   gatk --java-options "-Xmx!{jointgeno_retry_mem}g -Xms!{jointgeno_retry_mem}g" GenotypeGVCFs -R !{ref} -L !{regions} -O !{params.run_name}_region!{ref_chunk}.vcf.gz -V !{ingvcf} 2> !{params.run_name}_GATK_GenotypeGVCFs_region!{ref_chunk}.stderr > !{params.run_name}_GATK_GenotypeGVCFs_region!{ref_chunk}.stdout
   '''
}
//

//VQSR
/*
process vqsr {
   //tag ""

   cpus params.vqsr_cpus
   memory { params.vqsr_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.vqsr_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*.tranches'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*_plots.R'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*.recal.vcf'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*_fixed.vcf.g*'

   input:
   path(vcfs) from genotyped_vcfs.toSortedList( { a,b -> (a.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() <=> (b.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() } )
   path(vcf_indices) from genotyped_vcf_indices.toSortedList( { a,b -> (a.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() <=> (b.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() } )
   path ref
   path ref_dict
   path ref_fai
   path known_hapmap
   path known_hapmap_idx
   path known_omni
   path known_omni_idx
   path known_tgp
   path known_tgp_idx
   path known_dbsnp
   path known_dbsnp_idx
   path known_mills_indels
   path known_mills_indels_idx

   output:
   tuple path("${params.run_name}_GATK_SNP_recal.stderr"), path("${params.run_name}_GATK_SNP_recal.stdout"), path("${params.run_name}_GATK_SNP_VQSR.stderr"), path("${params.run_name}_GATK_SNP_VQSR.stdout"), path("${params.run_name}_GATK_INDEL_recal.stderr"), path("${params.run_name}_GATK_INDEL_recal.stdout"), path("${params.run_name}_GATK_INDEL_VQSR.stderr"), path("${params.run_name}_GATK_INDEL_VQSR.stdout") into vqsr_logs
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_plots.R"), path("${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf"), path("${params.run_name}_SNPVQSR_${params.snp_sens}.tranches") into snpvqsr_aux_output
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_plots.R"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches") into indelvqsr_aux_output
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_fixed.vcf.gz"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_fixed.vcf.gz.tbi") into snp_vqsr_vcf
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_fixed.vcf.gz"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_fixed.vcf.gz.tbi") into final_vqsr_vcf

   shell:
   vqsr_retry_mem = params.vqsr_mem.plus(task.attempt.minus(1).multiply(16))
   firstvcf = vcfs
      .first()
   invcf_list = vcfs
      .collect { vcf -> "-V ${vcf} " }
      .join()
   snp_recal_params = """-mode SNP \
    --rscript-file ${params.run_name}_SNPVQSR_${params.snp_sens}_plots.R \
    -O ${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}.tranches \
    -an QD -an DP -an FS -an SOR -an MQ -an ReadPosRankSum -an MQRankSum \
    --resource:hapmap,known=false,training=true,truth=true,prior=15.0 \
    ${known_hapmap} \
    --resource:omni,known=false,training=true,truth=true,prior=12.0 \
    ${known_omni} \
    --resource:1000G,known=false,training=true,truth=false,prior=10.0 \
    ${known_tgp} \
    --resource:dbsnp,known=true,training=false,truth=false,prior=7.0 \
    ${known_dbsnp} \
    -tranche 100.0 -tranche 99.9 -tranche 99.5 -tranche 99.0 \
    -tranche 98.5 -tranche 98.0 -tranche 97.5 -tranche 97.0 \
    --max-gaussians ${params.snp_mvn_k}"""
   snp_vqsr_params = """-mode SNP \
    --recal-file ${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}.tranches \
    --ts-filter-level ${params.snp_sens}"""
   indel_recal_params = """-mode INDEL \
    --rscript-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_plots.R \
    -O ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches \
    -an QD -an DP -an FS -an SOR -an MQ -an ReadPosRankSum -an MQRankSum \
    --resource:mills,known=false,training=true,truth=true,prior=12.0 \
    ${known_mills_indels} \
    --resource:dbsnp,known=true,training=false,truth=false,prior=7.0 \
    ${known_dbsnp} \
    -tranche 100.0 -tranche 99.9 -tranche 99.5 -tranche 99.0 \
    -tranche 98.5 -tranche 98.0 -tranche 97.5 -tranche 97.0 \
    --max-gaussians ${params.indel_mvn_k}"""
   indel_vqsr_params = """-mode INDEL \
    --recal-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches \
    --ts-filter-level ${params.indel_sens}"""
   '''
   module load !{params.mod_bcftools}
   module load !{params.mod_htslib}
   module load !{params.mod_gatk4}
   module load !{params.mod_R}
   #SNP VQSR outputs:
   snp_vqsr_vcf="!{params.run_name}_SNPVQSR_!{params.snp_sens}.vcf.gz"
   snp_vqsr_fixed_header=${snp_vqsr_vcf//.vcf.gz/_fixedHeader.vcf.gz}
   snp_vqsr_fixed_vcf=${snp_vqsr_vcf//.vcf.gz/_fixed.vcf.gz}
   #Run SNP VQSR:
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" VariantRecalibrator -R !{ref} !{snp_recal_params} !{invcf_list} 2> !{params.run_name}_GATK_SNP_recal.stderr > !{params.run_name}_GATK_SNP_recal.stdout
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" ApplyVQSR -R !{ref} !{snp_vqsr_params} !{invcf_list} -O ${snp_vqsr_vcf} 2> !{params.run_name}_GATK_SNP_VQSR.stderr > !{params.run_name}_GATK_SNP_VQSR.stdout
   #Fix the VCF header produced by ApplyVQSR:
   #ApplyVQSR produces a #CHROM line without any FORMAT or SAMPLE column
   # headers, so we replace that line with one from an input VCF.
   cat <(bcftools view -h ${snp_vqsr_vcf} | fgrep -v '#CHROM') <(bcftools view -h !{firstvcf} | fgrep '#CHROM') | bgzip -c > ${snp_vqsr_fixed_header}
   bcftools reheader -h ${snp_vqsr_fixed_header} -o ${snp_vqsr_fixed_vcf} ${snp_vqsr_vcf}
   tabix -f ${snp_vqsr_fixed_vcf}
   #INDEL VQSR outputs:
   indel_vqsr_vcf="!{params.run_name}_SNPVQSR_!{params.snp_sens}_INDELVQSR_!{params.indel_sens}.vcf.gz"
   indel_vqsr_fixed_header=${indel_vqsr_vcf//.vcf.gz/_fixedHeader.vcf.gz}
   indel_vqsr_fixed_vcf=${indel_vqsr_vcf//.vcf.gz/_fixed.vcf.gz}
   #Run INDEL VQSR:
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" VariantRecalibrator -R !{ref} !{indel_recal_params} -V ${snp_vqsr_fixed_vcf} 2> !{params.run_name}_GATK_INDEL_recal.stderr > !{params.run_name}_GATK_INDEL_recal.stdout
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" ApplyVQSR -R !{ref} !{indel_vqsr_params} -V ${snp_vqsr_fixed_vcf} -O ${indel_vqsr_vcf} 2> !{params.run_name}_GATK_INDEL_VQSR.stderr > !{params.run_name}_GATK_INDEL_VQSR.stdout
   #Fix the VCF header produced by ApplyVQSR:
   #ApplyVQSR produces a #CHROM line without any FORMAT or SAMPLE column
   # headers, so we replace that line with one from an input VCF.
   cat <(bcftools view -h ${indel_vqsr_vcf} | fgrep -v '#CHROM') <(bcftools view -h !{firstvcf} | fgrep '#CHROM') | bgzip -c > ${indel_vqsr_fixed_header}
   bcftools reheader -h ${indel_vqsr_fixed_header} -o ${indel_vqsr_fixed_vcf} ${indel_vqsr_vcf}
   tabix -f ${indel_vqsr_fixed_vcf}
   '''
}
*/
process vqsr {
   //tag ""

   cpus params.vqsr_cpus
   memory { params.vqsr_mem.plus(1).plus(task.attempt.minus(1).multiply(32))+' GB' }
   time { task.attempt == 2 ? '72h' : params.vqsr_timeout }
   errorStrategy { task.exitStatus in ([1]+(134..140).collect()) ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*.tranches'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*_plots.R'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*.recal.vcf'
   publishDir path: "${params.output_dir}/VQSR", mode: 'copy', pattern: '*_sites.vcf.g*'

   input:
   path(vcfs) from genotyped_vcfs.toSortedList( { a,b -> (a.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() <=> (b.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() } )
   path(vcf_indices) from genotyped_vcf_indices.toSortedList( { a,b -> (a.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() <=> (b.getSimpleName() =~ ~/^.+_region(\p{Digit}+)$/)[0][1].toInteger() } )
   path ref
   path ref_dict
   path ref_fai
   path known_hapmap
   path known_hapmap_idx
   path known_omni
   path known_omni_idx
   path known_tgp
   path known_tgp_idx
   path known_dbsnp
   path known_dbsnp_idx
   path known_mills_indels
   path known_mills_indels_idx

   output:
   tuple path("${params.run_name}_GATK_SNP_recal.stderr"), path("${params.run_name}_GATK_SNP_recal.stdout"), path("${params.run_name}_GATK_SNP_VQSR.stderr"), path("${params.run_name}_GATK_SNP_VQSR.stdout"), path("${params.run_name}_GATK_INDEL_recal.stderr"), path("${params.run_name}_GATK_INDEL_recal.stdout"), path("${params.run_name}_GATK_INDEL_VQSR.stderr"), path("${params.run_name}_GATK_INDEL_VQSR.stdout"), path("${params.run_name}_bcftools_concat_jgVCFs.stderr"), path("${params.run_name}_bcftools_concat_jgVCFs.stdout"), path("${params.run_name}_bcftools_annotate_VQSR.stderr"), path("${params.run_name}_bcftools_annotate_VQSR.stdout") into vqsr_logs
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_plots.R"), path("${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf"), path("${params.run_name}_SNPVQSR_${params.snp_sens}.tranches") into snpvqsr_aux_output
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_plots.R"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches") into indelvqsr_aux_output
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_sites.vcf.gz"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_sites.vcf.gz.tbi") into snp_vqsr_vcf
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_sites.vcf.gz"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_sites.vcf.gz.tbi") into indel_vqsr_vcf
   tuple path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.vcf.gz"), path("${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.vcf.gz.tbi") into final_vqsr_vcf

   shell:
   vqsr_retry_mem = params.vqsr_mem.plus(task.attempt.minus(1).multiply(32))
   invcf_list = vcfs
      .collect { vcf -> "-V ${vcf} " }
      .join()
   snp_recal_params = """-mode SNP \
    --rscript-file ${params.run_name}_SNPVQSR_${params.snp_sens}_plots.R \
    -O ${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}.tranches \
    -an QD -an DP -an FS -an SOR -an MQ -an ReadPosRankSum -an MQRankSum \
    --resource:hapmap,known=false,training=true,truth=true,prior=15.0 \
    ${known_hapmap} \
    --resource:omni,known=false,training=true,truth=true,prior=12.0 \
    ${known_omni} \
    --resource:1000G,known=false,training=true,truth=false,prior=10.0 \
    ${known_tgp} \
    --resource:dbsnp,known=true,training=false,truth=false,prior=7.0 \
    ${known_dbsnp} \
    -tranche 100.0 -tranche 99.9 -tranche 99.5 -tranche 99.0 \
    -tranche 98.5 -tranche 98.0 -tranche 97.5 -tranche 97.0 \
    --max-gaussians ${params.snp_mvn_k}"""
   snp_vqsr_params = """-mode SNP \
    --recal-file ${params.run_name}_SNPVQSR_${params.snp_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}.tranches \
    --ts-filter-level ${params.snp_sens}"""
   indel_recal_params = """-mode INDEL \
    --rscript-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}_plots.R \
    -O ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches \
    -an QD -an DP -an FS -an SOR -an MQ -an ReadPosRankSum -an MQRankSum \
    --resource:mills,known=false,training=true,truth=true,prior=12.0 \
    ${known_mills_indels} \
    --resource:dbsnp,known=true,training=false,truth=false,prior=7.0 \
    ${known_dbsnp} \
    -tranche 100.0 -tranche 99.9 -tranche 99.5 -tranche 99.0 \
    -tranche 98.5 -tranche 98.0 -tranche 97.5 -tranche 97.0 \
    --max-gaussians ${params.indel_mvn_k}"""
   indel_vqsr_params = """-mode INDEL \
    --recal-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.recal.vcf \
    --tranches-file ${params.run_name}_SNPVQSR_${params.snp_sens}_INDELVQSR_${params.indel_sens}.tranches \
    --ts-filter-level ${params.indel_sens}"""
   '''
   module load !{params.mod_bcftools}
   module load !{params.mod_htslib}
   module load !{params.mod_R}
   module load !{params.mod_gatk4}
   #Generate the sites-only input VCFs:
   invcf_list="!{invcf_list}"
   jgvcfs=${invcf_list//-V /};
   invcf_list="";
   rm_list="";
   for fullvcf in ${jgvcfs};
      do
      sitesvcf=${fullvcf//.vcf.gz/_sites.vcf.gz};
      echo "Generating sites-only VCF from ${fullvcf}"
      date
      bcftools view -G -Oz -o ${sitesvcf} ${fullvcf}
      tabix -f ${sitesvcf}
      invcf_list="${invcf_list}-V ${sitesvcf} "
      rm_list="${rm_list}${sitesvcf} "
      rm_list="${rm_list}${sitesvcf}.tbi "
      date
   done
   #SNP VQSR output:
   snp_vqsr_vcf="!{params.run_name}_SNPVQSR_!{params.snp_sens}_sites.vcf.gz"
   #Run SNP VQSR:
   echo "SNP mode GATK VariantRecalibrator"
   date
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" VariantRecalibrator -R !{ref} !{snp_recal_params} ${invcf_list} 2> !{params.run_name}_GATK_SNP_recal.stderr > !{params.run_name}_GATK_SNP_recal.stdout
   date
   echo "SNP mode GATK ApplyVQSR"
   date
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" ApplyVQSR -R !{ref} !{snp_vqsr_params} ${invcf_list} -O ${snp_vqsr_vcf} 2> !{params.run_name}_GATK_SNP_VQSR.stderr > !{params.run_name}_GATK_SNP_VQSR.stdout
   date
   tabix -f ${snp_vqsr_vcf}
   #INDEL VQSR output:
   indel_vqsr_vcf="!{params.run_name}_SNPVQSR_!{params.snp_sens}_INDELVQSR_!{params.indel_sens}_sites.vcf.gz"
   #Run INDEL VQSR:
   echo "INDEL mode GATK VariantRecalibrator"
   date
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" VariantRecalibrator -R !{ref} !{indel_recal_params} -V ${snp_vqsr_vcf} 2> !{params.run_name}_GATK_INDEL_recal.stderr > !{params.run_name}_GATK_INDEL_recal.stdout
   date
   echo "INDEL mode GATK ApplyVQSR"
   date
   gatk --java-options "-Xmx!{vqsr_retry_mem}g -Xms!{vqsr_retry_mem}g" ApplyVQSR -R !{ref} !{indel_vqsr_params} -V ${snp_vqsr_vcf} -O ${indel_vqsr_vcf} 2> !{params.run_name}_GATK_INDEL_VQSR.stderr > !{params.run_name}_GATK_INDEL_VQSR.stdout
   date
   tabix -f ${indel_vqsr_vcf}
   #Concatenate the jointly genotyped VCFs together so we can annotate:
   echo "Concatenating jointly genotyped VCFs"
   date
   bcftools concat -Oz -o !{params.run_name}_concat.vcf.gz ${jgvcfs[@]} 2> !{params.run_name}_bcftools_concat_jgVCFs.stderr > !{params.run_name}_bcftools_concat_jgVCFs.stdout
   date
   tabix -f !{params.run_name}_concat.vcf.gz
   rm_list="${rm_list}!{params.run_name}_concat.vcf.gz "
   rm_list="${rm_list}!{params.run_name}_concat.vcf.gz.tbi "
   #Now annotate with the the results of VQSR:
   final_vqsr_vcf="!{params.run_name}_SNPVQSR_!{params.snp_sens}_INDELVQSR_!{params.indel_sens}.vcf.gz"
   echo "Adding VQSR info from FILTER and INFO columns to concatenated VCF"
   date
   bcftools annotate -a ${indel_vqsr_vcf} -c FILTER,INFO -Oz -o ${final_vqsr_vcf} !{params.run_name}_concat.vcf.gz 2> !{params.run_name}_bcftools_annotate_VQSR.stderr > !{params.run_name}_bcftools_annotate_VQSR.stdout
   date
   tabix -f ${final_vqsr_vcf}
   #Clean up:
   rm ${rm_list[@]}
   '''
}

//Split into the major chromosomes for faster merging and annotation downstream:
//Slight change 2022/03/15: Filter out any ALTs missing from genotypes before
// splitting. ValidateVariants dislikes these, but HaplotypeCaller and
// GenotypeGVCFs produce them, annoyingly, so we need to get rid of them
// before dbSNP annotation.
process perchrom_vcfs {
   //tag ""

   cpus params.scatter_cpus
   memory { params.scatter_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '48h' : params.scatter_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/modern_VCFs", mode: 'copy', pattern: '*_chr*.vcf.g{z,z.tbi}'

   input:
   tuple path(invcf), path(invcfidx) from final_vqsr_vcf

   output:
   tuple path("${params.run_name}_bcftools_scatter.stderr"), path("${params.run_name}_bcftools_scatter.stdout") into scatter_vcf_logs
   path "${params.run_name}_chr*.vcf.gz" into scattered_vcfs
   path "${params.run_name}_chr*.vcf.gz.tbi" into scattered_vcf_indices

   shell:
   '''
   module load !{params.mod_bcftools}
   module load !{params.mod_htslib}
   bcftools view -Ou -a !{invcf} 2> !{params.run_name}_bcftools_trimalts.stderr | \
      bcftools +scatter -Oz -o ./ -s !{params.chrom_list} -p !{params.run_name}_chr -x other - 2> !{params.run_name}_bcftools_scatter.stderr > !{params.run_name}_bcftools_scatter.stdout
   IFS="," read -r -a chromarray <<< "!{params.chrom_list}"
   for c in "${chromarray[@]}";
      do
      tabix -f ./!{params.run_name}_chr${c}.vcf.gz
   done
   '''
}

//Merge per-chromosome with the archaics:
process add_archaic {
   tag "${chrom}"

   cpus params.archaic_cpus
   memory { params.archaic_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.archaic_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(chrom), path(invcf), path(arcvcf), path(pantrovcf) from scattered_vcfs.flatMap().map( { a -> [ (a =~ ~/_chr(\p{Alnum}+)[.]vcf[.]gz/)[0][1], a] } ).combine(arc_vcfs, by: 0).combine(pantro_vcfs, by: 0)
   tuple val(idx_chrom), path(invcfidx), path(arcvcfidx), path(pantrovcfidx) from scattered_vcf_indices.flatMap().map( { a -> [ (a =~ ~/_chr(\p{Alnum}+)[.]vcf[.]gz[.]tbi/)[0][1], a] } ).combine(arc_vcf_indices, by: 0).combine(pantro_vcf_indices, by: 0)

   output:
   tuple path("${params.run_name}_bcftools_merge_mall_archaics_PanTro_chr${chrom}.stderr"), path("${params.run_name}_bcftools_merge_mall_archaics_PanTro_chr${chrom}.stdout") into addarc_logs
   tuple val(chrom), path("${params.run_name}_wArchaics_chr${chrom}.vcf.gz") into addarc_vcfs
   tuple val(idx_chrom), path("${params.run_name}_wArchaics_chr${chrom}.vcf.gz.tbi") into addarc_vcf_indices

   shell:
   '''
   module load !{params.mod_bcftools}
   module load !{params.mod_htslib}
   bcftools merge -m all -Oz -o !{params.run_name}_wArchaics_chr!{chrom}.vcf.gz !{invcf} !{arcvcf} !{pantrovcf} 2> !{params.run_name}_bcftools_merge_mall_archaics_PanTro_chr!{chrom}.stderr > !{params.run_name}_bcftools_merge_mall_archaics_PanTro_chr!{chrom}.stdout
   tabix -f !{params.run_name}_wArchaics_chr!{chrom}.vcf.gz
   '''
}

//Annotate the per-chromosome VCFs with rsids from dbSNP:
process annotate_dbsnp {
   tag "${chrom}"

   cpus params.dbsnp_cpus
   memory { params.dbsnp_mem.plus(1).plus(task.attempt.minus(1).multiply(16))+' GB' }
   time { task.attempt == 2 ? '72h' : params.dbsnp_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'
   publishDir path: "${params.output_dir}/final_VCFs", mode: 'copy', pattern: '*_wArchaics_dbSNP*.vcf.g*'

   input:
   tuple val(chrom), path(invcf) from addarc_vcfs
   tuple val(idx_chrom), path(invcfidx) from addarc_vcf_indices
   path dbsnp
   path dbsnp_idx

   output:
   tuple path("${params.run_name}_bcftools_annotate_chr${chrom}.stderr"), path("${params.run_name}_bcftools_annotate_chr${chrom}.stdout") into dbsnp_logs
   tuple val(chrom), path("${params.run_name}_wArchaics_dbSNP${params.dbsnp_build}_chr${chrom}.vcf.gz"), path("${params.run_name}_wArchaics_dbSNP${params.dbsnp_build}_chr${chrom}.vcf.gz.tbi") into dbsnp_pass_vcf

   shell:
   '''
   module load !{params.mod_bcftools}
   module load !{params.mod_htslib}
   inputvcf="!{invcf}"
   annotatedvcf=${inputvcf//_wArchaics/_wArchaics_dbSNP!{params.dbsnp_build}};
   bcftools annotate -a !{dbsnp} -c ID -Oz -o ${annotatedvcf} !{invcf} 2> !{params.run_name}_bcftools_annotate_chr!{chrom}.stderr > !{params.run_name}_bcftools_annotate_chr!{chrom}.stdout
   tabix -f ${annotatedvcf}
   '''
}

process validate_vcf {
   tag "${chrom}"

   cpus params.vcf_check_cpus
   memory { params.vcf_check_mem.plus(1).plus(task.attempt.minus(1).multiply(4))+' GB' }
   time { task.attempt == 2 ? '48h' : params.vcf_check_timeout }
   errorStrategy { task.exitStatus in 134..140 ? 'retry' : 'terminate' }
   maxRetries 1

   publishDir path: "${params.output_dir}/logs", mode: 'copy', pattern: '*.std{err,out}'

   input:
   tuple val(chrom), path("${params.run_name}_wArchaics_dbSNP${params.dbsnp_build}_chr${chrom}.vcf.gz"), path("${params.run_name}_wArchaics_dbSNP${params.dbsnp_build}_chr${chrom}.vcf.gz.tbi") from dbsnp_pass_vcf
   path ref
   path ref_dict
   path ref_fai
   path dbsnp
   path dbsnp_idx

   output:
   tuple file("${params.run_name}_final_chr${chrom}_GATK_ValidateVariants.stderr"), file("${params.run_name}_final_chr${chrom}_GATK_ValidateVariants.stdout") into validate_vcf_logs

   shell:
   validate_retry_mem = params.vcf_check_mem.plus(task.attempt.minus(1).multiply(4))
   '''
   module load !{params.mod_gatk4}
   gatk --java-options "-Xms!{validate_retry_mem}g -Xmx!{validate_retry_mem}g" ValidateVariants -V !{params.run_name}_wArchaics_dbSNP!{params.dbsnp_build}_chr!{chrom}.vcf.gz -R !{ref} -L !{chrom} --validation-type-to-exclude IDS --dbsnp !{known_dbsnp} 2> !{params.run_name}_final_chr!{chrom}_GATK_ValidateVariants.stderr > !{params.run_name}_final_chr!{chrom}_GATK_ValidateVariants.stdout
   '''
}
