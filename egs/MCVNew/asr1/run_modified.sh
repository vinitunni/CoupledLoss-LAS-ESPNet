#!/bin/bash

# Copyright 2017 Johns Hopkins University (Shinji Watanabe)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh
echo RAN_PATH
. ./cmd.sh
echo RAN_CMD



resume=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/snapshot.ep.26
#resume=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.25_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta/results/snapshot_backup_34
#resume=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_us_orig_pytorch_vggblstmp_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta/results/snapshot_backup_20
#resume=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.5_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta/results/snapshot_backup_43
#resume=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/old_expts_before_12th_Aug/train_mixed_new_0.25_pytorch_vggblstm_e3_subsample2_2_2_unit1024_proj1024_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.0_bs12_mli600_mlo150_beamsize_10_delta/results/snapshot_backup_40
# general configuration
backend=pytorch
stage=4     # start from -1 if you need to start from data download
stop_stage=2
ngpu=1         # number of gpus ("0" uses cpu, otherwise use gpu2
debugmode=1
dumpdir=dump   # directory to dump full features
N=0            # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=1      # verbose option

# feature configuration
do_delta=true

# network architecture
# encoder related
etype=vggblstm    # encoder architecture type
#etype=blstmp
elayers=3
eunits=512
eprojs=512
subsample=2_2_2 # skip every n frame from input to nth layers
# decoder related
dlayers=1
dunits=512
# attention related
atype=location
adim=1024
aconv_chans=10
aconv_filts=100

# hybrid CTC/attention
mtlalpha=0.0

# minibatch related
batchsize=16
maxlen_in=600  # if input length  > maxlen_in, batchsize is automatically reduced
maxlen_out=150 # if output length > maxlen_out, batchsize is automatically reduced

# other config
drop=0.5 #dropout changed to 0.2 by vinit

# optimization related
sortagrad=0 # Feed samples from shortest to longest ; -1: enabled for all epochs, 0: disabled, other: enabled for 'other' epochs
opt=adadelta
epochs=400
patience=10

# rnnlm related
lm_layers=1
lm_units=1024
lm_opt=sgd        # or adam
lm_sortagrad=0 # Feed samples from shortest to longest ; -1: enabled for all epochs, 0: disabled, other: enabled for 'other' epochs
lm_batchsize=1024 # batch size in LM training
lm_epochs=20      # if the data size is large, we can reduce this
lm_patience=3
lm_maxlen=40      # if sentence length > lm_maxlen, lm_batchsize is automatically reduced

lm_resume=
#lm_resume=exp/train_rnnlm_pytorch_1layer_unit1024_sgd_bs1024_unigram5000/snapshot.ep.11         #specify a snapshot file to resume LM training
lmtag=            # tag for managing LMs

# decoding parameter
lm_weight=0 #0.7
beam_size=10
penalty=0.1
maxlenratio=0.8
minlenratio=0.2
ctc_weight=0
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'

# scheduled sampling option
samp_prob=0.3
#sampling_probability=0

# Set this to somewhere where you want to put your data, or where
# someone else has already put it.  You'll want to change this
# if you're not on the CLSP grid.
datadir=/home/vinit/exp/Datasets/MCVNew_v3/clips/

# base url for downloads.
data_url=www.openslr.org/resources/12

# bpemode (unigram or bpe)
nbpe=1000
bpemode=unigram

# exp tag
tag=
#tag=mixed_0.25_sampprob0.0_from_scratch_blstm_only
#tag=us_from_0.3_to_0.8_to_1
#tag="shorten-folder-name-expt" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

. ./path.sh
. ./cmd.sh

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail
export CUDA_VISIBLE_DEVICES=1
echo CUDA_VISIBLE_DEVICES $CUDA_VISIBLE_DEVICES

pairwise=True
pair_threshold=0.7
pair_cutoff=10
pair_lambda=0.0005
pair_alpha=1.0



# it is best to create a different dev set for each train set as bpe encoding is error free this way
#train_set=train_us_orig
#train_dev=test_us_orig

train_set=train_paired_0.25
train_dev=test_non_us_mp3

#train_set=train_mixed_new_0.5
#train_dev=test_us_mixed_0.5

recog_set="test_non_us_mp3"
###### Ignore stage -1 as we are not downloading the data
######
if [ ${stage} -le -1 ] && [ ${stop_stage} -ge -1 ]; then
    echo "stage -1: Data Download"
    for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360 train-other-500; do
        local/download_and_untar.sh ${datadir} ${data_url} ${part}
    done
fi
####### Ignore stage 0 as we are manually creatiung the kaldi files
#######
if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 0: Data preparation"
    for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360 train-other-500; do
        # use underscore-separated names in data directories.
        local/data_prep.sh ${datadir}/LibriSpeech/${part} data/${part//-/_}
    done
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}

if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    #for x in test_non_us_mp3 test_us_mp3 train_us_mp3 train_non_us_mp3; do
    #for x in train_mixed_0.1 train_mixed_0.25 train_mixed_0.5; do
#    for x in train_non_us_0.1 train_non_us_0.25 train_non_us_0.5; do
#        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
#            data/${x} exp/make_fbank/${x} ${fbankdir}
#        utils/fix_data_dir.sh data/${x}
#    done
# Check if it is better to just use combine data
    #utils/combine_data.sh --extra_files utt2num_frames data/${train_set}_org data/train_us_mp3 data/train_non_us_0.5
    utils/combine_data.sh --extra_files utt2num_frames data/${train_set}_org data/train_non_us_0.5
    utils/combine_data.sh --extra_files utt2num_frames data/${train_dev}_org data/test_us_mp3
    #utils/combine_data.sh --extra_files utt2num_frames data/${train_set}_org data/train_us_mp3




    # remove utt having more than 3000 frames
    # remove utt having more than 400 characters
    remove_longshortdata.sh --maxframes 3000 --maxchars 400 data/${train_set}_org data/${train_set}
    remove_longshortdata.sh --maxframes 3000 --maxchars 400 data/${train_dev}_org data/${train_dev}


    # compute global CMVN
	#TODO do I need to add --spk2utt
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark	
    #compute-cmvn-stats --spk2utt=ark:data/${train_set}/spk2utt scp:data/${train_set}/feats.scp /home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/data/${train_set}/cmvn.ark	

    # dump features for training
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
    utils/create_split_dir.pl \
        /export/b{14,15,16,17}/${USER}/espnet-data/egs/MCVNew/asr1/dump/${train_set}/delta${do_delta}/storage \
        ${feat_tr_dir}/storage
    fi
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
    utils/create_split_dir.pl \
        /export/b{14,15,16,17}/${USER}/espnet-data/egs/MCVNew/asr1/dump/${train_dev}/delta${do_delta}/storage \
        ${feat_dt_dir}/storage
    fi
    dump.sh --cmd "$train_cmd" --nj 40 --do_delta ${do_delta} \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
        data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/dev ${feat_dt_dir}
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
            data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
            ${feat_recog_dir}
    done
fi


####copied from above by vinit to enable feature generation a single time
#compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark
## dump features for training
#if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
#utils/create_split_dir.pl \
#	/export/b{14,15,16,17}/${USER}/espnet-data/egs/MCVNew/asr1/dump/${train_set}/delta${do_delta}/storage \
#	${feat_tr_dir}/storage
#fi
#if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
#utils/create_split_dir.pl \
#	/export/b{14,15,16,17}/${USER}/espnet-data/egs/MCVNew/asr1/dump/${train_dev}/delta${do_delta}/storage \
#	${feat_dt_dir}/storage
#fi
#dump.sh --cmd "$train_cmd" --nj 80 --do_delta ${do_delta} \
#	data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/train ${feat_tr_dir}
#dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
#	data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/dev ${feat_dt_dir}
#for rtask in ${recog_set}; do
#	feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
#	dump.sh --cmd "$train_cmd" --nj 32 --do_delta ${do_delta} \
#		data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
#		${feat_recog_dir}
#done
####

dict=data/lang_char/${train_set}_${bpemode}${nbpe}_units.txt
bpemodel=data/lang_char/${train_set}_${bpemode}${nbpe}

dict=data/lang_char/train_us_orig_unigram1000_units.txt
bpemodel=data/lang_char/train_us_orig_unigram1000

echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then

#	if [${pairwise} ]
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_char/
	echo "New dir made"
    #echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    cut -f 2- -d" " data/${train_set}/text > data/lang_char/input.txt
    #spm_train --input=data/lang_char/input.txt --vocab_size=${nbpe} --model_type=${bpemode} --model_prefix=${bpemodel} --input_sentence_size=100000000
    #spm_encode --model=${bpemodel}.model --output_format=piece < data/lang_char/input.txt | tr ' ' '\n' | sort | uniq | awk '{print $0 " " NR+1}' >> ${dict}
    wc -l ${dict}

    # make json labels
    data2json.sh --feat ${feat_tr_dir}/feats.scp --bpecode ${bpemodel}.model \
        data/${train_set} ${dict} > ${feat_tr_dir}/data_${bpemode}${nbpe}.json
    data2json.sh --feat ${feat_dt_dir}/feats.scp --bpecode ${bpemodel}.model \
        data/${train_dev} ${dict} > ${feat_dt_dir}/data_${bpemode}${nbpe}.json

    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        data2json.sh --feat ${feat_recog_dir}/feats.scp --bpecode ${bpemodel}.model \
            data/${rtask} ${dict} > ${feat_recog_dir}/data_${bpemode}${nbpe}.json
    done
fi

# You can skip this and remove --rnnlm option in the recognition (stage 5)
if [ -z ${lmtag} ]; then
    lmtag=${lm_layers}layer_unit${lm_units}_${lm_opt}_bs${lm_batchsize}
fi
lmexpname=train_rnnlm_${backend}_${lmtag}_${bpemode}${nbpe}
lmexpdir=exp/${lmexpname}
mkdir -p ${lmexpdir}

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: LM Preparation"
    lmdatadir=data/local/lm_train_${bpemode}${nbpe}
    mkdir -p ${lmdatadir}
    # use external data
    echo "downloading file"
    if [ ! -e data/local/lm_train/librispeech-lm-norm.txt.gz ]; then
        wget http://www.openslr.org/resources/11/librispeech-lm-norm.txt.gz -P data/local/lm_train/
    fi
    echo "download done"
    cut -f 2- -d" " data/${train_set}/text | gzip -c > data/local/lm_train/${train_set}_text.gz
    # combine external text and transcriptions and shuffle them with seed 777
    #which spm_encode
    zcat data/local/lm_train/librispeech-lm-norm.txt.gz data/local/lm_train/${train_set}_text.gz |\
        spm_encode --model=${bpemodel}.model --output_format=piece > ${lmdatadir}/train.txt
    cut -f 2- -d" " data/${train_dev}/text | spm_encode --model=${bpemodel}.model --output_format=piece \
        > ${lmdatadir}/valid.txt
    # use only 1 gpu
    if [ ${ngpu} -gt 1 ]; then
        echo "LM training does not support multi-gpu. signle gpu will be used."
    fi
    ${cuda_cmd} --gpu ${ngpu} ${lmexpdir}/train.log \
        lm_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --verbose 1 \
        --outdir ${lmexpdir} \
        --tensorboard-dir tensorboard/${lmexpname} \
        --train-label ${lmdatadir}/train.txt \
        --valid-label ${lmdatadir}/valid.txt \
        --resume ${lm_resume} \
        --layer ${lm_layers} \
        --unit ${lm_units} \
        --opt ${lm_opt} \
        --sortagrad ${lm_sortagrad} \
        --batchsize ${lm_batchsize} \
        --epoch ${lm_epochs} \
        --patience ${lm_patience} \
        --maxlen ${lm_maxlen} \
        --dict ${dict}
fi

if [ -z ${tag} ]; then
    expname=${train_set}_${backend}_${etype}_e${elayers}_subsample${subsample}_unit${eunits}_proj${eprojs}_d${dlayers}_unit${dunits}_${atype}_aconvc${aconv_chans}_aconvf${aconv_filts}_mtlalpha${mtlalpha}_drop${drop}_${opt}_sampprob${samp_prob}_bs${batchsize}_mli${maxlen_in}_mlo${maxlen_out}_beamsize_${beam_size}_pairwise${pairwise}_pairthrshld${pair_threshold}_paircutoff${pair_cutoff}_pairlmbda${pair_lambda}_pairalpha${pair_alpha}
    if ${do_delta}; then
        expname=${expname}_delta
    fi
else
    expname=${train_set}_${backend}_${tag}
fi
expdir=exp/${expname}
stop_stage=10
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
	mkdir -p ${expdir}
    echo "stage 4: Network Training"
    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --tensorboard-dir tensorboard_mixed/${expname} \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --verbose ${verbose} \
        --resume ${resume} \
        --train-json ${feat_tr_dir}/data_${bpemode}${nbpe}.json \
        --valid-json ${feat_dt_dir}/data_${bpemode}${nbpe}.json \
        --etype ${etype} \
        --elayers ${elayers} \
        --eunits ${eunits} \
        --eprojs ${eprojs} \
        --subsample ${subsample} \
        --dlayers ${dlayers} \
        --dunits ${dunits} \
        --atype ${atype} \
        --adim ${adim} \
        --aconv-chans ${aconv_chans} \
        --aconv-filts ${aconv_filts} \
        --mtlalpha ${mtlalpha} \
        --batch-size ${batchsize} \
        --maxlen-in ${maxlen_in} \
        --maxlen-out ${maxlen_out} \
        --sampling-probability ${samp_prob} \
        --dropout-rate ${drop} \
        --opt ${opt} \
        --sortagrad ${sortagrad} \
        --epochs ${epochs} \
        --patience ${patience}	\
		--ctc-weight ${ctc_weight}	\
	--report-cer	\
	--report-wer	\
	--pairwise ${pairwise}	\
	--pair-threshold ${pair_threshold} \
	--pair-cutoff ${pair_cutoff}	\
	--pair-lambda ${pair_lambda}	\
	--pair-alpha ${pair_alpha}
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Decoding"
    nj=32

    pids=() # initialize pids
    for rtask in ${recog_set}; do
    (
        #expdir=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.5_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta
	#	expdir=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.1_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta
		#expdir=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.25_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta
		#expdir=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_us_orig_pytorch_vggblstmp_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta
		#expdir=/home/vinit/exp/espnet-0.4.0/egs/MCVNew/asr1/exp/train_mixed_new_0.25_pytorch_vggblstm_e3_subsample2_2_2_unit512_proj512_d1_unit512_location_aconvc10_aconvf100_mtlalpha0.0_drop0.5_adadelta_sampprob0.3_bs12_mli600_mlo150_beamsize_10_delta
		decode_dir=decode_${rtask}_beam${beam_size}_e${recog_model}_p${penalty}_len${minlenratio}-${maxlenratio}_ctcw${ctc_weight}_rnnlm${lm_weight}_${lmtag}
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

        # split data
        splitjson.py --parts ${nj} ${feat_recog_dir}/data_${bpemode}${nbpe}.json

        #### use CPU for decoding
        ngpu=0

        # set batchsize 0 to disable batch decoding
        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --batchsize 0 \
            --recog-json ${feat_recog_dir}/split${nj}utt/data_${bpemode}${nbpe}.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${recog_model}  \
            --beam-size ${beam_size} \
            --penalty ${penalty} \
            --maxlenratio ${maxlenratio} \
            --minlenratio ${minlenratio} \
            --ctc-weight ${ctc_weight} \
            --lm-weight ${lm_weight}

        score_sclite.sh --bpe ${nbpe} --bpemodel ${bpemodel}.model --wer true ${expdir}/${decode_dir} ${dict}

    ) &
    pids+=($!) # store background pids
#            --rnnlm ${lmexpdir}/rnnlm.model.best \
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((++i)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished"
fi
