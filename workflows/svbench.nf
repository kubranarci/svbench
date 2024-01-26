/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap; fromSamplesheet } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary log to screen
log.info logo + paramsSummaryLog(workflow) + citation

WorkflowBenchmark.initialise(params, log)

// check mandatory parameters
ref         = Channel.fromPath([params.fasta,params.fai], checkIfExists: true).collect()

// check high confidence files
rename_chr  = params.rename_chromosomes ? Channel.fromPath(params.rename_chromosomes, checkIfExists: true).collect()
                                        : Channel.empty()

truth       = params.truth              ? Channel.fromPath(params.truth, checkIfExists: true).collect()
                                        : Channel.empty()

high_conf   = params.high_conf          ? Channel.fromPath(params.high_conf, checkIfExists: true).collect()
                                        : Channel.empty()

// TODO: GET FILES FROM IGENOMES ACCORDING TO META.ID



/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK              } from '../subworkflows/local/input_check'
include { SOMATIC_BENCHMARK        } from '../subworkflows/local/somatic_benchmark'
include { GERMLINE_BENCHMARK       } from '../subworkflows/local/germline_benchmark'
include { PREPARE_STRATIFICATIONS  } from '../subworkflows/local/prepare_stratifications'
include { PREPARE_VCFS_TRUTH       } from '../subworkflows/local/prepare_vcfs_truth'
include { PREPARE_VCFS_TEST        } from '../subworkflows/local/prepare_vcfs_test'
include { REPORT_STATISTICS as REPORT_STATISTICS_TEST } from '../subworkflows/local/report_statistics'
include { REPORT_STATISTICS as REPORT_STATISTICS_TRUTH } from '../subworkflows/local/report_statistics'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow SVBENCH {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        file(params.input)
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)
    ch_input = INPUT_CHECK.out.ch_sample
    
    //
    // PREPARE_STRATIFICATIONS: prepare stratifications and contigs
    //
    PREPARE_STRATIFICATIONS(
        ref
    )
    ch_versions = ch_versions.mix(PREPARE_STRATIFICATIONS.out.versions)

    //
    // SUBWORKFLOW: Prepare and normalize input vcfs
    //
    PREPARE_VCFS_TRUTH(
        truth,
        ref,
        [[],[]]
    )
    ch_versions = ch_versions.mix(PREPARE_VCFS_TRUTH.out.versions)

    PREPARE_VCFS_TEST(
        ch_input,
        ref,
        rename_chr,
        [[],[]]
    )
    ch_versions = ch_versions.mix(PREPARE_VCFS_TEST.out.versions)  

    //
    // SUBWORKFLOW: GET STATISTICS OF FILES
    //   
    //REPORT_STATISTICS_TRUTH(
    //

    REPORT_STATISTICS_TEST(
        PREPARE_VCFS_TEST.out.vcf_ch
    )
    ch_versions = ch_versions.mix(REPORT_STATISTICS_TEST.out.versions)

    // preare  benchmark set

    PREPARE_VCFS_TEST.out.vcf_ch.combine(PREPARE_VCFS_TRUTH.out.vcf_ch, by:0)
                                .set{bench_ch}

    bench_ch.view()
    if (params.analysis.contains("germline")){
    // GERMLINE VARIANT BENCHMARKING
        GERMLINE_BENCHMARK(
            bench_ch,
            high_conf,
            ref
        )
        ch_versions = ch_versions.mix(GERMLINE_BENCHMARK.out.versions)
    }

    if (params.analysis.contains("somatic")){
        // SOMATIC VARIANT BENCHMARKING
        SOMATIC_BENCHMARK(
            bench_ch,
            ref
        )
        ch_versions = ch_versions.mix(SOMATIC_BENCHMARK.out.versions)
    }

    // TODO: NEED A TOOL TO COLLECT METRICS AND ROCS LIKE DATAVZRD OR SQLITE DATABASE

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowBenchmark.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowBenchmark.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    //ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
