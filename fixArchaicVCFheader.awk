#!/bin/awk -f
#This script fixes the GQ header of archaic VCFs from EVA MPG and
# adds contig headers in the order of the .fai file provided.
#First input file is the .fai index of the reference genome
#Second input file is the VCF header (e.g. output of `bcftools view -h`)
BEGIN{
   OFS="\t";
   filenum=0;
}
FNR==1{
   filenum++;
}
filenum==1{
   ctglines[++numscafs]="##contig=<ID="$1",length="$2;
   if (length(asm) > 0) {
      ctglines[numscafs]=ctglines[numscafs]",assembly="asm;
   };
   if (length(species) > 0) {
      ctglines[numscafs]=ctglines[numscafs]",species="species;
   };
   ctglines[numscafs]=ctglines[numscafs]">";
}
filenum==2&&/^##FORMAT=<ID=GQ/{
   sub("Float", "Integer", $0);
}
filenum==2&&/^#CHROM/{
   PROCINFO["sorted_in"]="@ind_num_asc";
   for (i in ctglines) {
      print ctglines[i];
   };
}
filenum==2&&/^#/&&!/^##contig/{
   print $0;
}
