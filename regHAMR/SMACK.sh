#!/bin/bash
set -u

# Suite for Modification or Annotation-purposed Cleaning and Keeping

if [ "$#" -lt 13 ]; then
echo "Missing arguments!"
echo "USAGE: SMACK.sh <SRA Accession list.txt> <trim requirement T/F> <repo dir> <genome.fasta> 
        <annotation.gff3> <sam filter.pl> <hamr model.Rdata> <read length> <name table.csv>
        <ant lib> <out dir> <#cores> <genome length>" 
echo "EXAMPLE:"
exit 1
fi

# A list of SRR accession numbers generated from SRA run selector tool, 
# usually represent the sequencing data of an entire experiment, .txt file.
acc=$1

# Whether the data downloaded are trimmed or untrimmed fastq files. 
# If you want SMACK to trim it, put F 
trim=$2

# A directory containing all extra packages needed (gatk, hamr)
repo=$3

# The genome file of your model organism, .fasta file
gno=$4

# The annotation file of your model organism (usually found along with genome), .gff3 file
ant=$5

# The provided filtering file, .pl file
filter=$6

# The provided trained model for HAMR, .Rdata file
model=$7

# The length of your reads (usually ranging from 50~200)
len=$8

# Calculating the mismatch allowance from len
mis=$(($len*6/100))

# Overhang argument used by star
ohang=$((mis-1))

# A table corresponding each SRR file to the actual condition of each sequencing data, for the ease of downstream, .csv file
names=$9

# A folder with annotation libraries of your model organism as generated by running Diep's script
antlib=${10}

# Your desired output directory
out=${11}

# Number of threads on your CPU that this program can use
cores=${12}

# The size of genome of your model organism
gnolen=${13}

# Records the current directory (of this script)
curdir=$(dirname $0)

if [ ! -d "$out" ]; then mkdir $out; echo "created path: $out"; fi

if [ ! -d "$out/datasets" ]; then mkdir $out/datasets; echo "created path: $out/datasets"; fi

# Create directory to store original fastq files
if [ ! -d "$out/datasets/raw" ]; then mkdir $out/datasets/raw; fi
echo "You can find your original fastq files at $out/datasets/raw" 

# Create directory to store trimmed fastq files if pretrim is not specified
if [ ! "$trim" = 'T' ]; then
    if [ ! -d "$out/datasets/trimmed" ]; then mkdir $out/datasets/trimmed; fi
    echo "You can find your trimmed fastq files at $out/datasets/trimmed" 
fi

# Create directory to store fastqc results
if [ ! -d "$out/datasets/fastqc_results" ]; then mkdir $out/datasets/fastqc_results; fi
echo "You can find all the fastqc test results at $out/datasets/fastqc_results"

# Run a series of command checks to ensure fasterq-dumpAdapter can run smoothly
if ! command -v fasterq-dump > /dev/null; then
    echo "Failed to call fasterq-dump command. Please check your installation."
    exit 1
fi

if ! command -v fastqc > /dev/null; then
    echo "Failed to call fastqc command. Please check your installation."
    exit 1
fi

if ! command -v trim_galore > /dev/null; then
    echo "Failed to call trim_galore command. Please check your installation."
    exit 1
fi

# Grabs the fastq files from acc list provided into the dir ~/datasets
dumpout=$out/datasets
i=0
while IFS= read -r line
do ((i=i%$cores)); ((i++==0)) && wait
    $curdir/fasterq-dumpAdapter.sh \
        $line \
        $dumpout \
        $trim &
done < "$acc"

wait

echo ""
echo ""
echo "################ Finished downloading and processing all fastq files. Entering pipeline for HAMR analysis. ######################"

# Checks if the files were trimmed or cleaned, and if so, take those files for downstream
hamrin=""
suf=""
# If trimmed folder present, then user specified trimming, we take trimmed files with .fq
if [ -d "$dumpout/trimmed" ] 
then 
    hamrin=$dumpout/trimmed
    suf="fq"
else
    suf="fastq"
    # If cleaned folder present, then user specified cleaning, we take cleaned files.
    if [ -d "$dmpout/cleaned" ] 
    then 
        hamrin=$dumpout/cleaned
    else
        hamrin=$dumpout
    fi
fi

# In the case where no above folders can be found
if [ ! -n "$hamrin" ]; then
    echo "failed to locate downloaded fastq files"
    exit 1
fi

# Creating some folders
if [ ! -d "$out/pipeline" ]; then mkdir "$out/pipeline"; echo "created path: $out/pipeline"; fi

if [ ! -d "$out/hamr_out" ]; then mkdir $out/hamr_out; echo "created path: $out/hamr_out"; fi

# Check if zero_mod is present already, if not then create one
if [ ! -e "$out/hamr_out/zero_mod.txt" ] 
then 
    cd $out/hamr_out
    echo "Below samples have 0 HAMR predicted mods:" > zero_mod.txt
    cd
fi

# Check if indexed files already present for STAR
if [ -e "$out/ref/SAindex" ] 
    then
    echo "STAR Genome Directory with indexed genome detected, proceding to alignment..."
else
# If not, first check if ref folder is present, if not then make
    if [ ! -d "$out/ref" ]; then mkdir "$out/ref"; echo "created path: $out/ref"; fi
    # Now, do the indexing step
    # Define the SA index number argument
    log_result=$(echo "scale=2; l($gnolen)/l(2)/2 - 1" | bc -l)
    sain=$(echo "scale=0; if ($log_result < 14) $log_result else 14" | bc)

    # Create genome index 
    STAR \
        --runThreadN $cores \
        --runMode genomeGenerate \
        --genomeDir $out/ref \
        --genomeFastaFiles $gno \
        --sjdbGTFfile $ant \
        --sjdbOverhang $ohang \
        --genomeSAindexNbases $sain
fi

# Run a series of command checks to ensure fastq2hamr can run smoothly
if ! command -v mapfile > /dev/null; then
    echo "Failed to call mapfile command. Please check your installation."
    exit 1
fi

if ! command -v STAR > /dev/null; then
    echo "Failed to call STAR command. Please check your installation."
    exit 1
fi

if ! command -v samtools > /dev/null; then
    echo "Failed to call samtools command. Please check your installation."
    exit 1
fi

if ! command -v gatk > /dev/null; then
    echo "Failed to call gatk command. Please check your installation."
    exit 1
fi

if ! command -v python > /dev/null; then
    echo "Failed to call python command. Please check your installation."
    exit 1
fi

# Creates a folder for depth analysis
if [ ! -d "$out/pipeline/depth" ]; then mkdir $out/pipeline/depth; echo "created path: $out/pipeline/depth"; fi

# Pipes each fastq down the hamr pipeline, and stores out put in ~/hamr_out
# Note there's also a hamr_out in ~/pipeline/SRRNUMBER_temp/, but that one's for temp files
i=0
for f in $hamrin/*.$suf
do ((i=i%$cores)); ((i++==0)) && wait
    $curdir/fastq2hamr.sh \
    $f \
    $ant \
    $gno \
    $filter \
    $model \
    $out \
    $mis \
    $names \
    $cores \
    $gnolen \
    $repo &
done

wait

# Check whether any hamr.mod.text is present, if not, halt the program here
if [ -z "$(ls -A $out/hamr_out)" ]; then
   echo "No HAMR predicted mod found for any sequencing data in this project, please see log for verification"
   exit 1
fi

# If program didn't exit, at least 1 mod file, move zero mod record outside so it doesn't get read as a modtbl next
mv $out/hamr_out/zero_mod.txt $out

# Produce consensus bam files based on filename (per extracted from name.csv) and store in ~/consensus
if [ ! -d "$out/consensus" ]; then mkdir $out/consensus; echo "created path: $out/consensus"; fi

# Run a series of command checks to ensure findConsensus can run smoothly
if ! command -v Rscript > /dev/null; then
    echo "Failed to call Rscript command. Please check your installation."
    exit 1
fi

echo "################ Finished HAMR analysis. Producing consensus mod table and depth analysis. ######################"

# Find consensus accross all reps of a given sample group
Rscript $curdir/findConsensus.R \
    $out/hamr_out \
    $out/consensus

wait

# The case where no consensus file is found, prevents *.bed from being created
if [ -z "$(ls -A $out/consensus)" ]; then
   echo "No consensus mods found within any sequencing group. Please see check individual rep for analysis. "
   exit 1
fi

# Add depth columns with info from each rep alignment, mutate in place
for f in $out/consensus/*.bed
do
    t=$(basename $f)
    d=$(dirname $f)
    n=${t%.*}
    echo "starting depth analysis on $n"
    $curdir/depth_helper.sh $out $t $d $n $f &
done

wait

# Find average depth across reps for each mod, mutate in place
for f in $out/consensus/*.bed
do
    t=$(basename $f)
    n=${t%.*}
    echo "computing depth across reps for $n"
    Rscript $curdir/depth_helper_average.R $f &
done

wait

echo "################ Finished depth analysis for all HAMR predicted modifications. Generating library overlaps. ######################"

# Produce overlap bam files with the provided annotation library folders and store in ~/lap
if [ ! -d "$out/lap" ]; then mkdir $out/lap; echo "created path: $out/lap"; fi

# Run a series of command checks to ensure consensusOverlap can run smoothly
if ! command -v intersectBed > /dev/null; then
    echo "Failed to call intersectBed command. Please check your installation."
    exit 1
fi

# Overlap with provided libraries for each sample group
for f in $out/consensus/*
do $curdir/consensusOverlap.sh \
    $f \
    $antlib/*_CDS.bed \
    $antlib/*_UTR.bed \
    $antlib/*_gene.bed \
    $antlib/*_mRNA.bed \
    $out/lap 
done