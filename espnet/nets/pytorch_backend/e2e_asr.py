#!/usr/bin/env python

# Copyright 2017 Johns Hopkins University (Shinji Watanabe)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)


from __future__ import division

import argparse
import logging
import math

import editdistance

import chainer
import numpy as np
import six
import torch

from itertools import groupby

from chainer import reporter

from espnet.nets.asr_interface import ASRInterface
from espnet.nets.e2e_asr_common import label_smoothing_dist
from espnet.nets.pytorch_backend.ctc import ctc_for
from espnet.nets.pytorch_backend.nets_utils import pad_list
from espnet.nets.pytorch_backend.nets_utils import to_device
from espnet.nets.pytorch_backend.nets_utils import to_torch_tensor
from espnet.nets.pytorch_backend.rnn.attentions import att_for
from espnet.nets.pytorch_backend.rnn.decoders import decoder_for
from espnet.nets.pytorch_backend.rnn.encoders import encoder_for

CTC_LOSS_THRESHOLD = 10000


class Reporter(chainer.Chain):
    """A chainer reporter wrapper"""

    def report(self, loss_ctc, loss_att, acc, cer_ctc, cer, wer, mtl_loss):
        reporter.report({'loss_ctc': loss_ctc}, self)
        reporter.report({'loss_att': loss_att}, self)
        reporter.report({'acc': acc}, self)
        reporter.report({'cer_ctc': cer_ctc}, self)
        reporter.report({'cer': cer}, self)
        reporter.report({'wer': wer}, self)
        logging.info('mtl loss:' + str(mtl_loss))
        reporter.report({'loss': mtl_loss}, self)


class E2E(ASRInterface, torch.nn.Module):
    """E2E module

    :param int idim: dimension of inputs
    :param int odim: dimension of outputs
    :param Namespace args: argument Namespace containing options
    """

    def __init__(self, idim, odim, args):
        torch.nn.Module.__init__(self)
        self.mtlalpha = args.mtlalpha
        assert 0.0 <= self.mtlalpha <= 1.0, "mtlalpha should be [0.0, 1.0]"
        self.etype = args.etype
        self.verbose = args.verbose
        self.char_list = args.char_list
        self.outdir = args.outdir
        self.space = args.sym_space
        self.blank = args.sym_blank
        self.reporter = Reporter()

        # below means the last number becomes eos/sos ID
        # note that sos/eos IDs are identical
        self.sos = odim - 1
        self.eos = odim - 1

        # subsample info
        # +1 means input (+1) and layers outputs (args.elayer)
        subsample = np.ones(args.elayers + 1, dtype=np.int)
        if args.etype.endswith("p") and not args.etype.startswith("vgg"):
            ss = args.subsample.split("_")
            for j in range(min(args.elayers + 1, len(ss))):
                subsample[j] = int(ss[j])
        else:
            logging.warning(
                'Subsampling is not performed for vgg*. It is performed in max pooling layers at CNN.')
        logging.info('subsample: ' + ' '.join([str(x) for x in subsample]))
        self.subsample = subsample

        # label smoothing info
        if args.lsm_type:
            logging.info("Use label smoothing with " + args.lsm_type)
            labeldist = label_smoothing_dist(odim, args.lsm_type, transcript=args.train_json)
        else:
            labeldist = None

        if args.use_frontend:
            # Relative importing because of using python3 syntax
            from espnet.nets.pytorch_backend.frontends.feature_transform \
                import feature_transform_for
            from espnet.nets.pytorch_backend.frontends.frontend \
                import frontend_for

            self.frontend = frontend_for(args, idim)
            self.feature_transform = feature_transform_for(args, (idim - 1) * 2)
            idim = args.n_mels
        else:
            self.frontend = None

        # encoder
        self.enc = encoder_for(args, idim, self.subsample)
        # ctc
        self.ctc = ctc_for(args, odim)
        # attention
        self.att = att_for(args)
        # decoder
        self.dec = decoder_for(args, odim, self.sos, self.eos, self.att, labeldist)

        # weight initialization
        self.init_like_chainer()

        # options for beam search
        if 'report_cer' in vars(args) and (args.report_cer or args.report_wer):
            recog_args = {'beam_size': args.beam_size, 'penalty': args.penalty,
                          'ctc_weight': args.ctc_weight, 'maxlenratio': args.maxlenratio,
                          'minlenratio': args.minlenratio, 'lm_weight': args.lm_weight,
                          'rnnlm': args.rnnlm, 'nbest': args.nbest,
                          'space': args.sym_space, 'blank': args.sym_blank}

            self.recog_args = argparse.Namespace(**recog_args)
            self.report_cer = args.report_cer
            self.report_wer = args.report_wer
        else:
            self.report_cer = False
            self.report_wer = False
        self.rnnlm = None

        self.logzero = -10000000000.0
        self.loss = None
        self.acc = None
        self.loss_siam = None
        self.pairwise = args.pairwise
        self.pair_lambda = args.pair_lambda
        self.pair_alpha = args.pair_alpha
        self.epsilon = args.oversamp_epsilon

    def init_like_chainer(self):
        """Initialize weight like chainer

        chainer basically uses LeCun way: W ~ Normal(0, fan_in ** -0.5), b = 0
        pytorch basically uses W, b ~ Uniform(-fan_in**-0.5, fan_in**-0.5)

        however, there are two exceptions as far as I know.
        - EmbedID.W ~ Normal(0, 1)
        - LSTM.upward.b[forget_gate_range] = 1 (but not used in NStepLSTM)
        """

        def lecun_normal_init_parameters(module):
            for p in module.parameters():
                data = p.data
                if data.dim() == 1:
                    # bias
                    data.zero_()
                elif data.dim() == 2:
                    # linear weight
                    n = data.size(1)
                    stdv = 1. / math.sqrt(n)
                    data.normal_(0, stdv)
                elif data.dim() in (3, 4):
                    # conv weight
                    n = data.size(1)
                    for k in data.size()[2:]:
                        n *= k
                    stdv = 1. / math.sqrt(n)
                    data.normal_(0, stdv)
                else:
                    raise NotImplementedError

        def set_forget_bias_to_one(bias):
            n = bias.size(0)
            start, end = n // 4, n // 2
            bias.data[start:end].fill_(1.)

        lecun_normal_init_parameters(self)
        # exceptions
        # embed weight ~ Normal(0, 1)
        self.dec.embed.weight.data.normal_(0, 1)
        # forget-bias = 1.0
        # https://discuss.pytorch.org/t/set-forget-gate-bias-of-lstm/1745
        for l in six.moves.range(len(self.dec.decoder)):
            set_forget_bias_to_one(self.dec.decoder[l].bias_ih)

    def forward(self, xs_pad, ilens, ys_pad):
        """E2E forward

        :param torch.Tensor xs_pad: batch of padded input sequences (B, Tmax, idim)
        :param torch.Tensor ilens: batch of lengths of input sequences (B)
        :param torch.Tensor ys_pad: batch of padded character id sequence tensor (B, Lmax)
        :return: ctc loass value
        :rtype: torch.Tensor
        :return: attention loss value
        :rtype: torch.Tensor
        :return: accuracy in attention decoder
        :rtype: float
        """
        # 0. Frontend
        if self.frontend is not None:
            hs_pad, hlens, mask = self.frontend(to_torch_tensor(xs_pad), ilens)
            hs_pad, hlens = self.feature_transform(hs_pad, hlens)
        else:
            hs_pad, hlens = xs_pad, ilens
        ignore_mask = np.zeros(len(hs_pad))
        if self.pairwise:
            r,c = hs_pad[0,:,:].shape
            for i in range(int(len(hs_pad)/2)):
                delta_norm =torch.norm(hs_pad[2*i,:,:]-hs_pad[2*i+1,:,:])/pow(r*c,0.5)
                logging.info("delta_norm is" + str(delta_norm))
                #logging.info("epsilon is" + str(self.epsilon))
                if( delta_norm <= self.epsilon):
                    ignore_mask[2*i]=1
        ignore_mask = (ignore_mask==1)
        #logging.info("ignore_mask is "+ str(ignore_mask))

        # 1. Encoder
        #logging.info("before sorting hlens is: "+ str(hlens))
        hlens2 , perm_index = torch.tensor(hlens).sort(0,descending=True)
        #logging.info("after sorting hlens is : "+str(hlens2))
        hs_pad = hs_pad[perm_index,:,:]
        hlens = hlens2
        hs_pad, hlens, _ = self.enc(hs_pad, hlens)

        hs_pad = hs_pad[perm_index.sort()[1],:,:]
        hlens = hlens[perm_index.sort()[1]]

        # 2. CTC loss
        if self.mtlalpha == 0:
            self.loss_ctc = None
        else:
            self.loss_ctc = self.ctc(hs_pad, hlens, ys_pad)

        # 3. attention loss
        if self.mtlalpha == 1:
            self.loss_att, self.loss_siam, acc = None, None, None
        else:
            self.loss_att, self.loss_siam, acc = self.dec(hs_pad, hlens, ys_pad, ignore_mask)
        self.acc = acc

        # 4. compute cer without beam search
        if self.mtlalpha == 0:
            cer_ctc = None
        else:
            cers = []

            y_hats = self.ctc.argmax(hs_pad).data
            for i, y in enumerate(y_hats):
                y_hat = [x[0] for x in groupby(y)]
                y_true = ys_pad[i]

                seq_hat = [self.char_list[int(idx)] for idx in y_hat if int(idx) != -1]
                seq_true = [self.char_list[int(idx)] for idx in y_true if int(idx) != -1]
                seq_hat_text = "".join(seq_hat).replace(self.space, ' ')
                seq_hat_text = seq_hat_text.replace(self.blank, '')
                seq_true_text = "".join(seq_true).replace(self.space, ' ')

                hyp_chars = seq_hat_text.replace(' ', '')
                ref_chars = seq_true_text.replace(' ', '')
                if len(ref_chars) > 0:
                    cers.append(editdistance.eval(hyp_chars, ref_chars) / len(ref_chars))

            cer_ctc = sum(cers) / len(cers) if cers else None

        # 5. compute cer/wer
        if self.training or not (self.report_cer or self.report_wer):
            #print ("Assigning WER and CER as 0 (line 250)")
            cer, wer = 0.0, 0.0
            # oracle_cer, oracle_wer = 0.0, 0.0
        else:
            if self.recog_args.ctc_weight > 0.0:
                lpz = self.ctc.log_softmax(hs_pad).data
            else:
                lpz = None

            word_eds, word_ref_lens, char_eds, char_ref_lens = [], [], [], []
            nbest_hyps = self.dec.recognize_beam_batch(hs_pad, torch.tensor(hlens), lpz,
                                                       self.recog_args, self.char_list,
                                                       self.rnnlm)
            # remove <sos> and <eos>
            y_hats = [nbest_hyp[0]['yseq'][1:-1] for nbest_hyp in nbest_hyps]
            for i, y_hat in enumerate(y_hats):
                y_true = ys_pad[i]

                seq_hat = [self.char_list[int(idx)] for idx in y_hat if int(idx) != -1]
                seq_true = [self.char_list[int(idx)] for idx in y_true if int(idx) != -1]
                seq_hat_text = "".join(seq_hat).replace(self.recog_args.space, ' ')
                seq_hat_text = seq_hat_text.replace(self.recog_args.blank, '')
                seq_true_text = "".join(seq_true).replace(self.recog_args.space, ' ')

                #print added by vinit to compare between teacher forced and non teacher forced outputs
                logging.info('Nbest output-->groundtruth is ' + seq_true_text)
                logging.info('Nbest output-->prediction  is ' + seq_hat_text)

                hyp_words = seq_hat_text.split()
                ref_words = seq_true_text.split()
                word_eds.append(editdistance.eval(hyp_words, ref_words))
                word_ref_lens.append(len(ref_words))
                hyp_chars = seq_hat_text.replace(' ', '')
                ref_chars = seq_true_text.replace(' ', '')
                char_eds.append(editdistance.eval(hyp_chars, ref_chars))
                char_ref_lens.append(len(ref_chars))

            wer = 0.0 if not self.report_wer else float(sum(word_eds)) / sum(word_ref_lens)
            print ('wer set as 0 line 284' if not self.report_wer else 'wer calculated line 284')
            cer = 0.0 if not self.report_cer else float(sum(char_eds)) / sum(char_ref_lens)
            print ('cer set as 0 line 286' if not self.report_cer else 'cer calculated line 286')

        alpha = self.mtlalpha
        if alpha == 0:
            self.loss = self.loss_att
            loss_att_data = float(self.loss_att)
            loss_ctc_data = None
        elif alpha == 1:
            self.loss = self.loss_ctc
            loss_att_data = None
            loss_ctc_data = float(self.loss_ctc)
        else:
            self.loss = alpha * self.loss_ctc + (1 - alpha) * self.loss_att
            loss_att_data = float(self.loss_att)
            loss_ctc_data = float(self.loss_ctc)

        loss_data = float(self.loss)
        if self.pairwise:
            self.loss = ((1.0-self.pair_lambda)*self.loss)+(self.pair_lambda*self.loss_siam)
            self.loss*=self.pair_alpha
            #self.loss = loss_data
            loss_data = float(self.loss)
        if loss_data < CTC_LOSS_THRESHOLD and not math.isnan(loss_data):
            self.reporter.report(loss_ctc_data, loss_att_data, acc, cer_ctc, cer, wer, loss_data)
        else:
            logging.warning('loss (=%f) is not correct', loss_data)
        return self.loss

    def recognize(self, x, recog_args, char_list, rnnlm=None):
        """E2E beam search

        :param ndarray x: input acoustic feature (T, D)
        :param Namespace recog_args: argument Namespace containing options
        :param list char_list: list of characters
        :param torch.nn.Module rnnlm: language model module
        :return: N-best decoding results
        :rtype: list
        """
        prev = self.training
        self.eval()
        ilens = [x.shape[0]]

        # subsample frame
        x = x[::self.subsample[0], :]
        h = to_device(self, to_torch_tensor(x).float())
        # make a utt list (1) to use the same interface for encoder
        hs = h.contiguous().unsqueeze(0)

        # 0. Frontend
        if self.frontend is not None:
            enhanced, hlens, mask = self.frontend(hs, ilens)
            hs, hlens = self.feature_transform(enhanced, hlens)
        else:
            hs, hlens = hs, ilens

        # 1. encoder
        hs, _, _ = self.enc(hs, hlens)

        # calculate log P(z_t|X) for CTC scores
        if recog_args.ctc_weight > 0.0:
            lpz = self.ctc.log_softmax(hs)[0]
        else:
            lpz = None

        # 2. Decoder
        # decode the first utterance
        y = self.dec.recognize_beam(hs[0], lpz, recog_args, char_list, rnnlm)

        if prev:
            self.train()

        return y

    def recognize_batch(self, xs, recog_args, char_list, rnnlm=None):
        """E2E beam search

        :param list xs: list of input acoustic feature arrays [(T_1, D), (T_2, D), ...]
        :param Namespace recog_args: argument Namespace containing options
        :param list char_list: list of characters
        :param torch.nn.Module rnnlm: language model module
        :return: N-best decoding results
        :rtype: list
        """
        prev = self.training
        self.eval()
        ilens = np.fromiter((xx.shape[0] for xx in xs), dtype=np.int64)

        # subsample frame
        xs = [xx[::self.subsample[0], :] for xx in xs]
        xs = [to_device(self, to_torch_tensor(xx).float()) for xx in xs]
        xs_pad = pad_list(xs, 0.0)

        # 0. Frontend
        if self.frontend is not None:
            enhanced, hlens, mask = self.frontend(xs_pad, ilens)
            hs_pad, hlens = self.feature_transform(enhanced, hlens)
        else:
            hs_pad, hlens = xs_pad, ilens

        # 1. encoder
        hs_pad, hlens, _ = self.enc(hs_pad, hlens)

        # calculate log P(z_t|X) for CTC scores
        if recog_args.ctc_weight > 0.0:
            lpz = self.ctc.log_softmax(hs_pad)
        else:
            lpz = None

        # 2. decoder
        hlens = torch.tensor(list(map(int, hlens)))  # make sure hlens is tensor
        y = self.dec.recognize_beam_batch(hs_pad, hlens, lpz, recog_args, char_list, rnnlm)

        if prev:
            self.train()
        return y

    def enhance(self, xs):
        """Forwarding only the frontend stage

        :param ndarray xs: input acoustic feature (T, C, F)
        """

        if self.frontend is None:
            raise RuntimeError('Frontend does\'t exist')
        prev = self.training
        self.eval()
        ilens = np.fromiter((xx.shape[0] for xx in xs), dtype=np.int64)

        # subsample frame
        xs = [xx[::self.subsample[0], :] for xx in xs]
        xs = [to_device(self, to_torch_tensor(xx).float()) for xx in xs]
        xs_pad = pad_list(xs, 0.0)
        enhanced, hlensm, mask = self.frontend(xs_pad, ilens)
        if prev:
            self.train()
        return enhanced.cpu().numpy(), mask.cpu().numpy(), ilens

    def calculate_all_attentions(self, xs_pad, ilens, ys_pad):
        """E2E attention calculation

        :param torch.Tensor xs_pad: batch of padded input sequences (B, Tmax, idim)
        :param torch.Tensor ilens: batch of lengths of input sequences (B)
        :param torch.Tensor ys_pad: batch of padded character id sequence tensor (B, Lmax)
        :return: attention weights with the following shape,
            1) multi-head case => attention weights (B, H, Lmax, Tmax),
            2) other case => attention weights (B, Lmax, Tmax).
        :rtype: float ndarray
        """
        with torch.no_grad():
            # 0. Frontend
            if self.frontend is not None:
                hs_pad, hlens, mask = self.frontend(to_torch_tensor(xs_pad), ilens)
                hs_pad, hlens = self.feature_transform(hs_pad, hlens)
            else:
                hs_pad, hlens = xs_pad, ilens

            # 1. Encoder
            hpad, hlens, _ = self.enc(hs_pad, hlens)

            # 2. Decoder
            att_ws = self.dec.calculate_all_attentions(hpad, hlens, ys_pad)

        return att_ws

    def subsample_frames(self, x):
        # subsample frame
        x = x[::self.subsample[0], :]
        ilen = [x.shape[0]]
        h = to_device(self, torch.from_numpy(
            np.array(x, dtype=np.float32)))
        h.contiguous()
        return h, ilen
