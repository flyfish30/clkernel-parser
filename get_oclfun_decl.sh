#!/bin/sh

if [ ! $# -eq 2 ]
then
    echo "get_oclfun_decl: <oclkernels.cl> <oclcallwrapper.c>"
fi

cl_file=$1
wrapper_file=$2
oclfun_decl_file="/tmp/clfunctions.c"

echo "typedef unsigned char  uchar;"     >  $oclfun_decl_file
echo "typedef unsigned int   uint;"      >> $oclfun_decl_file
echo "typedef unsigned short half;"      >> $oclfun_decl_file
echo "typedef unsigned char* image2d_t;" >> $oclfun_decl_file

grep -Pzo "(?s)\N*__kernel.*?{" $cl_file | sed -e 's/{/;/g' >> $oclfun_decl_file
./clkernel-parser $oclfun_decl_file > $wrapper_file
