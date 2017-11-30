//
//  ffplayer_android.h
//  Rectangles
//
//  Created by huangjunren on 2017/11/29.
//

#ifndef ffplayer_android_h
#define ffplayer_android_h

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include "SDL.h"
#include <libavutil/avstring.h>
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libavutil/samplefmt.h"
#include "libswresample/swresample.h"
#include "SDL.h"
#include "SDL_thread.h"
#include "SDL_events.h"
#include "libavutil/pixfmt.h"

#define SDL_AUDIO_BUFFER_SIZE 1024

#define MAX_AUDIOQ_SIZE (5 * 16 * 1024)
#define MAX_VIDEOQ_SIZE (5 * 256 * 1024)

#define AV_SYNC_THRESHOLD 0.01
#define AV_NOSYNC_THRESHOLD 10.0

#define SAMPLE_CORRECTION_PERCENT_MAX 10
#define AUDIO_DIFF_AVG_NB 20

#define FF_ALLOC_EVENT   (SDL_USEREVENT)
#define FF_REFRESH_EVENT (SDL_USEREVENT + 1)
#define FF_QUIT_EVENT (SDL_USEREVENT + 2)

#define VIDEO_PICTURE_QUEUE_SIZE 1

#define DEFAULT_AV_SYNC_TYPE AV_SYNC_AUDIO_MASTER
#define AVCODEC_MAX_AUDIO_FRAME_SIZE 192000 // 1 second of 48khz 32bit audio

typedef struct PacketQueue {
    AVPacketList *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    SDL_mutex *mutex;
    SDL_cond *cond;
} PacketQueue;

typedef struct VideoPicture {
    SDL_Window *screen;
    SDL_Renderer *renderer;
    SDL_Texture *bmp;
    
    AVFrame* rawdata;
    int width, height; /*source height & width*/
    int allocated;
    double pts;
} VideoPicture;

typedef struct VideoState {
    char filename[1024];
    AVFormatContext *ic;
    int videoStream, audioStream;
    AVStream *audio_st;
    AVFrame *audio_frame;
    PacketQueue audioq;
    unsigned int audio_buf_size;
    unsigned int audio_buf_index;
    AVPacket audio_pkt;
    uint8_t *audio_pkt_data;
    int audio_pkt_size;
    uint8_t *audio_buf;
    DECLARE_ALIGNED(16,uint8_t,audio_buf2) [AVCODEC_MAX_AUDIO_FRAME_SIZE * 4];
    enum AVSampleFormat audio_src_fmt;
    enum AVSampleFormat audio_tgt_fmt;
    int audio_src_channels;
    int audio_tgt_channels;
    int64_t audio_src_channel_layout;
    int64_t audio_tgt_channel_layout;
    int audio_src_freq;
    int audio_tgt_freq;
    struct SwrContext *swr_ctx;                     
    
    AVStream *video_st;
    PacketQueue videoq;
    
    // Video FrameQueue
    VideoPicture pictq[VIDEO_PICTURE_QUEUE_SIZE];
    int pictq_size, pictq_rindex, pictq_windex;
    SDL_mutex *pictq_mutex;
    SDL_cond *pictq_cond;
    
    SDL_mutex *audio_mutex;
    SDL_cond *audio_cond;
    
    SDL_mutex *recv_mutex;
    SDL_cond *recv_cond;
    
    SDL_Thread *parse_tid;
    SDL_Thread *audio_tid;
    SDL_Thread *video_tid;
    
    AVIOContext *io_ctx;
    struct SwsContext *sws_ctx;
    
    double audio_clock;
    
    int av_sync_type;
    double external_clock;/*external clock base*/
    int64_t external_clock_time;
    
    int audio_hw_buf_size;
    double audio_diff_cum;/*used of AV difference average computation*/
    double audio_diff_avg_coef;
    double audio_diff_threshold;
    int audio_diff_avg_count;
    double frame_timer;
    double frame_last_pts;
    double frame_last_delay;
    
    double video_current_pts; ///<current displayed pts (different from video_clock if frame fifos are used)
    int64_t video_current_pts_time; ///<time (av_gettime) at which we updated video_current_pts - used to have running video pts
    
    double video_clock; ///<pts of last decoded frame / predicted pts of next decoded frame
    
    //quit = -2 : 未开始初始化函数
    //quit = -1 : 完成ffmpeg相关属性的初始化
    //quit = 0 : 正常开始进行视频的播放
    //quit = 1 : 退出当前视频的播放
    int quit;
    
    // for seek stream
    int seek_req;
    int64_t seek_pos;
    int64_t seek_rel;
    int seek_flags;
    SDL_cond *continue_read_thread;
    
    // 视频总时长
    int64_t duration;
    double totalTimes;
    
    AVCodecContext * audio_codec_ctx;
    AVCodecContext * video_codec_ctx;
    int paused;
    SDL_TimerID lastAddTimer;
    Uint32 event;
    
    int backed;
    AVPacket flush_pkt;
    
} VideoState;

enum {
    AV_SYNC_AUDIO_MASTER,
    AV_SYNC_VIDEO_MASTER,
    AV_SYNC_EXTERNAL_MASTER,
};

/**
 主动获得当前的播放时间位置

 @return 返回int型的时间戳
 */
int stream_GetCurrentPosition();

/**
 获得播放的时长

 @return 返回int64_t的时间戳
 */
int64_t stream_GetDuration();

/**
 进行指定pts位置进行跳转

 @param pos 设置跳转pts位置
 @param rel 现在此参数暂时不使用，请传入默认值0
 @param seek_by_bytes 现在此参数暂时不使用，请传入默认值0
 */
void stream_seek(int64_t pos, int64_t rel, int seek_by_bytes);

/**
 视频暂停
 */
void stream_pause();


void stream_play(const char *inPath);

/**
 视频关闭
 */
void stream_close();

#endif /* ffplayer_android_h */
