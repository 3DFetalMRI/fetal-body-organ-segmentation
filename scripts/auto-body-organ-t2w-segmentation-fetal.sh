#!/usr/bin/env bash -l

#
# 3D Fetal MRI repositories: automated processing solutions
#
# Copyright 2018- King's College London
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo

source /root/.bashrc

eval "$(conda shell.bash hook)"

conda init bash

#conda init bash
conda activate Segmentation_FetalMRI_MONAI

#UPDATE AS REQUIRED BEFORE RUNNING !!!!
software_path=/home
default_run_dir=/home/tmp_proc


mirtk_path=${software_path}/MIRTK/build/bin
dcm2niix_path=${software_path}/dcm2niix/build/bin
segm_path=${software_path}/auto-proc-svrtk
template_path=${segm_path}/templates



test_dir=${software_path}/MIRTK
if [[ ! -d ${test_dir} ]];then
    echo "ERROR: COULD NOT FIND MIRTK INSTALLED IN : " ${software_path}
    echo "PLEASE INSTALL OR UPDATE THE PATH software_path VARIABLE IN THE SCRIPT"
    exit
fi

test_dir=${segm_path}/trained_models
if [[ ! -d ${test_dir} ]];then
    echo "ERROR: COULD NOT FIND SEGMENTATION MODULE INSTALLED IN : " ${software_path}
    echo "PLEASE INSTALL OR UPDATE THE PATH software_path VARIABLE IN THE SCRIPT"
    exit
fi


monai_check_path_global_body_unet=${segm_path}/trained_models/monai-checkpoints-unet-body_global-1-lab
monai_check_path_organ_body_unet=${segm_path}/trained_models/monai-checkpoints-unet-body-organs-10-lab


test_dir=${default_run_dir}
if [[ ! -d ${test_dir} ]];then
    mkdir ${default_run_dir}
else
    rm -r ${default_run_dir}/*
fi

test_dir=${default_run_dir}
if [[ ! -d ${test_dir} ]];then
    echo "ERROR: COULD NOT CREATE THE PROCESSING FOLDER : " ${default_run_dir}
    echo "PLEASE CHECK THE PERMISSIONS OR UPDATE THE PATH default_run_dir VARIABLE IN THE SCRIPT"
    exit
fi



echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo
echo "Body organ segmentation for 3D T2w MRI DSVR fetal body recons (KCL)"
echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo

if [[ $# -ne 2 ]] ; then
    echo "Usage: bash /home/segmentation/auto-body-organs-segmentation-fetal.sh"
    echo "            [full path to the folder with 3D T2w SVR recons]"
    echo "            [full path to the folder for segmentation results]"
    echo
    echo "note: tmp processing files are stored in /home/tmp_proc"
    echo
    exit
else
    input_main_folder=$1
    output_main_folder=$2
fi


echo " - input folder : " ${input_main_folder}
echo " - output folder : " ${output_main_folder}


test_dir=${input_main_folder}
if [[ ! -d ${test_dir} ]];then
    echo
	echo "ERROR: NO FOLDER WITH THE INPUT FILES FOUND !!!!" 
	exit
fi


test_dir=${output_main_folder}
if [[ ! -d ${test_dir} ]];then
	mkdir ${output_main_folder}
fi 



cd ${default_run_dir}
main_dir=$(pwd)


number_of_stacks=$(find ${input_main_folder}/ -name "*.dcm" | wc -l)
if [ $number_of_stacks -gt 0 ];then
    echo
    echo "-----------------------------------------------------------------------------"
    echo "FOUND .dcm FILES - CONVERTING TO .nii.gz !!!!"
    echo "-----------------------------------------------------------------------------"
    echo
    cd ${input_main_folder}/
    ${dcm2niix_path}/dcm2niix -z y .
    cd ${main_dir}/
fi



number_of_stacks=$(find ${input_main_folder}/ -name "*.nii*" | wc -l)
if [[ ${number_of_stacks} -eq 0 ]];then
    echo
    echo "-----------------------------------------------------------------------------"
	echo "ERROR: NO INPUT .nii / .nii.gz FILES FOUND !!!!"
    echo "-----------------------------------------------------------------------------"
    echo
	exit
fi 

mkdir ${default_run_dir}/org-files
find ${input_main_folder}/ -name "*.nii*" -exec cp {} ${default_run_dir}/org-files  \; 

echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo
echo "PREPROCESSING ..."
echo

cd ${default_run_dir}


mkdir org-files-preproc
cp org-files/* org-files-preproc

cd org-files-preproc

stack_names=$(ls *.nii*)
IFS=$'\n' read -rd '' -a all_stacks <<<"$stack_names"

echo
echo "-----------------------------------------------------------------------------"
echo "CROPPING & REMOVING NAN & NEGATIVE/EXTREME VALUES & "
echo "TRANSFORMING TO THE STANDARD SPACE & REMOVING DYNAMICS..."
echo "-----------------------------------------------------------------------------"
echo

for ((i=0;i<${#all_stacks[@]};i++));
do
    echo " - " ${i} " : " ${all_stacks[$i]}
#    ${mirtk_path}/mirtk nan ${all_stacks[$i]} 100000
    ${mirtk_path}/mirtk extract-image-region ${all_stacks[$i]} ${all_stacks[$i]} -Rt1 0 -Rt2 0
    ${mirtk_path}/mirtk threshold-image ${all_stacks[$i]} ../th.nii.gz 0.005 > ../tmp.txt
    ${mirtk_path}/mirtk crop-image ${all_stacks[$i]} ../th.nii.gz ${all_stacks[$i]}
    
    ${mirtk_path}/mirtk edit-image ${template_path}/body-ref-space.nii.gz ../ref.nii.gz -copy-origin ${all_stacks[$i]}
    ${mirtk_path}/mirtk transform-image ${all_stacks[$i]} ${all_stacks[$i]} -target ../ref.nii.gz -interp Linear
    ${mirtk_path}/mirtk crop-image ${all_stacks[$i]} ../th.nii.gz ${all_stacks[$i]}
    ${mirtk_path}/mirtk nan ${all_stacks[$i]} 1000000
    
    
done

stack_names=$(ls *.nii*)
IFS=$'\n' read -rd '' -a all_stacks <<<"$stack_names"


echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo
echo "3D ORGAN SEGMENTATION OF 3D DSVR T2W BODY RECONS..."
echo

cd ${main_dir}

echo
echo "-----------------------------------------------------------------------------"
echo "GLOBAL BODY ..."
echo "-----------------------------------------------------------------------------"
echo

number_of_stacks=$(ls org-files-preproc/*.nii* | wc -l)
stack_names=$(ls org-files-preproc/*.nii*)

echo " ... "

res=128
monai_lab_num=1
number_of_stacks=$(find org-files-preproc/ -name "*.nii*" | wc -l)
${mirtk_path}/mirtk prepare-for-monai res-stack-files/ stack-files/ stack-info.json stack-info.csv ${res} ${number_of_stacks} org-files-preproc/*nii* > tmp.log

mkdir monai-segmentation-results-body_global
python ${segm_path}/run_monai_unet_segmentation-2022.py ${main_dir}/ ${monai_check_path_global_body_unet}/ stack-info.json ${main_dir}/monai-segmentation-results-body_global ${res} ${monai_lab_num}


number_of_stacks=$(find monai-segmentation-results-body_global/ -name "*.nii*" | wc -l)
if [[ ${number_of_stacks} -eq 0 ]];then
    echo
    echo "-----------------------------------------------------------------------------"
    echo "ERROR: GLOBAL BODY LOCALISATION DID NOT WORK !!!!"
    echo "-----------------------------------------------------------------------------"
    echo
    exit
fi


echo
echo "-----------------------------------------------------------------------------"
echo "EXTRACTING LABELS AND MASKING..."
echo "-----------------------------------------------------------------------------"
echo

out_mask_names=$(ls monai-segmentation-results-body_global/cnn-*.nii*)
IFS=$'\n' read -rd '' -a all_masks <<<"$out_mask_names"

stack_names=$(ls org-files-preproc/*.nii*)
IFS=$'\n' read -rd '' -a all_stacks <<<"$stack_names"


mkdir masked-stacks
mkdir body_global-masks

for ((i=0;i<${#all_stacks[@]};i++));
do
    echo " - " ${i} " : " ${all_stacks[$i]} ${all_masks[$i]}
    
    jj=$((${i}+1000))
    
    ${mirtk_path}/mirtk extract-label ${all_masks[$i]} body_global-masks/mask-${jj}.nii.gz 1 1
    ${mirtk_path}/mirtk extract-connected-components body_global-masks/mask-${jj}.nii.gz body_global-masks/mask-${jj}.nii.gz
    ${mirtk_path}/mirtk transform-image body_global-masks/mask-${jj}.nii.gz body_global-masks/mask-${jj}.nii.gz -target ${all_stacks[$i]} -labels
    ${mirtk_path}/mirtk dilate-image body_global-masks/mask-${jj}.nii.gz dl.nii.gz -iterations 4
    ${mirtk_path}/mirtk erode-image dl.nii.gz dl.nii.gz -iterations 2
    ${mirtk_path}/mirtk mask-image ${all_stacks[$i]} dl.nii.gz masked-stacks/masked-stack-${jj}.nii.gz
    ${software_path}/N4BiasFieldCorrection -i masked-stacks/masked-stack-${jj}.nii.gz -x dl.nii.gz -o tmp.nii.gz  -c "[50x50x50,0.001]" -s 2 -b "[100,3]" -t "[0.15,0.01,200]" > t.txt 
    cp tmp.nii.gz  masked-stacks/masked-stack-${jj}.nii.gz
    ${mirtk_path}/mirtk crop-image masked-stacks/masked-stack-${jj}.nii.gz dl.nii.gz masked-stacks/masked-stack-${jj}.nii.gz

	

	# cp tmp.nii.gz masked-input-files/masked-stack-${jj}.nii.gz

done


echo
echo "-----------------------------------------------------------------------------"
echo "BODY ORGAN SEGMENTATION ..."
echo "-----------------------------------------------------------------------------"
echo

number_of_stacks=$(ls masked-stacks/*.nii* | wc -l)
stack_names=$(ls masked-stacks/*.nii*)

echo " ... "

res=128
monai_lab_num=10
number_of_stacks=$(find masked-stacks/ -name "*.nii*" | wc -l)
${mirtk_path}/mirtk prepare-for-monai res-masked-stack-files/ masked-stack-files/ masked-stack-info.json masked-stack-info.csv ${res} ${number_of_stacks} masked-stacks/*nii* > tmp.log

mkdir monai-segmentation-results-organs

python ${segm_path}/run_monai_unet_segmentation-2022.py ${main_dir}/ ${monai_check_path_organ_body_unet}/ masked-stack-info.json ${main_dir}/monai-segmentation-results-organs ${res} ${monai_lab_num}



number_of_stacks=$(find monai-segmentation-results-organs/ -name "*.nii*" | wc -l)
if [[ ${number_of_stacks} -eq 0 ]];then
    echo
    echo "-----------------------------------------------------------------------------"
    echo "ERROR: BODY ORGAN SEGMENTATION DID NOT WORK !!!!"
    echo "-----------------------------------------------------------------------------"
    echo
    exit
fi


echo
echo "-----------------------------------------------------------------------------"
echo "EXTRACTING LABELS AND TRANSFORMING TO THE ORIGINAL SPACE ..."
echo "-----------------------------------------------------------------------------"
echo

out_mask_names=$(ls monai-segmentation-results-organs/cnn-*.nii*)
IFS=$'\n' read -rd '' -a all_masks <<<"$out_mask_names"

stack_names=$(ls org-files/*.nii*)
IFS=$'\n' read -rd '' -a all_stacks <<<"$stack_names"


mkdir organs-masks

for ((i=0;i<${#all_stacks[@]};i++));
do
    echo " - " ${i} " : " ${all_stacks[$i]} ${all_masks[$i]}
    
    jj=$((${i}+1000))
    
    echo
    
    ${mirtk_path}/mirtk transform-image ${all_masks[$i]} ${all_masks[$i]} -target ${all_stacks[$i]} -labels
    ${mirtk_path}/mirtk transform-and-rename ${all_stacks[$i]} ${all_masks[$i]} "-mask-body_organs-"${monai_lab_num} ${main_dir}/organs-masks

    echo

done



number_of_final_files=$(ls ${main_dir}/organs-masks/*.nii* | wc -l)
if [[ ${number_of_final_files} -ne 0 ]];then

    cp -r organs-masks/*.nii* ${output_main_folder}/
    

    echo "-----------------------------------------------------------------------------"
    echo "Segmentation results are in the output folder : " ${output_main_folder}
    echo "-----------------------------------------------------------------------------"
        
else
    echo
    echo "-----------------------------------------------------------------------------"
    echo "ERROR: COULD NOT COPY THE FILES TO THE OUTPUT FOLDER : " ${output_main_folder}
    echo "PLEASE CHECK THE WRITE PERMISSIONS / LOCATION !!!"
    echo
    echo "-----------------------------------------------------------------------------"
    echo

fi


echo
echo "-----------------------------------------------------------------------------"
echo "-----------------------------------------------------------------------------"
echo



    





