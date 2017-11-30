//
//  ffplayer_interface.h
//  Rectangles
//
//  Created by huangjunren on 2017/11/30.
//

#import <Foundation/Foundation.h>
#include "ffplayer.h"

@protocol ffplayerSeekPosDelegate <NSObject>//协议
- (void)didTransSeekPos:(double)pos;//协议方法
@end

@interface ffplayer_interface : NSObject
@property (nonatomic, weak) id<ffplayerSeekPosDelegate> delegate;//代理属性

/**
 主动获得当前的播放时间位置
 
 @return 返回int型的时间戳
 */
- (int) stream_GetCurrentPosition;

/**
 获得播放的时长
 
 @return 返回int64_t的时间戳
 */
- (int64_t) stream_GetDuration;

/**
 进行指定pts位置进行跳转
 
 @param pos 设置跳转pts位置
 @param rel 现在此参数暂时不使用，请传入默认值0
 @param seek_by_bytes 现在此参数暂时不使用，请传入默认值0
 */
- (void) stream_seek:(int64_t)pos rel:(int64_t)rel seek_by_bytes:(int)seek_by_bytes;

/**
 视频暂停
 */
- (void) stream_pause;

/**
 视频播放

 @param filePath 传入的视频播放路径
 */
- (void) stream_play:(NSString *)filePath;

/**
 视频关闭
 */
- (void) stream_close;

@end
