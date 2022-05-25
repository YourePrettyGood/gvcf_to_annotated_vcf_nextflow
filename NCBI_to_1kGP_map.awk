#!/bin/awk -f
#This script takes different scaffold maps to do a simple scaffold name
# replacement to generate a VCF on hs37d5 from a VCF on GRCh37.
#The expected input files are:
# 1) GCF_000001405.25_GRCh37.p13_assembly_report.txt from NCBI, which has
#    the necessary columns for mapping scaffold names between GRCh37 and
#    UCSC's hg19
# 2) g1kToUcsc.txt from UCSC, which has the necessary columns for mapping
#    scaffold names between UCSC's hg19 and the 1kGP's hs37d5
#In principle, as long as the files retain equivalent formats, this script
# can be applied to other conversions, like going from GRCh38 to GRCh38DH
BEGIN{
   FS="\t";
   OFS=FS;
   filenum=0;
   num_contigs=0;
}
FNR==1{
   filenum++;
}
filenum==1&&/^# Sequence-Name/{
   gsub("# ", "", $1);
   for (i=1; i<=NF; i++) {
      cols[$i]=i;
   };
}
filenum==1&&!/^#/{
   if ($cols["UCSC-style-name"] in ucscmap) {
      print "Found multiple mappings of "$cols["UCSC-style-name"]", first to "ucscmap[$cols["UCSC-style-name"]]", then to "$cols["RefSeq-Accn"] > "/dev/stderr";
   } else {
      if (length(debug) > 0) {
         print "Added "$cols["UCSC-style-name"]"=>"$cols["RefSeq-Accn"]" to the ucscmap" > "/dev/stderr";
      };
      if ($cols["UCSC-style-name"] != "na") {
         ucscmap[$cols["UCSC-style-name"]]=$cols["RefSeq-Accn"];
      };
   };
}
filenum==2{
   if ($2 in ucscmap) {
      if (length(debug) > 0) {
         print "Added "ucscmap[$2]"=>"$1" to the tgpmap" > "/dev/stderr";
      };
#      tgpmap[ucscmap[$2]]=$1;
      print ucscmap[$2]" "$1;
   } else {
      if (length(debug) > 0) {
         print $2" not found in ucscmap, but found in the input UCSC to 1kGP file" > "/dev/stderr";
      };
   };
}
