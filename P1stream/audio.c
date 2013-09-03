#include "p1stream_priv.h"

#include <math.h>
#include <stdlib.h>
#include <memory.h>

// Fixed internal mixing buffer parameters.
static const int sample_rate = 44100;
static const int num_channels = 2;
// Hardcoded bitrate.
static const int bit_rate = 128 * 1024;
// Mix buffer buffer of one full second.
static const int mix_samples = num_channels * sample_rate;
// Minimum output buffer size per FDK AAC requirements.
static const int out_min_size = 6144 / 8 * num_channels;
// Complete output buffer size, also one full second.
static const int out_size = out_min_size * 64;

static void p1_audio_write(P1AudioFull *ctx, P1AudioSource *asrc, float **in, size_t *samples);
static size_t p1_audio_read(P1AudioFull *ctx);
static int64_t p1_audio_samples_to_mach_time(P1ContextFull *ctx, size_t samples);


void p1_audio_init(P1AudioFull *audiof, P1Config *cfg, P1ConfigSection *sect)
{
    P1Audio *audio = (P1Audio *) audiof;

    p1_list_init(&audio->sources);

    int ret = pthread_mutex_init(&audio->lock, NULL);
    assert(ret == 0);
}

void p1_audio_start(P1AudioFull *audiof)
{
    P1Audio *audio = (P1Audio *) audiof;
    AACENC_ERROR err;

    audiof->mix = calloc(mix_samples, sizeof(float));
    audiof->enc_in = malloc(mix_samples * sizeof(INT_PCM));
    audiof->out = malloc(out_size);

    err = aacEncOpen(&audiof->aac, 0x01, 2);
    assert(err == AACENC_OK);

    err = aacEncoder_SetParam(audiof->aac, AACENC_AOT, AOT_AAC_LC);
    assert(err == AACENC_OK);
    err = aacEncoder_SetParam(audiof->aac, AACENC_SAMPLERATE, sample_rate);
    assert(err == AACENC_OK);
    err = aacEncoder_SetParam(audiof->aac, AACENC_CHANNELMODE, MODE_2);
    assert(err == AACENC_OK);
    err = aacEncoder_SetParam(audiof->aac, AACENC_BITRATE, bit_rate);
    assert(err == AACENC_OK);
    err = aacEncoder_SetParam(audiof->aac, AACENC_TRANSMUX, TT_MP4_RAW);
    assert(err == AACENC_OK);

    err = aacEncEncode(audiof->aac, NULL, NULL, NULL, NULL);
    assert(err == AACENC_OK);

    p1_set_state(audio->ctx, P1_OTYPE_AUDIO, audio, P1_STATE_RUNNING);
}

void p1_audio_buffer(P1AudioSource *asrc, int64_t time, float *in, size_t samples)
{
    P1Source *src = (P1Source *) asrc;
    P1Context *ctx = src->ctx;
    P1ContextFull *ctxf = (P1ContextFull *) ctx;
    P1Audio *audio = ctx->audio;
    P1AudioFull *audiof = (P1AudioFull *) audio;
    P1Connection *conn = ctx->conn;
    P1ConnectionFull *connf = (P1ConnectionFull *) ctx->conn;

    if (audio->state != P1_STATE_RUNNING || conn->state != P1_STATE_RUNNING)
        return;

    if (!audiof->sent_config) {
        audiof->sent_config = true;
        p1_conn_audio_config(connf);
    }

    // FIXME: we can do better than this.
    pthread_mutex_lock(&audio->lock);

    // Recalculate time for the start of the mix buffer.
    if (asrc->master)
        audiof->time = time - p1_audio_samples_to_mach_time(ctxf, asrc->mix_pos);

    size_t out_size;
    do {
        // Write to the mix buffer.
        p1_audio_write(audiof, asrc, &in, &samples);

        // Read, encode and stream from the mix buffer.
        time = audiof->time;
        out_size = p1_audio_read(audiof);
        if (out_size)
            p1_conn_audio(connf, time, audiof->out, out_size);
    } while (out_size);

    pthread_mutex_unlock(&audio->lock);

    if (samples)
        p1_log(ctx, P1_LOG_WARNING, "Audio mix buffer full, dropped %zd samples!\n", samples);
}

bool p1_configure_audio_source(P1AudioSource *src, P1Config *cfg, P1ConfigSection *sect)
{
    return cfg->get_float(cfg, sect, "volume", &src->volume)
        && cfg->get_bool(cfg, sect, "master", &src->master);
}

// Write as much as possible to the mix buffer.
static void p1_audio_write(P1AudioFull *audiof, P1AudioSource *asrc, float **in, size_t *samples)
{
    size_t to_write = mix_samples - asrc->mix_pos;
    if (*samples < to_write)
        to_write = *samples;

    if (to_write != 0) {
        // Mix samples.
        // FIXME: Maybe synchronize based on timestamps?
        float *p_in = *in;
        float *p_mix = audiof->mix + asrc->mix_pos;
        for (size_t i = 0; i < to_write; i++)
            *(p_mix++) += *(p_in++) * asrc->volume;

        // Progress positions.
        *in = p_in;
        *samples -= to_write;
        asrc->mix_pos += to_write;
    }
}

// Read as much as possible from the ring buffer.
static size_t p1_audio_read(P1AudioFull *audiof)
{
    P1Audio *audio = (P1Audio *) audiof;
    P1Context *ctx = audio->ctx;
    P1ContextFull *ctxf = (P1ContextFull *) ctx;
    P1ListNode *head;
    P1ListNode *node;

    // See how much data is ready.
    size_t samples = mix_samples + 1;
    head = &audio->sources;
    p1_list_iterate(head, node) {
        P1Source *src = (P1Source *) node;
        P1AudioSource *asrc = (P1AudioSource *) node;

        if (src->state == P1_STATE_RUNNING) {
            if (asrc->mix_pos < samples)
                samples = asrc->mix_pos;
        }
    }
    if (samples > mix_samples)
        return 0;

    // Convert to 16-bit.
    // FIXME: this is wasteful, because we potentially do this multiple times
    // for the same samples. Predict reads using aac->nSamplesToRead.
    float *mix = audiof->mix;
    INT_PCM *enc_in = audiof->enc_in;
    for (size_t i = 0; i < samples; i++) {
        float sample = mix[i];
        if (sample > +1.0) sample = +1.0;
        if (sample < -1.0) sample = -1.0;
        enc_in[i] = (INT_PCM) (sample * SAMPLE_MAX);
    }

    // Prepare encoder arguments.
    INT el_sizes[] = { sizeof(INT_PCM) };

    void *enc_bufs[] = { enc_in };
    INT enc_identifiers[] = { IN_AUDIO_DATA };
    INT enc_sizes[] = { (INT) (samples * sizeof(INT_PCM)) };
    AACENC_BufDesc in_desc = {
        .numBufs = 1,
        .bufs = enc_bufs,
        .bufferIdentifiers = enc_identifiers,
        .bufSizes = enc_sizes,
        .bufElSizes = el_sizes
    };

    void *out_bufs[] = { audiof->out };
    INT out_identifiers[] = { OUT_BITSTREAM_DATA };
    INT out_sizes[] = { out_size };
    AACENC_BufDesc out_desc = {
        .numBufs = 1,
        .bufs = out_bufs,
        .bufferIdentifiers = out_identifiers,
        .bufSizes = out_sizes,
        .bufElSizes = el_sizes
    };

    AACENC_InArgs in_args = {
        .numInSamples = (INT) samples,
        .numAncBytes = 0
    };

    // Encode as much as we can; FDK AAC gives us small batches.
    AACENC_ERROR err;
    AACENC_OutArgs out_args = { .numInSamples = 1 };
    while (in_args.numInSamples && out_args.numInSamples && out_desc.bufSizes[0] > out_min_size) {
        err = aacEncEncode(audiof->aac, &in_desc, &out_desc, &in_args, &out_args);
        assert(err == AACENC_OK);

        size_t in_processed = out_args.numInSamples * sizeof(INT_PCM);
        in_desc.bufs[0] += in_processed;
        in_desc.bufSizes[0] -= in_processed;

        size_t out_bytes = out_args.numOutBytes;
        out_desc.bufs[0] += out_bytes;
        out_desc.bufSizes[0] -= out_bytes;

        in_args.numInSamples -= out_args.numInSamples;
    }

    // Move remaining data up in the mix buffer.
    size_t mix_read = (INT_PCM *) in_desc.bufs[0] - enc_in;
    if (mix_read) {
        size_t mix_remaining = samples - mix_read;
        if (mix_remaining)
            memmove(mix, in_desc.bufs[0], mix_remaining * sizeof(float));
        memset(mix + mix_remaining, 0, mix_read * sizeof(float));

        // Adjust source positions.
        p1_list_iterate(head, node) {
            P1AudioSource *asrc = (P1AudioSource *) node;
            asrc->mix_pos -= mix_read;
        }

        // Recalculate mix buffer start time.
        audiof->time += p1_audio_samples_to_mach_time(ctxf, mix_read);
    }

    return out_desc.bufs[0] - audiof->out;
}

static int64_t p1_audio_samples_to_mach_time(P1ContextFull *ctxf, size_t samples)
{
    int64_t nanosec = samples / num_channels * 1000000000 / sample_rate;
    return nanosec * ctxf->timebase.denom / ctxf->timebase.numer;
}
