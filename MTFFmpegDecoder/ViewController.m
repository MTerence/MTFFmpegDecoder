//
//  ViewController.m
//  MTFFmpegDecoder
//
//  Created by Ternence on 2019/3/27.
//  Copyright © 2019 Ternence. All rights reserved.
//

#import "ViewController.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

@interface ViewController ()

@end

@implementation ViewController

- (IBAction)action_DecodeButtonClick:(UIButton *)sender {
    
    AVFormatContext     *pFormatCtx;        //统领全局的基本结构体。主要用于处理封装格式（FLV/MKV/RMVB等
    AVCodecContext      *pCodecCtx;         //保存视、音频编解码相关信息
    AVCodec             *pCodec;            //每种编解码器对应一个结构体
    AVFrame             *pFrame;            //解码后的结构
    AVFrame             *pFrameYUV;
    AVPacket            *packet;            //解码前
    struct SwsContext   *img_convert_ctx;   //头文件只有一行，但是实际上这个结构体十分复杂

    int                 i;
    int                 videoIndex;         //为了检查哪个流是视频流，保存流数组下标
    uint8_t             *out_buffer;
    
    int                 y_size;
    int                 ret, got_picture;
    
    FILE                *fil_yuv;
    int                 frame_cnt;          //帧数计算
    clock_t             time_start, time_finish;
    double              time_duration = 0.0;
    
    char input_str_full[500] = {0};
    char output_str_full[500] = {0};
    char info[1000] = {0};
    
    NSString *input_str = [NSString stringWithFormat:@"resource.bundle/%@",self.information];
    NSString *output_str = [NSString stringWithFormat:@"resource.bundle/%@",self.outputURL.text];
    
    NSString *input_nsstr = [[[NSBundle mainBundle]resourcePath] stringByAppendingPathComponent:input_str];
    NSString *output_nsstr = [[[NSBundle mainBundle]resourcePath] stringByAppendingPathComponent:output_str];
    
    sprintf(input_str_full, "%s", [input_nsstr UTF8String]);
    sprintf(output_str_full, "%s",[output_nsstr UTF8String]);
    
    printf("Input Path %s\n", input_str_full);
    printf("Output Path %s\n", output_str_full);
    
    //初始化解码器
    av_register_all();
    avformat_network_init();
    pFormatCtx = avformat_alloc_context();
    
    /*
     avformat_open_input FFmpeg打开媒体
     在该函数中，FFMPEG完成了
     输入输出结构体AVIOContext的初始化；
     
     输入数据的协议（例如RTMP，或者file）的识别（通过一套评分机制）:1判断文件名的后缀 2读取文件头的数据进行比对；
     
     使用获得最高分的文件协议对应的URLProtocol，通过函数指针的方式，与FFMPEG连接（非专业用词）；
     
     剩下的就是调用该URLProtocol的函数进行open,read等操作了
     
     @return >=0 if OK, AVERROR_xxx on error
     */
    
    if (avformat_open_input(&pFormatCtx, input_str_full, NULL, NULL) < 0) {
        printf("Couldn't open input stream.\n");
        return;
    }
    
    
    /*
     int avformat_find_stream_info(AVFormatContext *ic, AVDictionary **options);
     该函数可以读取一部分视音频数据并且获得一些相关的信息
     ic：输入的AVFormatContext。
     options：额外的选项,具体干啥的不知道...
     @return >=0 if OK, AVERROR_xxx on error
     
     该函数主要用于给每个媒体流（音频/视频）的AVStream结构体赋值。我们大致浏览一下这个函数的代码，会发现它其实已经实现了解码器的查找，解码器的打开，视音频帧的读取，视音频帧的解码等工作。换句话说，该函数实际上已经“走通”的解码的整个流程。下面看一下除了成员变量赋值之外，该函数的几个关键流程。

     1.查找解码器：find_decoder()
     2.打开解码器：avcodec_open2()
     3.读取完整的一帧压缩编码的数据：read_frame_internal()
     注：av_read_frame()内部实际上就是调用的read_frame_internal()。
     4.解码一些压缩编码数据：try_decode_frame()
     */
    if (avformat_find_stream_info(pFormatCtx, NULL) < 0) {
        printf("Couldn't find stream information.\n");
        return;
    }
    
    //找出视频流, nb_streams表示视频中有几种流
    videoIndex = -1;
    for (i = 0; i < pFormatCtx->nb_streams; i++)
    {
        if (pFormatCtx->streams[i]->codec->codec_type == AVMEDIA_TYPE_VIDEO) {
            videoIndex = i;
            break;
        }
    }
    
    if (videoIndex == -1) {
        printf("Couldn't find a video stream.\n");
        return;
    }
    
    /*
    复制编解码的信息到编解码的结构AVCodecContext结构中，
    一方面为了操作结构中数据方便（不需要每次都从AVFormatContext结构开始一个一个指向）
    另一方面方便函数的调用
     */
    pCodecCtx = pFormatCtx->streams[videoIndex]->codec;
    
    //找到一个和视频流对应的解码器
    pCodec = avcodec_find_decoder(pCodecCtx->codec_id);
    if (pCodec == NULL) {
        printf("Couldn't find Codec.\n");
        return;
    }
    
    /*
     int avcodec_open2(AVCodecContext *avctx, const AVCodec *codec, AVDictionary **options);
     初始化一个视音频编解码器的AVCodecContext(打开解码器)
     avctx：需要初始化的AVCodecContext。
     codec：输入的AVCodec
     options：一些选项。例如使用libx264编码的时候，“preset”，“tune”等都可以通过该参数设置。
     
     */
    if (avcodec_open2(pCodecCtx, pCodec, NULL) != 0) {
        printf("Couldn't open Codec.\n");
        return;
    }
    
    pFrame    = av_frame_alloc();
    pFrameYUV = av_frame_alloc();
    out_buffer = (unsigned char *)av_malloc(av_image_get_buffer_size(AV_PIX_FMT_YUV420P, pCodecCtx->width, pCodecCtx->height, 1));
    av_image_fill_arrays(pFrameYUV->data, pFrameYUV->linesize, out_buffer, AV_PIX_FMT_YUV420P, pCodecCtx->width, pCodecCtx->height, 1);
    packet = (AVPacket *)av_malloc(sizeof(AVPacket));
    
    
}

@end
