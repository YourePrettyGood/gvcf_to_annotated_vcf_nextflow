#!/bin/awk -f
#This script generates a BED of full scaffold intervals that are
# compatible between the NCBI, UCSC, and 1kGP versions of the reference.
#The expected input files are:
# 1) The map TSV output by NCBI_to_1kGP_map.awk
# 2) hs37d5.fa.fai, the FASTA index for the 1kGP reference
#In principle, as long as the files retain equivalent formats, this script
# can be applied to other conversions, like going from GRCh38 to GRCh38DH
BEGIN{
   OFS="\t";
   filenum=0;
}
FNR==1{
   filenum++;
}
filenum==1{
   keepscafs[$2]=$1;
}
filenum==2{
   if ($1 in keepscafs) {
      print $1, "0", $2;
   };
}
