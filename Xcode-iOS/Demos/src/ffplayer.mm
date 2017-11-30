/*
 * SDL_Lesson.c
 *
 *  Created on: Aug 12, 2014
 *      Author: clarck
 */

#ifdef __cplusplus
extern "C" {
#endif
    
#include <libavutil/time.h>
#include "ffplayer.h"

uint64_t global_video_pkt_pts = AV_NOPTS_VALUE;
VideoState *global_video_state = NULL;

void packet_queue_init(PacketQueue *q) {
    memset(q, 0, sizeof(PacketQueue));
    q->mutex = SDL_CreateMutex();
    q->cond = SDL_CreateCond();
}

int packet_queue_put(PacketQueue *q, AVPacket *pkt) {
    AVPacketList *pkt1;
    
    pkt1 = (AVPacketList *) av_malloc(sizeof(AVPacketList));
    if (!pkt1) {
        return -1;
    }
    pkt1->pkt = *pkt;
    pkt1->next = NULL;
    
    SDL_LockMutex(q->mutex);
    
    if (!q->last_pkt) {
        q->first_pkt = pkt1;
    } else {
        q->last_pkt->next = pkt1;
    }
    
    q->last_pkt = pkt1;
    q->nb_packets++;
    q->size += pkt1->pkt.size;
    SDL_CondSignal(q->cond);
    SDL_UnlockMutex(q->mutex);
    return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block) {
    AVPacketList *pkt1;
    int ret;
    
    SDL_LockMutex(q->mutex);
    
    for (;;) {
        SDL_LockMutex(global_video_state->audio_mutex);
        while (global_video_state->quit == 1) {
            NSLog(@"packet_queue_get is->quit == 1");
            SDL_CondWaitTimeout(global_video_state->audio_cond, global_video_state->audio_mutex,
                                10);
            if (global_video_state->quit == 1) {
                ret = -1;
                SDL_UnlockMutex(global_video_state->audio_mutex);
                SDL_UnlockMutex(q->mutex);
                return ret;
            }
        }
        SDL_UnlockMutex(global_video_state->audio_mutex);
        
        pkt1 = q->first_pkt;
        if (pkt1) {
            q->first_pkt = pkt1->next;
            if (!q->first_pkt) {
                q->last_pkt = NULL;
            }
            q->nb_packets--;
            q->size -= pkt1->pkt.size;
            *pkt = pkt1->pkt;
            
            av_free(pkt1);
            ret = 1;
            break;
        } else if (!block) {
            ret = 0;
            SDL_CondWaitTimeout(q->cond, q->mutex, 10);
            //break;
        } else {
            SDL_CondWait(q->cond, q->mutex);
        }
    }
    
    SDL_UnlockMutex(q->mutex);
    
    return ret;
}

void packet_queue_flush(PacketQueue *q) {
    AVPacketList *pkt, *pkt1;
    
    SDL_LockMutex(q->mutex);
    for (pkt = q->first_pkt; pkt; pkt = pkt1) {
        pkt1 = pkt->next;
        av_packet_unref(&pkt->pkt);
        //av_freep(&pkt);
    }
    q->last_pkt = NULL;
    q->first_pkt = NULL;
    q->nb_packets = 0;
    q->size = 0;
    SDL_UnlockMutex(q->mutex);
}

double get_audio_clock(VideoState *is) {
    double pts;
    int hw_buf_size, bytes_per_sec, n;
    
    pts = is->audio_clock; /* maintained in the audio thread */
    hw_buf_size = is->audio_buf_size - is->audio_buf_index;
    bytes_per_sec = 0;
    n = is->audio_st->codec->channels * 2;
    if (is->audio_st) {
        bytes_per_sec = is->audio_st->codec->sample_rate * n;
    }
    if (bytes_per_sec) {
        pts -= (double) hw_buf_size / bytes_per_sec;
    }
    return pts;
}

double get_video_clock(VideoState *is) {
    double delta;
    
    delta = (av_gettime() - is->video_current_pts_time) / 1000000.0;
    return is->video_current_pts + delta;
}

double get_external_clock(VideoState *is) {
    return av_gettime() / 1000000.0;
}

double get_master_clock(VideoState *is) {
    if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
        return get_video_clock(is);
    } else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
        return get_audio_clock(is);
    } else {
        return get_external_clock(is);
    }
}

/* Add or subtract samples to get a better sync, return new audio buffer size */
int synchronize_audio(VideoState *is, short *samples, int samples_size, double pts) {
    int n;
    double ref_clock;
    
    n = 2 * is->audio_st->codec->channels;
    
    if (is->av_sync_type != AV_SYNC_AUDIO_MASTER) {
        
        double diff, avg_diff;
        int wanted_size, min_size, max_size;
        //int nb_samples;
        
        ref_clock = get_master_clock(is);
        diff = get_audio_clock(is) - ref_clock;
        
        if (diff < AV_NOSYNC_THRESHOLD) {
            // accumulate the diffs
            is->audio_diff_cum = diff + is->audio_diff_avg_coef * is->audio_diff_cum;
            if (is->audio_diff_avg_count < AUDIO_DIFF_AVG_NB) {
                is->audio_diff_avg_count++;
            } else {
                avg_diff = is->audio_diff_cum * (1.0 - is->audio_diff_avg_coef);
                if (fabs(avg_diff) >= is->audio_diff_threshold) {
                    wanted_size =
                    samples_size + ((int) (diff * is->audio_st->codec->sample_rate) * n);
                    min_size = samples_size * ((100 - SAMPLE_CORRECTION_PERCENT_MAX) / 100);
                    max_size = samples_size * ((100 + SAMPLE_CORRECTION_PERCENT_MAX) / 100);
                    if (wanted_size < min_size) {
                        wanted_size = min_size;
                    } else if (wanted_size > max_size) {
                        wanted_size = max_size;
                    }
                    if (wanted_size < samples_size) {
                        /* remove samples */
                        samples_size = wanted_size;
                    } else if (wanted_size > samples_size) {
                        uint8_t *samples_end, *q;
                        int nb;
                        
                        /* add samples by copying final sample*/
                        nb = (samples_size - wanted_size);
                        samples_end = (uint8_t *) samples + samples_size - n;
                        q = samples_end + n;
                        while (nb > 0) {
                            memcpy(q, samples_end, n);
                            q += n;
                            nb -= n;
                        }
                        samples_size = wanted_size;
                    }
                }
            }
        } else {
            /* difference is TOO big; reset diff stuff */
            is->audio_diff_avg_count = 0;
            is->audio_diff_cum = 0;
        }
        //LOGD("====synchronize_audio called better_sync_samples_size %d\n",samples_size);
    }
    return samples_size;
}

int audio_decode_frame(VideoState *is, double *pts_ptr) {
    int len1, len2, decoded_data_size;
    AVPacket *pkt = &is->audio_pkt;
    int got_frame = 0;
    int64_t dec_channel_layout;
    int wanted_nb_samples, resampled_data_size, n;
    
    double pts;
    
    NSLog(@"audio_decode_frame Start!");
    
    for (;;) {
        SDL_LockMutex(is->audio_mutex);
        if (is->quit == 1)
            SDL_CondSignal(is->audio_cond);
        SDL_UnlockMutex(is->audio_mutex);
        
        SDL_LockMutex(is->audio_mutex);
        while (is->quit) {
            NSLog(@"audio_decode_frame is->quit == 1");
            SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
            if (is->quit == 1) {
                SDL_UnlockMutex(is->audio_mutex);
                SDL_PauseAudio(1);
                NSLog(@"audio_callback quit == 1");
                return -1;
            }
        }
        SDL_UnlockMutex(is->audio_mutex);
        
        // pause and resume
        if (is->paused) {
            return -1;
        }
        //        LOGD("audio_decode_frame called 2, is->audio_pkt_size:%d", is->audio_pkt_size);
        // multiple frames in a single AVPacket
        while (is->audio_pkt_size > 0) {
            SDL_LockMutex(is->audio_mutex);
            while (is->quit) {
                NSLog(@"audio_decode_frame is->quit == 1");
                SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
                if (is->quit == 1) {
                    SDL_UnlockMutex(is->audio_mutex);
                    SDL_PauseAudio(1);
                    NSLog(@"audio_callback quit == 1");
                    return -1;
                }
            }
            SDL_UnlockMutex(is->audio_mutex);
            //            LOGD("audio_decode_frame called 3");
            if (!is->audio_frame) {
                if (!(is->audio_frame = av_frame_alloc())) {
                    return AVERROR(ENOMEM);
                }
            }
            //            else {
            //                avcodec_get_frame_defaults(is->audio_frame);
            //            }
            // the number of bytes consumed from the input AVPacket
            len1 = avcodec_decode_audio4(is->audio_st->codec, is->audio_frame, &got_frame, pkt);
            if (len1 < 0) {
                // error, skip the frame
                is->audio_pkt_size = 0;
                break;
            }
            
            is->audio_pkt_data += len1;
            is->audio_pkt_size -= len1;
            
            if (!got_frame)
                continue;
            
            /* 计算解码出来的帧需要的缓冲大小 */
            decoded_data_size = av_samples_get_buffer_size(NULL, is->audio_frame->channels,
                                                           is->audio_frame->nb_samples,
                                                           (enum AVSampleFormat)is->audio_frame->format, 1);
            //LOGD("====解码出来的帧需要的缓冲大小decoded_data_size:: %d\n",decoded_data_size);
            dec_channel_layout = (is->audio_frame->channel_layout && is->audio_frame->channels ==
                                  av_get_channel_layout_nb_channels(
                                                                    is->audio_frame->channel_layout))
            ? is->audio_frame->channel_layout : av_get_default_channel_layout(
                                                                              is->audio_frame->channels);
            
            // 希望每一个音频帧采样数 当音视频同步方式是音频同步视频时，需要增加或减少每一帧采样数才会需要重采样
            wanted_nb_samples = is->audio_frame->nb_samples;
            
            // 重采样两层含义：
            // 1.audio file audio播放参数（source format）与 SDL计算出来的播放参数(target format)不一致时
            // 2.当音视频同步方式是音频同步视频时，需要增加或减少每一帧采样数来同步。
            
            //            LOGD("source format format::%d   channel_layout::%lld  sample_rate::%d \n",is->audio_frame->format,dec_channel_layout,is->audio_frame->sample_rate);
            //            LOGD("target format format::%d   channel_layout::%lld  sample_rate::%d \n",is->audio_src_fmt,is->audio_src_channel_layout,is->audio_src_freq);
            
            // 当audio file audio播放参数（source format）与 SDL计算出来的播放参数(target format)不一致时 需要resample(source format --> target forma)
            if (is->audio_frame->format != is->audio_src_fmt ||
                dec_channel_layout != is->audio_src_channel_layout ||
                is->audio_frame->sample_rate != is->audio_src_freq ||
                wanted_nb_samples != is->audio_frame->nb_samples && !is->swr_ctx) {
                NSLog(@"====audio source format 与 sdl target format 不一致 初始化swr_ctx \n");
                if (is->swr_ctx)
                    swr_free(&is->swr_ctx);
                is->swr_ctx = swr_alloc_set_opts(NULL,
                                                 is->audio_tgt_channel_layout, (enum AVSampleFormat)is->audio_tgt_fmt,
                                                 is->audio_tgt_freq,
                                                 dec_channel_layout, (enum AVSampleFormat)is->audio_frame->format,
                                                 is->audio_frame->sample_rate,
                                                 0, NULL);
                if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
                    fprintf(stderr, "swr_init() failed\n");
                    break;
                }
                is->audio_src_channel_layout = dec_channel_layout;
                is->audio_src_channels = is->audio_st->codec->channels;
                is->audio_src_freq = is->audio_st->codec->sample_rate;
                is->audio_src_fmt = is->audio_st->codec->sample_fmt;
            } else {
                int i = 1;
            }
            
            /* 这里我们可以对采样数进行调整，增加或者减少，一般可以用来做声画同步 */
            if (is->swr_ctx) {
                const uint8_t **in = (const uint8_t **) is->audio_frame->extended_data;
                uint8_t *out[] = {is->audio_buf2};
                if (wanted_nb_samples != is->audio_frame->nb_samples) {
                    NSLog(@"===进行重采样");
                    if (swr_set_compensation(is->swr_ctx,
                                             (wanted_nb_samples - is->audio_frame->nb_samples) *
                                             is->audio_tgt_freq / is->audio_frame->sample_rate,
                                             wanted_nb_samples * is->audio_tgt_freq /
                                             is->audio_frame->sample_rate
                                             ) < 0) {
                        fprintf(stderr, "swr_set_compensation() failed\n");
                        break;
                    }
                }
                
                len2 = swr_convert(is->swr_ctx, out,
                                   sizeof(is->audio_buf2) / is->audio_tgt_channels
                                   / av_get_bytes_per_sample(is->audio_tgt_fmt),
                                   in, is->audio_frame->nb_samples);
                if (len2 < 0) {
                    fprintf(stderr, "swr_convert() failed\n");
                    break;
                }
                if (len2 == sizeof(is->audio_buf2) / is->audio_tgt_channels /
                    av_get_bytes_per_sample(is->audio_tgt_fmt)) {
                    fprintf(stderr, "warning: audio buffer is probably too small\n");
                    swr_init(is->swr_ctx);
                }
                
                //is->audio_buf = is->audio_buf2;
                resampled_data_size =
                len2 * is->audio_tgt_channels * av_get_bytes_per_sample(is->audio_tgt_fmt);
                memcpy(is->audio_buf, is->audio_buf2, resampled_data_size);
            } else {
                resampled_data_size = decoded_data_size;
                memcpy(is->audio_buf, is->audio_frame->data[0], resampled_data_size);
                //is->audio_buf = is->audio_frame->data[0];
            }
            
            pts = is->audio_clock;
            *pts_ptr = pts;
            n = 2 * is->audio_st->codec->channels;
            is->audio_clock +=
            (double) resampled_data_size / (double) (n * is->audio_st->codec->sample_rate);
            
            // We have data, return it and come back for more later
            //LOGD("====重采样后一帧需要的缓冲大小 resampled_data_size:: %d\n",resampled_data_size);
            return resampled_data_size;
        }// end while
        
        if (pkt->data)
            av_free_packet(pkt);
        memset(pkt, 0, sizeof(*pkt));
        
        if (packet_queue_get(&is->audioq, pkt, 1) < 0)
            return -1;
        
        if (pkt->data == is->flush_pkt.data) { ///seek 才会发生
            avcodec_flush_buffers(is->audio_st->codec);
            continue;
        }
        
        is->audio_pkt_data = pkt->data;
        is->audio_pkt_size = pkt->size;
        
        /* if update, update the audio clock w/pts */
        if (pkt->pts != AV_NOPTS_VALUE) {
            is->audio_clock = av_q2d(is->audio_st->time_base) * pkt->pts;
        }
    }// end for
    return -1;
}

void audio_callback(void *userdata, Uint8 *stream, int len) {
    //SDL_LockAudio();
    //    VideoState *is = (VideoState *) userdata;
    VideoState *is = global_video_state;
    int len1, audio_data_size;
    
    double pts;
    
    //    LOGE("SDL缓冲区的大小%d:\n", len);
    /*   len是由SDL传入的SDL缓冲区的大小，如果这个缓冲未满，我们就一直往里填充数据 */
    while (len > 0) {
        SDL_LockMutex(is->audio_mutex);
        while (is->quit) {
            NSLog(@"audio_callback is->quit == 1");
            SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
            if (is->quit == 1) {
                SDL_UnlockMutex(is->audio_mutex);
                SDL_PauseAudio(1);
                NSLog(@"audio_callback quit == 1");
                return;
            }
        }
        SDL_UnlockMutex(is->audio_mutex);
        //        LOGD("audio_callback called");
        /*  audio_buf_index 和 audio_buf_size 标示我们自己用来放置解码出来的数据的缓冲区，*/
        /*   这些数据待copy到SDL缓冲区， 当audio_buf_index >= audio_buf_size的时候意味着我*/
        /*   们的缓冲为空，没有数据可供copy，这时候需要调用audio_decode_frame来解码出更*/
        /*   多的桢数据 */
        
        if (is->audio_buf_index >= is->audio_buf_size) {
            // audio_data_size:表示解码后一帧字节大小
            audio_data_size = audio_decode_frame(is, &pts);
            SDL_LockMutex(is->audio_mutex);
            while (is->quit) {
                NSLog(@"audio_callback is->quit == 1");
                SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
                if (is->quit == 1) {
                    SDL_UnlockMutex(is->audio_mutex);
                    SDL_PauseAudio(1);
                    NSLog(@"audio_callback quit == 1");
                    return;
                }
            }
            SDL_UnlockMutex(is->audio_mutex);
            /* audio_data_size < 0 标示没能解码出数据，我们默认播放静音 */
            if (audio_data_size < 0 && is->audio_buf) {
                /* silence */
                is->audio_buf_size = 1024;
                /* 清零，静音 */
                if (is->audio_buf) memset(is->audio_buf, 0, is->audio_buf_size);
            } else {
                if (is->audio_buf)
                    audio_data_size = synchronize_audio(is, (int16_t *) is->audio_buf,
                                                        audio_data_size, pts);
                is->audio_buf_size = audio_data_size;
            }
            is->audio_buf_index = 0;
        }
        
        SDL_LockMutex(is->audio_mutex);
        while (is->quit) {
            NSLog(@"audio_callback is->quit == 1");
            SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
            if (is->quit == 1) {
                SDL_UnlockMutex(is->audio_mutex);
                SDL_PauseAudio(1);
                NSLog(@"audio_callback quit == 1");
                return;
            }
        }
        SDL_UnlockMutex(is->audio_mutex);
        if (is->audio_buf) {
            /*  查看stream可用空间，决定一次copy多少数据，剩下的下次继续copy */
            len1 = is->audio_buf_size - is->audio_buf_index;
            if (len1 > len) {
                len1 = len;
            }
            // void *memcpy(void *dest, const void *src, size_t n);
            if (is->audio_buf)
                memcpy(stream, (uint8_t *) is->audio_buf + is->audio_buf_index, len1);
            len -= len1;
            stream += len1;
            is->audio_buf_index += len1;
            NSLog(@"audio_callback is Over!!");
        } else {
            NSLog(@"is->audio_buf is NULL!!");
            break;
        }
    }// end while
    //SDL_UnlockAudio();
}

static Uint32 sdl_refresh_timer_cb(Uint32 interval, void *opaque) {
    SDL_Event event;
    event.type = FF_REFRESH_EVENT;
    event.user.data1 = opaque;
    SDL_PushEvent(&event);
    return 0;
}


static void schedule_refresh(VideoState *is, int delay) {
    SDL_LockMutex(is->audio_mutex);
    while (is->quit < 0 || is->quit > 0) {
        NSLog(@"schedule_refresh is->quit == 1");
        SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
        if (is->quit < 0 || is->quit > 0) {
            SDL_UnlockMutex(is->audio_mutex);
            return;
        }
    }
    SDL_UnlockMutex(is->audio_mutex);
    
    is->lastAddTimer = SDL_AddTimer(delay, sdl_refresh_timer_cb, is);
    NSLog(@"SDL_AddTimer:%ld", is->lastAddTimer);
}

//int decode_interrupt_cb(void *opaque) {
//    return (global_video_state && global_video_state->quit);
//}

void video_display(VideoState *is) {
    SDL_Rect rect, rect2;
    VideoPicture *vp;
    float aspect_ratio;
    
    vp = &is->pictq[is->pictq_rindex];
    if (vp->bmp) {
        if (is->video_st->codec->sample_aspect_ratio.num == 0) {
            aspect_ratio = 0;
        } else {
            aspect_ratio =
            (float) (av_q2d(is->video_st->codec->sample_aspect_ratio) *
                     is->video_st->codec->width /
                     is->video_st->codec->height);
        }
        
        if (aspect_ratio <= 0.0) {
            aspect_ratio = (float) is->video_st->codec->width / (float) is->video_st->codec->height;
        }
        
        rect.x = 100;
        rect.y = 100;
        rect.w = 640;
        rect.h = 480;
        
        // 第二个参数 param rect  A pointer to the rectangle of pixels to update, or NULL to update the entire texture.
        SDL_UpdateYUVTexture(vp->bmp, NULL, vp->rawdata->data[0],
                             vp->rawdata->linesize[0], vp->rawdata->data[1],
                             vp->rawdata->linesize[1], vp->rawdata->data[2],
                             vp->rawdata->linesize[2]);
        
        SDL_RenderClear(vp->renderer);
        // param srcrect   A pointer to the source rectangle, or NULL for the entire
        //                   texture.
        // param dstrect   A pointer to the destination rectangle, or NULL for the
        //                   entire rendering target.
        // SDL_RenderCopy(vp->renderer, vp->bmp, NULL, &rect);
        SDL_RenderCopy(vp->renderer, vp->bmp, NULL, NULL);
        SDL_RenderPresent(vp->renderer);
    }
}

void video_refresh_timer(void * userdata) {
    VideoState * is = global_video_state;
    VideoPicture * vp;
    double actual_delay, delay, sync_threshold, ref_clock, diff;
    
    SDL_LockMutex(is->audio_mutex);
    while (is->quit) {
        NSLog(@"video_refresh_timer is->quit == 1");
        SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
        if (is->quit) {
            NSLog(@"video_refresh_timer callback quit == 1");
            SDL_UnlockMutex(is->audio_mutex);
            return;
        }
    }
    SDL_UnlockMutex(is->audio_mutex);
    
    if (is->video_st && is->audio_st) {
        if (is->pictq_size == 0) {
            SDL_LockMutex(is->audio_mutex);
            while (is->quit) {
                NSLog(@"video_refresh_timer is->quit == 1");
                SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
                if (is->quit) {
                    NSLog(@"video_refresh_timer callback quit == 1");
                    SDL_UnlockMutex(is->audio_mutex);
                    return;
                }
            }
            SDL_UnlockMutex(is->audio_mutex);
            NSLog(@"schedule_refresh(is, 1)");
            schedule_refresh(is, 1);
        } else {
            if (is->paused) {
                SDL_Delay(10);
                NSLog(@"schedule_refresh(is, 100) 1");
                schedule_refresh(is, 100);
            } else {
                vp = &is->pictq[is->pictq_rindex];
                
                is->video_current_pts = vp->pts;
                is->video_current_pts_time = av_gettime();
                
                delay = vp->pts - is->frame_last_pts; /* the pts from last time */
                if (delay <= 0 || delay >= 1.0) {
                    /* if incorrect delay, use previous one */
                    delay = is->frame_last_delay;
                }
                /* save for next time */
                is->frame_last_delay = delay;
                is->frame_last_pts = vp->pts;
                
                /* update delay to sync to audio */
                //            ref_clock = get_audio_clock(is);
                //            diff = vp->pts - ref_clock;
                
                /* update delay to sync to audio if not master source */
                if (is->av_sync_type != AV_SYNC_VIDEO_MASTER) {
                    ref_clock = get_master_clock(is);
                    diff = vp->pts - ref_clock;
                    
                    /* Skip or repeat the frame. Take delay into account
                     FFPlay still doesn't "know if this is the best guess." */
                    sync_threshold =
                    (delay > AV_SYNC_THRESHOLD) ? delay : AV_SYNC_THRESHOLD;
                    if (fabs(diff) < AV_NOSYNC_THRESHOLD) {
                        if (diff <= -sync_threshold) {
                            delay = 0;
                        } else if (diff >= sync_threshold) {
                            delay = 2 * delay;
                        }
                    }
                }
                is->frame_timer += delay;
                /* computer the REAL delay */
                actual_delay = is->frame_timer - (av_gettime() / 1000000.0);
                if (actual_delay < 0.010) {
                    /* Really it should skip the picture instead */
                    actual_delay = 0.010;
                }
                // 时间戳打印
                
                NSLog(@"===>video clock:%f audio_clock:%f  actual_timer:%f  actual_delay:%d\n", vp->pts, ref_clock, is->frame_timer, (int) (actual_delay * 1000 + 0.5));
//                if (__offplayerSeekPos.delegate && [__offplayerSeekPos.delegate respondsToSelector:@selector(didTransSeekPos:)]) {
//                    //代理存在且有这个transButIndex:方法
//                    [__offplayerSeekPos.delegate didTransSeekPos:vp->pts];
//                }
                
                schedule_refresh(is, (int) (actual_delay * 1000 + 0.5));
                
                /* show the picture! */
                video_display(is);
                
                /* update queue for next picture! */
                if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE) {
                    is->pictq_rindex = 0;
                }
                SDL_LockMutex(is->pictq_mutex);
                is->pictq_size--;
                SDL_CondSignal(is->pictq_cond);
                SDL_UnlockMutex(is->pictq_mutex);
            }
        }
    } else {
        NSLog(@"schedule_refresh(is, 100) 2");
        schedule_refresh(is, 100);
    }
}

void alloc_picture(void *userdata) {
    VideoState *is = (VideoState *) userdata;
    VideoPicture *vp;
    
    NSLog(@"alloc_picture Start");
    vp = &is->pictq[is->pictq_windex];
    if (vp->bmp) {
        // we already have one make another, bigger/smaller
        SDL_DestroyTexture(vp->bmp);
    }
    
    if (vp->rawdata) {
        av_free(vp->rawdata);
    }
    
    // Allocate a place to put our YUV image on that screen
    vp->screen = SDL_CreateWindow("My Player Window", SDL_WINDOWPOS_UNDEFINED,
                                  SDL_WINDOWPOS_UNDEFINED, is->video_st->codec->width,
                                  is->video_st->codec->height,
                                  SDL_WINDOW_FULLSCREEN | SDL_WINDOW_OPENGL);
    
    vp->renderer = SDL_CreateRenderer(vp->screen, -1, 0);
    vp->bmp = SDL_CreateTexture(vp->renderer, SDL_PIXELFORMAT_YV12,
                                SDL_TEXTUREACCESS_STREAMING, is->video_st->codec->width,
                                is->video_st->codec->height);
    
    vp->width = is->video_st->codec->width;
    vp->height = is->video_st->codec->height;
    NSLog(@"VideoPicture width::%d  height::%d ", vp->width, vp->height);
    
    AVFrame *pFrameYUV = av_frame_alloc();
    if (pFrameYUV == NULL)
        return;
    
    int numBytes = avpicture_get_size(AV_PIX_FMT_YUVJ420P, vp->width, vp->height);
    uint8_t *buffer = (uint8_t *) av_malloc(numBytes * sizeof(uint8_t));
    
    avpicture_fill((AVPicture *) pFrameYUV, buffer, AV_PIX_FMT_YUVJ420P, vp->width, vp->height);
    
    vp->rawdata = pFrameYUV;
    
    SDL_LockMutex(is->pictq_mutex);
    vp->allocated = 1;
    SDL_CondSignal(is->pictq_cond);
    SDL_UnlockMutex(is->pictq_mutex);
}

int queue_picture(VideoState *is, AVFrame *pFrame, double pts) {
    VideoPicture *vp;
    //int dst_pic_fmt
    AVPicture pict;
    
    /* wait unitl we have space for a new pic */
    SDL_LockMutex(is->pictq_mutex);
    while (is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE) {
        //LOGD("queue_picture is->pictq_size:%d, VIDEO_PICTURE_QUEUE_SIZE:%d ", is->pictq_size, VIDEO_PICTURE_QUEUE_SIZE);
        SDL_CondWaitTimeout(is->pictq_cond, is->pictq_mutex, 10);
        if (is->quit) {
            SDL_UnlockMutex(is->pictq_mutex);
            NSLog(@"queue_picture quit == 1");
            break;
        }
    }
    SDL_UnlockMutex(is->pictq_mutex);
    
    //    if (is->quit){
    //        LOGD("queue_picture1 is->quit == 1");
    //        return -1;
    //    }
    
    // windex is set to 0 initially
    vp = &is->pictq[is->pictq_windex];
    
    /* allocate or resize the buffer ! */
    if (vp->allocated ==
        0 /*|| vp->width != is->video_st->codec->width || vp->height != is->video_st->codec->height*/) {
        SDL_Event event;
        
        vp->allocated = 0;
        /* we have to do it in the main thread */
        event.type = FF_ALLOC_EVENT;
        event.user.data1 = is;
        SDL_PushEvent(&event);
        
        /* wait until we have a picture allocated */
        SDL_LockMutex(is->pictq_mutex);
        while (!vp->allocated) {
            SDL_CondWait(is->pictq_cond, is->pictq_mutex);
        }
        SDL_UnlockMutex(is->pictq_mutex);
    }
    
    /* We have a place to put our picture on the queue */
    if (vp->rawdata) {
        // Convert the image into YUV format that SDL uses
        sws_scale(is->sws_ctx, (uint8_t const *const *) pFrame->data,
                  pFrame->linesize, 0, is->video_st->codec->height,
                  vp->rawdata->data, vp->rawdata->linesize);
        
        vp->pts = pts;
        
        /* now we inform our display thread that we have a pic ready */
        if (++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE) {
            is->pictq_windex = 0;
        }
        SDL_LockMutex(is->pictq_mutex);
        is->pictq_size++;
        SDL_UnlockMutex(is->pictq_mutex);
    }
    return 0;
}

double synchronize_video(VideoState *is, AVFrame *src_frame, double pts) {
    
    double frame_delay;
    
    if (pts != 0) {
        /* if we have pts, set video clock to it */
        is->video_clock = pts;
    } else {
        /* if we aren't given a pts, set it to the clock */
        pts = is->video_clock;
    }
    /* update the video clock */
    frame_delay = av_q2d(is->video_st->codec->time_base);
    /* if we are repeating a frame, adjust clock accordingly */
    frame_delay += src_frame->repeat_pict * (frame_delay * 0.5);
    is->video_clock += frame_delay;
    return pts;
}

void read_thread_failed(VideoState *is, AVFormatContext *ic, SDL_mutex *wait_mutex) {
    if (ic && !is->ic) {
        avformat_close_input(&ic);
    }
    SDL_DestroyMutex(wait_mutex);
}

int VideoStateInit_ffmpeg(VideoState *is) {
    is->ic = NULL;
    is->videoStream = -1;
    is->audioStream = -1;
    is->audio_st = NULL;
    is->audio_frame = NULL;
    is->audio_buf_size = 0;
    is->audio_buf_index = 0;
    is->audio_pkt_data = NULL;
    is->audio_pkt_size = 0;
    is->audio_buf = NULL;
    is->audio_src_channels = -1;
    is->audio_tgt_channels = -1;
    is->audio_src_channel_layout = 0;
    is->audio_tgt_channel_layout = 0;
    is->audio_src_freq = 0;
    is->audio_tgt_freq = 0;
    is->swr_ctx = NULL;                     // audio 重采样转换器
    is->video_st = NULL;
    is->pictq_size = 0;
    is->pictq_mutex = NULL;
    is->pictq_cond = NULL;
    is->audio_mutex = NULL;
    is->audio_cond = NULL;
    is->parse_tid = NULL;
    is->audio_tid = NULL;
    is->video_tid = NULL;
    is->io_ctx = NULL;
    is->sws_ctx = NULL;// video 格式转换器
    is->audio_clock = 0;
    is->external_clock = 0;/*external clock base*/
    is->external_clock_time = 0;
    is->audio_hw_buf_size = 0;
    is->audio_diff_cum = 0;/*used of AV difference average computation*/
    is->audio_diff_avg_coef = 0;
    is->audio_diff_threshold = 0;
    is->audio_diff_avg_count = 0;
    is->frame_timer = 0;
    is->frame_last_pts = 0;
    is->frame_last_delay = 0;
    is->video_current_pts = 0; ///<current displayed pts (different from video_clock if frame fifos are used)
    is->video_current_pts_time = 0; ///<time (av_gettime) at which we updated video_current_pts - used to have running video pts
    is->video_clock = 0; ///<pts of last decoded frame / predicted pts of next decoded frame
    is->seek_req = 0;
    is->seek_pos = 0;
    is->seek_rel = -1;
    is->seek_flags = -1;
    is->duration = -1;
    is->totalTimes = -1;
    is->audio_codec_ctx = NULL;
    is->video_codec_ctx = NULL;
}

void VideoStateInit_SDL(VideoState *is) {
    is->pictq_rindex = 0;
    is->pictq_windex = 0;
    is->quit = -2;
    is->paused = 0;
    is->backed = 0;
    is->continue_read_thread = NULL;
    is->av_sync_type = 0;
    VideoPicture *vp = &is->pictq[is->pictq_windex];
    {
        vp->pts = 0;
        vp->allocated = 0;
        vp->bmp = NULL;
        vp->height = -1;
        vp->rawdata = NULL;
        vp->renderer = NULL;
        vp->screen = NULL;
        vp->width = 0;
    }
}

/* pause or resume the video */
void stream_toggle_pause(VideoState *is) {
    is->frame_timer = (double) av_gettime() / 1000000.0;
    is->paused = !is->paused;
}

void frame_queue_unref_item(VideoPicture *vp) {
    av_frame_unref(vp->rawdata);
}

void free_picture(VideoPicture *vp) {
    if (vp->bmp) {
        SDL_DestroyTexture(vp->bmp);
        vp->bmp = NULL;
    }
}

void frame_queue_destory(VideoState *is) {
    for (int i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++) {
        VideoPicture *vp = &is->pictq[i];
        vp->allocated = 0;
        if (vp->renderer) {
            SDL_DestroyRenderer(vp->renderer);
            vp->renderer = NULL;
        }
        if (vp->screen) {
            SDL_DestroyWindow(vp->screen);
            vp->screen = NULL;
        }
        frame_queue_unref_item(vp);
        av_frame_free(&vp->rawdata);
        free_picture(vp);
    }
    //    SDL_DestroyMutex(is->pictq_mutex);
    //    SDL_DestroyCond(is->pictq_cond);
}

void packet_queue_destroy(PacketQueue *q) {
    packet_queue_flush(q);
    SDL_DestroyMutex(q->mutex);
    SDL_DestroyCond(q->cond);
}

void packet_queue_abort(PacketQueue *q) {
    SDL_LockMutex(q->mutex);
    SDL_CondSignal(q->cond);
    SDL_UnlockMutex(q->mutex);
}

// decode_thread
// audio --> is->audioq  -->    SDL audio_callback <decode And play>
// video_thread
// video --> is->videoq  -->    decode --> queue_picture()      -->  SDL video_refresh_timer()  <play>
void audio_abort(VideoState *is) {
    NSLog(@"==> audio_abort and flush 1");
    //packet_queue_abort(&is->audioq);
    packet_queue_flush(&is->audioq);
    NSLog(@"==> audio_abort and flush 2");
}

void video_abort(VideoState *is) {
    packet_queue_flush(&is->videoq);
}

void audio_decoder_destroy(VideoState *is) {
    NSLog(@"==> audio_decoder_destroy 1");
    //av_packet_unref(&is->audio_pkt);
    avcodec_close(is->audio_codec_ctx);
    is->audio_codec_ctx = NULL;
    
}


void video_decoder_destroy(VideoState *is) {
    //    av_packet_unref(&is->video_pkt);
    avcodec_close(is->video_codec_ctx);
    is->video_codec_ctx = NULL;
}

void stream_component_close(VideoState *is, int stream_index) {
    AVFormatContext *ic = is->ic;
    AVCodecContext *avctx;
    
    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return;
    avctx = ic->streams[stream_index]->codec;
    
    switch (avctx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            audio_abort(is);
            //SDL_CloseAudioDevice()
            audio_decoder_destroy(is);
            NSLog(@"====>3");
            swr_free(&is->swr_ctx);
            NSLog(@"====>4");
            //在音频时钟情况下无必要
            if(is->audio_buf){
                av_free(is->audio_buf);
                is->audio_buf = NULL;
            }
            is->audio_pkt_size = 0;
            is->audio_buf_size = 0;
            
            //            av_free(&is->audio_buf);
            //            is->audio_pkt_size = 0;
            //            is->audio_buf_size = 0;
            //            is->audio_buf = NULL;
            NSLog(@"====>5");
            
            break;
        case AVMEDIA_TYPE_VIDEO:
            NSLog(@"====>6");
            video_abort(is);
            NSLog(@"====>7");
            video_decoder_destroy(is);
            NSLog(@"====>8");
            break;
        default:
            break;
    }
}

void ffmpeg_close(VideoState *is) {
    if (is && is->quit != 0)
        return;
    
    SDL_LockMutex(is->audio_mutex);
    NSLog(@"===>退出 标志位quit = 1\n");
    is->quit = 1;
    SDL_CondSignal(is->audio_cond);
    SDL_UnlockMutex(is->audio_mutex);
    
    SDL_WaitThread(is->parse_tid, NULL);
    is->parse_tid = NULL;
    NSLog(@"close parse thread\n");
    
    SDL_WaitThread(is->video_tid, NULL);
    is->video_tid = NULL;
    NSLog(@"close video thread\n");
    
    NSLog(@"===sdl quit SDL_CloseAudio begin");
    AVPacket pktAudio;
    uint8_t data[1024] = {0};
    av_init_packet(&pktAudio);
    pktAudio.data = data;
    pktAudio.size = 1024;
    packet_queue_put(&is->audioq, &pktAudio);
    SDL_CloseAudio();
    NSLog(@"===sdl quit SDL_CloseAudio end");
    
    //destroy_avQueue(is);
    if (is->audioStream >= 0) {
        stream_component_close(is, is->audioStream);
        NSLog(@"audioq flush and audio decoder destroy");
        
    }
    if (is->videoStream >= 0) {
        stream_component_close(is, is->videoStream);
        NSLog(@"videoq flush and video decoder destroy\n");
        
    }
    
    avformat_close_input(&is->ic);
    sws_freeContext(is->sws_ctx);
    
    packet_queue_abort(&is->videoq);
    packet_queue_abort(&is->audioq);
    packet_queue_destroy(&is->videoq);
    packet_queue_destroy(&is->audioq);
    NSLog(@"===videoq and audioq has destroyed\n");
}



void sdl_close(VideoState *is) {
    /* free all pictures */
    frame_queue_destory(is);
    NSLog(@"picture queue destroyed");
    
    SDL_RemoveTimer(is->lastAddTimer);
    NSLog(@"SDL_RemoveTimer:%ld", is->lastAddTimer);
    
    SDL_LockMutex(is->audio_mutex);
    is->quit = -2;
    SDL_CondSignal(is->audio_cond);
    SDL_UnlockMutex(is->audio_mutex);
    
}

VideoState *global_video_state_create() {
    VideoState *is;
    is = (VideoState *)av_malloc(sizeof(VideoState));
    VideoStateInit_ffmpeg(is);
    VideoStateInit_SDL(is);
    
    is->pictq_mutex = SDL_CreateMutex();
    is->pictq_cond = SDL_CreateCond();
    is->audio_mutex = SDL_CreateMutex();
    is->audio_cond = SDL_CreateCond();
    is->quit = -2;
    
    return is;
}

int global_video_state_destory() {
    if (global_video_state) {
        SDL_DestroyMutex(global_video_state->pictq_mutex);
        SDL_DestroyCond(global_video_state->pictq_cond);
        SDL_DestroyMutex(global_video_state->audio_mutex);
        SDL_DestroyCond(global_video_state->audio_cond);
        av_free(global_video_state);
        global_video_state = NULL;
    }
}

int ffmpeg_open(const char *file_path) {
    av_register_all();
    avformat_network_init();
    
    VideoState *is = global_video_state;
    int video_index = -1;
    int audio_index = -1;
    int i = -1;
    AVCodecContext *codecCtx;
    AVCodec *codec;
    AVFormatContext *pFormatCtx = NULL;
    
    av_strlcpy(is->filename, file_path, sizeof(is->filename));
    //Open video file
    if (avformat_open_input(&pFormatCtx, is->filename, NULL, NULL) != 0) {
        NSLog(@"Couldn't open file %s\n", is->filename);
        return -1;
    }
    
    is->ic = pFormatCtx;
    
    if (avformat_find_stream_info(is->ic, NULL) < 0) {
        NSLog(@"avformat_find_stream_info is Failed!\n");
        return -1; // Couldn't find stream information
    }
    
    //Dump information about file onto standard error
    av_dump_format(is->ic, 0, is->filename, 0);
    is->duration = is->ic->duration;
    is->videoStream = -1;
    is->audioStream = -1;
    
    //Find the first video stream
    for (i = 0; i < is->ic->nb_streams; i++) {
        if (is->ic->streams[i]->codec->coder_type == AVMEDIA_TYPE_VIDEO && video_index < 0) {
            video_index = i;
        }
        
        if (is->ic->streams[i]->codec->codec_type == AVMEDIA_TYPE_AUDIO && audio_index < 0) {
            audio_index = i;
        }
    }
    
    is->videoStream = video_index;
    is->audioStream = audio_index;
    
    // init flush_pkt
    av_init_packet(&(is->flush_pkt));
    is->flush_pkt.data = (uint8_t *) &(is->flush_pkt);
    
    AVPacket pkt1, *packet = &pkt1;
    int ret;
    int64_t seek_conv_target = -1;
    SDL_mutex *wait_mutex = SDL_CreateMutex();
    if (!wait_mutex) {
        NSLog(@"Read Thread SDL_CreateMutex(): %s\n", SDL_GetError());
        read_thread_failed(is, NULL, wait_mutex);
        return -1;
    }
    
    is->duration = -1;
    if (is->audioStream >= 0) {
        /* 所有设置SDL音频流信息的步骤都在这个函数里完成 */
        //audio_stream_component_open(is, is->audioStream);
        
        is->audio_codec_ctx = is->ic->streams[is->audioStream]->codec;
        is->audio_buf = (uint8_t *) av_malloc(sizeof(uint8_t *) * 1024);
        is->audio_src_fmt = is->audio_tgt_fmt = AV_SAMPLE_FMT_S16;
        codec = avcodec_find_decoder(is->audio_codec_ctx->codec_id);
        if (!codec || (avcodec_open2(is->audio_codec_ctx, codec, NULL) < 0)) {
            fprintf(stderr, "Unsupported codec!\n");
            return -1;
        }
        
        is->ic->streams[is->audioStream]->discard = AVDISCARD_DEFAULT;
        is->audio_st = is->ic->streams[is->audioStream];
        is->audio_buf_size = 0;
        is->audio_buf_index = 0;
        
        /* averaging filter for audio sync */
        is->audio_diff_avg_coef = exp(log(0.01 / AUDIO_DIFF_AVG_NB));
        is->audio_diff_avg_count = 0;
        /* Correct audio only if larger error than this */
        is->audio_diff_threshold = 2.0 * SDL_AUDIO_BUFFER_SIZE / is->audio_codec_ctx->sample_rate;
        
        memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
        packet_queue_init(&is->audioq);
    }
    
    if (is->videoStream >= 0) {
        //video_stream_component_open(is, is->videoStream);
        
        // Get a pointer to the codec context for the video stream
        is->video_codec_ctx = pFormatCtx->streams[is->videoStream]->codec;
        // 声明到VideoState中
        codec = avcodec_find_decoder(is->video_codec_ctx->codec_id);
        if (!codec || (avcodec_open2(is->video_codec_ctx, codec, NULL) < 0)) {
            fprintf(stderr, "Unsupported codec!\n");
            return -1;
        }
        
        is->video_st = pFormatCtx->streams[is->videoStream];
        // 初始化像素格式转换上下文
        is->sws_ctx = sws_getContext(is->video_st->codec->width, is->video_st->codec->height,
                                     is->video_st->codec->pix_fmt,
                                     is->video_st->codec->width, is->video_st->codec->height,
                                     AV_PIX_FMT_YUVJ420P,
                                     SWS_FAST_BILINEAR, NULL, NULL, NULL);
        
        is->frame_timer = (double) av_gettime() / 1000000.0;
        is->frame_last_delay = 40e-3;
        is->video_current_pts_time = av_gettime();
        packet_queue_init(&is->videoq);
    }
    
    if (is->videoStream < 0 || is->audioStream <= 0) {
        fprintf(stderr, "%s: could not open codec\n", is->filename);
        return -1;
    }
    is->duration = is->ic->duration;
    
    SDL_LockMutex(is->audio_mutex);
    is->quit = -1;
    SDL_CondSignal(is->audio_cond);
    SDL_UnlockMutex(is->audio_mutex);
    
    NSLog(@"ffmpeg_open is Finish");
    return 0;
}

int sdl_open(VideoState *is, int isInThread) {
    SDL_Event event;
    SDL_AudioSpec wanted_spec, spec;
    int64_t wanted_channel_layout = 0;
    int wanted_nb_channels;
    /*  SDL支持的声道数为 1, 2, 4, 6 */
    /*  后面我们会使用这个数组来纠正不支持的声道数目 */
    const int next_nb_channels[] = {0, 0, 1, 6, 2, 6, 4, 6};
    AVCodecContext *codecCtx = NULL;
    AVCodec *codec = NULL;
    VideoPicture *vp = NULL;
    
    //    SDL_LockMutex(is->audio_mutex);
    //    while (is->quit == -2) {
    //        LOGE("===sdl_open is->quit = -2 ,then wait \n");
    //        SDL_CondWait(is->audio_cond, is->audio_mutex);
    //    }
    //    SDL_UnlockMutex(is->audio_mutex);
    
    SDL_Quit();
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER)) {
        NSLog(@"Could not initialize SDL - %s\n", SDL_GetError());
        exit(1);
    }
    
    is->av_sync_type = DEFAULT_AV_SYNC_TYPE;
    
    // create the SDL condition variable(条件变量)
    if (!(is->continue_read_thread = SDL_CreateCond())) {
        NSLog(@"Thread SDL_CreateCond(): %s\n", SDL_GetError());
        // stream_close(is);
        return -1;
    }
    
    if (is->audioStream >= 0 && is->quit == -1) {
        /* 所有设置SDL音频流信息的步骤都在这个函数里完成 */
        //audio_stream_component_open(is, is->audioStream);
        
        codecCtx = is->ic->streams[is->audioStream]->codec;
        wanted_nb_channels = codecCtx->channels;
        if (!wanted_channel_layout ||
            wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
            wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
            wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
        }
        
        wanted_spec.channels = av_get_channel_layout_nb_channels(wanted_channel_layout);
        wanted_spec.freq = codecCtx->sample_rate;
        if (wanted_spec.freq <= 0 || wanted_spec.channels <= 0) {
            fprintf(stderr, "Invalid sample rate or channel count!\n");
            return -1;
        }
        
        wanted_spec.format = AUDIO_S16SYS; // 具体含义请查看“SDL宏定义”部分
        wanted_spec.silence = 0;            // 0指示静音
        wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;  // 自定义SDL缓冲区大小
        wanted_spec.callback = audio_callback;        // 音频解码的关键回调函数
        wanted_spec.userdata = is;                    // 传给上面回调函数的外带数据
        
        /*  打开音频设备，这里使用一个while来循环尝试打开不同的声道数(由上面 */
        /*  next_nb_channels数组指定）直到成功打开，或者全部失败 */
        while (SDL_OpenAudio(&wanted_spec, &spec) < 0) {
            NSLog(@"SDL_OpenAudio (%d channels): %s\n", wanted_spec.channels, SDL_GetError());
            wanted_spec.channels = next_nb_channels[FFMIN(7, wanted_spec.channels)];
            if (!wanted_spec.channels) {
                NSLog(@"No more channel combinations to tyu, audio open failed\n");
                return -1;
            }
            wanted_channel_layout = av_get_default_channel_layout(wanted_spec.channels);
        }
        
        /* 检查实际使用的配置（保存在spec,由SDL_OpenAudio()填充） */
        if (spec.format != AUDIO_S16SYS) {
            NSLog(@"SDL advised audio format %d is not supported!\n", spec.format);
            return -1;
        }
        
        if (spec.channels != wanted_spec.channels) {
            wanted_channel_layout = av_get_default_channel_layout(spec.channels);
            if (!wanted_channel_layout) {
                NSLog(@"SDL advised channel count %d is not supported!\n", spec.channels);
                return -1;
            }
        }
        
        //hw SDL hardware buffer size
        is->audio_hw_buf_size = spec.size;
        
        /* 把设置好的参数保存到大结构中 */
        is->audio_src_freq = is->audio_tgt_freq = spec.freq;
        is->audio_src_channel_layout = is->audio_tgt_channel_layout = wanted_channel_layout;
        is->audio_src_channels = is->audio_tgt_channels = spec.channels;
        SDL_PauseAudio(0); // 开始播放静音
    }
    
    if (is->videoStream >= 0 && is->quit == -1) {
        //video_stream_component_open(is, is->videoStream);
        if (!isInThread){
            NSLog(@"to alloc_picture 1");
            alloc_picture(is);
        } else {
            NSLog(@"to alloc_picture 2");
            vp->allocated = 0;
            /* we have to do it in the main thread */
            event.type = FF_ALLOC_EVENT;
            event.user.data1 = is;
            SDL_PushEvent(&event);
            
            /* wait until we have a picture allocated */
            SDL_LockMutex(is->pictq_mutex);
            while (!vp->allocated) {
                SDL_CondWait(is->pictq_cond, is->pictq_mutex);
            }
            SDL_UnlockMutex(is->pictq_mutex);
        }
    }
    
    SDL_LockMutex(is->audio_mutex);
    is->quit = -1;
    SDL_CondSignal(is->audio_cond);
    SDL_UnlockMutex(is->audio_mutex);
    return 0;
}

int decode_new_thread(void *args) {
    
    VideoState *is = global_video_state;
    //    AVFormatContext *pFormatCtx = NULL;
    AVPacket pkt1, *packet = &pkt1;
    int ret;
    int64_t seek_conv_target = -1;
    SDL_mutex *wait_mutex = SDL_CreateMutex();
    if (!wait_mutex) {
        NSLog(@"Read Thread SDL_CreateMutex(): %s\n", SDL_GetError());
        read_thread_failed(is, NULL, wait_mutex);
        return -1;
    }
    
    if (is->quit) {
        SDL_LockMutex(is->audio_mutex);
        is->quit = 0;
        SDL_CondSignal(is->audio_cond);
        SDL_UnlockMutex(is->audio_mutex);
    }
    schedule_refresh(is, 1);
    
    NSLog(@"totalTimes: %lf\n", is->totalTimes);//03：23
    //main decode loop
    /* 读包的主循环， av_read_frame不停的从文件中读取数据包*/
    
    for (;;) {
        SDL_LockMutex(is->audio_mutex);
        while (is->quit) {
            NSLog(@"decode_thread is->quit == 1");
            SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
            if (is->quit == 1) {
                SDL_UnlockMutex(is->audio_mutex);
                NSLog(@"decode_thread audio_callback quit == 1");
                goto fail;
            }
        }
        SDL_UnlockMutex(is->audio_mutex);
        
        if (is->paused) {
            SDL_Delay(10);
            continue;
        }
        
        
        //seek stuff goes here
        if (is->seek_req) {
            int64_t seek_target = is->seek_pos;
            int64_t seek_min = is->seek_rel > 0 ? seek_target - is->seek_rel + 2 : INT64_MIN;
            int64_t seek_max = is->seek_rel > 0 ? seek_target - is->seek_rel - 2 : INT64_MAX;
            
            // FIXME the +-2 is due to rounding being not done in the correct direction in generation of the seek_pos/seek_rel variables
            //             ret = avformat_seek_file(is->ic, -1, seek_min, seek_target, seek_max, is->seek_flags);
            ret = avformat_seek_file(is->ic, -1, seek_min, seek_target, seek_max, is->seek_flags);
            //seek_conv_target = av_rescale_q((int64_t) seek_target, AV_TIME_BASE_Q,is->video_codec_ctx->time_base);
            NSLog(@"src seek_target:%lld  src time_base:%d \n", seek_target, AV_TIME_BASE);
            NSLog(@"target seek_target:%lld  target time_base:%d \n", seek_conv_target, is->video_codec_ctx->time_base.den / is->video_codec_ctx->time_base.num);
            
            // ret = avformat_seek_file(is->ic, video_index, seek_min, seek_conv_target, seek_max, AVSEEK_FLAG_BACKWARD);
            if (ret < 0) {
                NSLog(@"%s: error while seeking\n", is->filename);
            } else {
                NSLog(@"seeking flush queue \n");
                if (is->audioStream >= 0) {
                    packet_queue_flush(&is->audioq);
                    packet_queue_put(&is->audioq, &is->flush_pkt);
                }
                if (is->videoStream >= 0) {
                    packet_queue_flush(&is->videoq);
                    packet_queue_put(&is->videoq, &is->flush_pkt);
                }
                NSLog(@"audio_queue size:: %d,video_queue size%d\n", is->audioq.nb_packets, is->videoq.nb_packets);
            }
            is->seek_req = 0;
        }
        
        /* 这里audioq.size是指队列中的所有数据包带的音频数据的总量或者视频数据总量，并不是包的数量 */
        if (is->audioq.size > MAX_AUDIOQ_SIZE || is->videoq.size > MAX_VIDEOQ_SIZE) {
            /* wait 10 ms */
            SDL_Delay(10);
            continue;
        }
        
        if (av_read_frame(is->ic, packet) < 0) {
            if (is->videoq.size > 0 || is->audioq.size > 0) {
                SDL_Delay(100); /* no error; wait for user input */
                continue;
            } else {
                // FIXME 解决文件播放接收后
                is->frame_timer = (double) av_gettime() / 1000000.0;
                SDL_Delay(10);
                continue;
            }
        }
        
        // Is this a packet from the video stream?
        if (packet->stream_index == is->videoStream) {
            packet_queue_put(&is->videoq, packet);
        } else if (packet->stream_index == is->audioStream) {
            packet_queue_put(&is->audioq, packet);
        } else {
            av_free_packet(packet);
        }
    }
    
fail:
    NSLog(@" parse thread end 发送FF_QUIT_EVENT消息\n");
    if (1) {
        SDL_Event event;
        event.type = FF_QUIT_EVENT;
        event.user.data1 = is;
        SDL_PushEvent(&event);
    }
    return 0;
}

int video_new_thread(void *args) {
    VideoState *is = global_video_state;
    AVPacket pkt1, *packet = &pkt1;
    int frameFinished;
    AVFrame *pFrame = NULL;
    double pts = 0;
    
    pFrame = av_frame_alloc();
    
    for (;;) {
        NSLog(@"video_thread Loop");
        SDL_LockMutex(is->audio_mutex);
        while (is->quit) {
            NSLog(@"video_thread is->quit == 1");
            SDL_CondWaitTimeout(is->audio_cond, is->audio_mutex, 10);
            if (is->quit == 1) {
                SDL_UnlockMutex(is->audio_mutex);
                NSLog(@"video_thread quit == 1");
                goto ErrLab;
            }
        }
        SDL_UnlockMutex(is->audio_mutex);
        
        if (packet_queue_get(&is->videoq, packet, 0) < 0) {
            // means we quit getting packets
            NSLog(@"avcodec_flush_buffers break!");
            break;
        }
        if (packet->data == is->flush_pkt.data) {
            NSLog(@"Seek 操作 avcodec_flush_buffers continue!");
            avcodec_flush_buffers(is->video_st->codec);
            continue;
        }
        pts = 0;
        
        // Save global pts to be stored in pFrame in first call
        global_video_pkt_pts = (uint64_t) packet->pts;
        
        // Decode video frame
        avcodec_decode_video2(is->video_st->codec, pFrame, &frameFinished, packet);
        
        if (packet->dts == AV_NOPTS_VALUE && pFrame->opaque
            && *(uint64_t *) pFrame->opaque != AV_NOPTS_VALUE) {
            pts = *(uint64_t *) pFrame->opaque;
        } else if (packet->dts != AV_NOPTS_VALUE) {
            pts = packet->dts;
        } else {
            pts = 0;
        }
        pts *= av_q2d(is->video_st->time_base);
        
        // Did we get a video frame?
        if (frameFinished) {
            pts = synchronize_video(is, pFrame, pts);
            if (queue_picture(is, pFrame, pts) < 0) {
                break;
            }
        }
        av_free_packet(packet);
    }
    
ErrLab:
    NSLog(@"video_thread Over!");
    av_free(pFrame);
    return 0;
}

void sdl_loop(VideoState *is) {
    SDL_Event event;
    AVPacket pktAudio;
    uint8_t data[1024] = {0};
    SDL_threadID video_tid = -1;
    int ret = -1;
    
    is->parse_tid = SDL_CreateThread(decode_new_thread, NULL, is);
    SDL_threadID parse_tid = SDL_GetThreadID(is->parse_tid);
    NSLog(@"parse_tid:: %lu \n", parse_tid);
    if (!is->parse_tid) {
        goto ErrLab;
    }
    
    is->video_tid = SDL_CreateThread(video_new_thread, NULL, is);
    video_tid = SDL_GetThreadID(is->video_tid);
    NSLog(@"video_tid::%lu\n", video_tid);
    if (!is->video_tid) {
        goto ErrLab;
    }
    
    for (;;) {
        ret = SDL_WaitEvent(&event);
        NSLog(@"sdl_loop ret:%d",ret);
        is->event = event.type;
        switch (event.type) {
            case FF_QUIT_EVENT:
                NSLog(@"init_play Over!");
                goto ErrLab;
            case FF_ALLOC_EVENT:
                NSLog(@"FF_ALLOC_EVENT Start!");
                alloc_picture(event.user.data1);
                NSLog(@"FF_ALLOC_EVENT Over!");
                break;
            case FF_REFRESH_EVENT:
                video_refresh_timer(event.user.data1);
                break;
            default:
                break;
        }
    }
    
ErrLab:
    return;
}

int stream_GetCurrentPosition() {
    if (global_video_state)
        return (int) (global_video_state->audio_clock * 1000);
    else
        return -1;
}

int64_t stream_GetDuration() {
    if (global_video_state)
        return global_video_state->duration;
    else
        return -1;
}

void stream_seek(int64_t pos, int64_t rel, int seek_by_bytes) {
    VideoState *is = global_video_state;
    is->seek_pos = pos;
    is->seek_rel = rel;
    is->seek_flags &= ~AVSEEK_FLAG_BYTE;
    if (seek_by_bytes) {
        is->seek_flags |= AVSEEK_FLAG_BYTE;
    }
    is->seek_req = 1;
    NSLog(@"===1 when stream_seek signal continue_read_thread\n");
    return;
}
    
void stream_pause() {
    stream_toggle_pause(global_video_state);
}

void stream_play(const char *inPath) {
    global_video_state = global_video_state_create();
    ffmpeg_open(inPath);
    sdl_open(global_video_state, 0);
    sdl_loop(global_video_state);
    return;
}
    
void stream_close() {
    ffmpeg_close(global_video_state);
    sdl_close(global_video_state);
    global_video_state_destory();
}
    
int main(int argc, char *argv[]) {
//    ffplayerSeekPos *obj = [ffplayerSeekPos init];
//    [obj.delegate transSeekPos:1];
    //NSString *documentsDirectory = [NSString stringWithFormat:@"%@/Documents/20171120113508.flv", NSHomeDirectory()];
    NSString *documentsDirectory = [NSString stringWithFormat:@"http://leyu-dev-livestorage.b0.upaiyun.com/leyulive.pull.dev.iemylife.com/leyu/0091e94cd8254dd7af7f2b347d91b8fa/recorder20171115100710.mp4"];
    stream_play([documentsDirectory UTF8String]);
    return 0;
}

#ifdef __cplusplus
}
#endif
