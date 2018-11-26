#!/bin/bash
# Copyright   2017   Johns Hopkins University (Author: Daniel Garcia-Romero)
#             2017   Johns Hopkins University (Author: Daniel Povey)
#        2017-2018   David Snyder
#             2018   Ewald Enzinger
# Apache 2.0.
#
#             2018   Yi Liu. Modified to support network training using TensorFlow
#
# See ../README.txt for more info on data required.
# Results (mostly equal error-rates) are inline in comments below.

# make sure to modify "cmd.sh" and "path.sh", change the KALDI_ROOT to the correct directory
. ./cmd.sh
. ./path.sh
set -e

source activate tf

data=/home/dawna/mgb3/diarization/imports/data/mfc30/data
data2=/home/dawna/mgb3/transcription/exp-yl695/Snst/xvector/cpdaic_1.0_50/data
exp=/home/dawna/mgb3/transcription/exp-yl695/Snst/xvector/cpdaic_1.0_50/exp
mfccdir=/home/dawna/mgb3/diarization/imports/data/mfc30/mfcc
vaddir=/home/dawna/mgb3/diarization/imports/data/mfc30/mfcc

stage=5

# The kaldi voxceleb egs directory
kaldi_voxceleb=/home/dawna/mgb3/transcription/exp-yl695/software/kaldi_cpu/egs/voxceleb

voxceleb1_trials=/home/dawna/mgb3/diarization/imports/data/mfc30/data/voxceleb1_test/trials
voxceleb1_root=/home/dawna/mgb3/diarization/imports/voxceleb/voxceleb1
voxceleb2_root=/home/dawna/mgb3/diarization/imports/voxceleb/voxceleb2
musan_root=/home/dawna/mgb3/diarization/imports/musan
rirs_root=/home/dawna/mgb3/diarization/imports/RIRS_NOISES

if [ $stage -le -1 ]; then
    # link the directories
    rm -fr utils steps sid conf local
    ln -s $kaldi_voxceleb/v2/utils ./
    ln -s $kaldi_voxceleb/v2/steps ./
    ln -s $kaldi_voxceleb/v2/sid ./
    ln -s $kaldi_voxceleb/v2/conf ./
    ln -s $kaldi_voxceleb/v2/local ./
fi

if [ $stage -le 0 ]; then
  local/make_voxceleb2.pl $voxceleb2_root dev $data/voxceleb2_train
  local/make_voxceleb2.pl $voxceleb2_root test $data/voxceleb2_test
  # This script reates data/voxceleb1_test and data/voxceleb1_train.
  # Our evaluation set is the test portion of VoxCeleb1.
  local/make_voxceleb1.pl $voxceleb1_root $data
  # We'll train on all of VoxCeleb2, plus the training portion of VoxCeleb1.
  # This should give 7,351 speakers and 1,277,503 utterances.
  utils/combine_data.sh $data/voxceleb_train $data/voxceleb2_train $data/voxceleb2_test $data/voxceleb1_train
fi

if [ $stage -le 1 ]; then
  # Make MFCCs and compute the energy-based VAD for each dataset
  for name in voxceleb_train voxceleb1_test; do
    steps/make_mfcc.sh --write-utt2num-frames true --mfcc-config conf/mfcc.conf --nj 40 --cmd "$train_cmd" \
      $data/${name} exp/make_mfcc $mfccdir
    utils/fix_data_dir.sh $data/${name}
    sid/compute_vad_decision.sh --nj 40 --cmd "$train_cmd" \
      $data/${name} exp/make_vad $vaddir
    utils/fix_data_dir.sh $data/${name}
  done
fi

# In this section, we augment the VoxCeleb2 data with reverberation,
# noise, music, and babble, and combine it with the clean data.
if [ $stage -le 2 ]; then
  frame_shift=0.01
  awk -v frame_shift=$frame_shift '{print $1, $2*frame_shift;}' $data/voxceleb_train/utt2num_frames > $data/voxceleb_train/reco2dur

  # Make sure you already have the RIRS_NOISES dataset
#  # Make a version with reverberated speech
#  rvb_opts=()
#  rvb_opts+=(--rir-set-parameters "0.5, RIRS_NOISES/simulated_rirs/smallroom/rir_list")
#  rvb_opts+=(--rir-set-parameters "0.5, RIRS_NOISES/simulated_rirs/mediumroom/rir_list")

  # Make a reverberated version of the VoxCeleb2 list.  Note that we don't add any
  # additive noise here.
  python steps/data/reverberate_data_dir.py \
    "${rvb_opts[@]}" \
    --speech-rvb-probability 1 \
    --pointsource-noise-addition-probability 0 \
    --isotropic-noise-addition-probability 0 \
    --num-replications 1 \
    --source-sampling-rate 16000 \
    $data/voxceleb_train $data/voxceleb_train_reverb
  cp data/voxceleb_train/vad.scp $data/voxceleb_train_reverb/
  utils/copy_data_dir.sh --utt-suffix "-reverb" $data/voxceleb_train_reverb $data/voxceleb_train_reverb.new
  rm -rf $data/voxceleb_train_reverb
  mv $data/voxceleb_train_reverb.new $data/voxceleb_train_reverb

  # Prepare the MUSAN corpus, which consists of music, speech, and noise
  # suitable for augmentation.
  local/make_musan.sh $musan_root $data

  # Get the duration of the MUSAN recordings.  This will be used by the
  # script augment_data_dir.py.
  for name in speech noise music; do
    utils/data/get_utt2dur.sh $data/musan_${name}
    mv $data/musan_${name}/utt2dur $data/musan_${name}/reco2dur
  done

  # Augment with musan_noise
  python steps/data/augment_data_dir.py --utt-suffix "noise" --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "$data/musan_noise" $data/voxceleb_train $data/voxceleb_train_noise
  # Augment with musan_music
  python steps/data/augment_data_dir.py --utt-suffix "music" --bg-snrs "15:10:8:5" --num-bg-noises "1" --bg-noise-dir "$data/musan_music" $data/voxceleb_train $data/voxceleb_train_music
  # Augment with musan_speech
  python steps/data/augment_data_dir.py --utt-suffix "babble" --bg-snrs "20:17:15:13" --num-bg-noises "3:4:5:6:7" --bg-noise-dir "$data/musan_speech" $data/voxceleb_train $data/voxceleb_train_babble

  # Combine reverb, noise, music, and babble into one directory.
  utils/combine_data.sh $data/voxceleb_train_aug $data/voxceleb_train_reverb $data/voxceleb_train_noise $data/voxceleb_train_music $data/voxceleb_train_babble
fi

if [ $stage -le 3 ]; then
  # Take a random subset of the augmentations
  utils/subset_data_dir.sh $data/voxceleb_train_aug 1000000 $data/voxceleb_train_aug_1m
  utils/fix_data_dir.sh $data/voxceleb_train_aug_1m

  # Make MFCCs for the augmented data.  Note that we do not compute a new
  # vad.scp file here.  Instead, we use the vad.scp from the clean version of
  # the list.
  steps/make_mfcc.sh --mfcc-config conf/mfcc.conf --nj 40 --cmd "$train_cmd" \
    $data/voxceleb_train_aug_1m $exp/make_mfcc $mfccdir

  # Combine the clean and augmented VoxCeleb2 list.  This is now roughly
  # double the size of the original clean list.
  utils/combine_data.sh $data/voxceleb_train_combined $data/voxceleb_train_aug_1m $data/voxceleb_train
fi

# Now we prepare the features to generate examples for xvector training.
if [ $stage -le 4 ]; then
  # Note:
  # I found that if the data is compressed, the loading speed is very slow. Although uncompressed version takes larger
  # disk space, it is still worthy to using the uncompressed one.
  local/nnet3/xvector/prepare_feats_for_egs.sh --compress false --nj 40 --cmd "$train_cmd" \
    $data/voxceleb_train_combined $data2/voxceleb_train_combined_no_sil $exp/voxceleb_train_combined_no_sil
  utils/fix_data_dir.sh $data2/voxceleb_train_combined_no_sil
fi

if [ $stage -le 5 ]; then
  # Now, we need to remove features that are too short after removing silence
  # frames.  We want atleast 5s (500 frames) per utterance.
  min_len=400
  mv $data2/voxceleb_train_combined_no_sil/utt2num_frames $data2/voxceleb_train_combined_no_sil/utt2num_frames.bak
  awk -v min_len=${min_len} '$2 > min_len {print $1, $2}' $data2/voxceleb_train_combined_no_sil/utt2num_frames.bak > $data2/voxceleb_train_combined_no_sil/utt2num_frames
  utils/filter_scp.pl $data2/voxceleb_train_combined_no_sil/utt2num_frames $data2/voxceleb_train_combined_no_sil/utt2spk > $data2/voxceleb_train_combined_no_sil/utt2spk.new
  mv $data2/voxceleb_train_combined_no_sil/utt2spk.new $data2/voxceleb_train_combined_no_sil/utt2spk
  utils/fix_data_dir.sh $data2/voxceleb_train_combined_no_sil

  # We also want several utterances per speaker. Now we'll throw out speakers
  # with fewer than 8 utterances.
  min_num_utts=8
  awk '{print $1, NF-1}' $data2/voxceleb_train_combined_no_sil/spk2utt > $data2/voxceleb_train_combined_no_sil/spk2num
  awk -v min_num_utts=${min_num_utts} '$2 >= min_num_utts {print $1, $2}' $data2/voxceleb_train_combined_no_sil/spk2num | utils/filter_scp.pl - $data2/voxceleb_train_combined_no_sil/spk2utt > $data2/voxceleb_train_combined_no_sil/spk2utt.new
  mv $data2/voxceleb_train_combined_no_sil/spk2utt.new $data2/voxceleb_train_combined_no_sil/spk2utt
  utils/spk2utt_to_utt2spk.pl $data2/voxceleb_train_combined_no_sil/spk2utt > $data2/voxceleb_train_combined_no_sil/utt2spk

  utils/filter_scp.pl $data2/voxceleb_train_combined_no_sil/utt2spk $data2/voxceleb_train_combined_no_sil/utt2num_frames > $data2/voxceleb_train_combined_no_sil/utt2num_frames.new
  mv $data2/voxceleb_train_combined_no_sil/utt2num_frames.new $data2/voxceleb_train_combined_no_sil/utt2num_frames

  # Now we're ready to create training examples.
  utils/fix_data_dir.sh $data2/voxceleb_train_combined_no_sil
fi
exit 1

# Stages 6 through 8 are handled in run_xvector.sh
local/nnet3/xvector/run_xvector.sh --stage $stage --train-stage -1 \
  --data data/train_combined_no_sil --nnet-dir $nnet_dir \
  --egs-dir $nnet_dir/egs

if [ $stage -le 9 ]; then
  # Extract x-vectors for centering, LDA, and PLDA training.
  sid/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd --mem 4G" --nj 80 \
    $nnet_dir data/train \
    $nnet_dir/xvectors_train

  # Extract x-vectors used in the evaluation.
  sid/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd --mem 4G" --nj 40 \
    $nnet_dir data/voxceleb1_test \
    $nnet_dir/xvectors_voxceleb1_test
fi

if [ $stage -le 10 ]; then
  # Compute the mean vector for centering the evaluation xvectors.
  $train_cmd $nnet_dir/xvectors_train/log/compute_mean.log \
    ivector-mean scp:$nnet_dir/xvectors_train/xvector.scp \
    $nnet_dir/xvectors_train/mean.vec || exit 1;

  # This script uses LDA to decrease the dimensionality prior to PLDA.
  lda_dim=200
  $train_cmd $nnet_dir/xvectors_train/log/lda.log \
    ivector-compute-lda --total-covariance-factor=0.0 --dim=$lda_dim \
    "ark:ivector-subtract-global-mean scp:$nnet_dir/xvectors_train/xvector.scp ark:- |" \
    ark:data/train/utt2spk $nnet_dir/xvectors_train/transform.mat || exit 1;

  # Train the PLDA model.
  $train_cmd $nnet_dir/xvectors_train/log/plda.log \
    ivector-compute-plda ark:data/train/spk2utt \
    "ark:ivector-subtract-global-mean scp:$nnet_dir/xvectors_train/xvector.scp ark:- | transform-vec $nnet_dir/xvectors_train/transform.mat ark:- ark:- | ivector-normalize-length ark:-  ark:- |" \
    $nnet_dir/xvectors_train/plda || exit 1;
fi

if [ $stage -le 11 ]; then
  $train_cmd exp/scores/log/voxceleb1_test_scoring.log \
    ivector-plda-scoring --normalize-length=true \
    "ivector-copy-plda --smoothing=0.0 $nnet_dir/xvectors_train/plda - |" \
    "ark:ivector-subtract-global-mean $nnet_dir/xvectors_train/mean.vec scp:$nnet_dir/xvectors_voxceleb1_test/xvector.scp ark:- | transform-vec $nnet_dir/xvectors_train/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean $nnet_dir/xvectors_train/mean.vec scp:$nnet_dir/xvectors_voxceleb1_test/xvector.scp ark:- | transform-vec $nnet_dir/xvectors_train/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$voxceleb1_trials' | cut -d\  --fields=1,2 |" exp/scores_voxceleb1_test || exit 1;
fi

if [ $stage -le 12 ]; then
  eer=`compute-eer <(local/prepare_for_eer.py $voxceleb1_trials exp/scores_voxceleb1_test) 2> /dev/null`
  mindcf1=`sid/compute_min_dcf.py --p-target 0.01 exp/scores_voxceleb1_test $voxceleb1_trials 2> /dev/null`
  mindcf2=`sid/compute_min_dcf.py --p-target 0.001 exp/scores_voxceleb1_test $voxceleb1_trials 2> /dev/null`
  echo "EER: $eer%"
  echo "minDCF(p-target=0.01): $mindcf1"
  echo "minDCF(p-target=0.001): $mindcf2"
  # EER: 3.128%
  # minDCF(p-target=0.01): 0.3258
  # minDCF(p-target=0.001): 0.5003
  #
  # For reference, here's the ivector system from ../v1:
  # EER: 5.329%
  # minDCF(p-target=0.01): 0.4933
  # minDCF(p-target=0.001): 0.6168
fi


