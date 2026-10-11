#import "NetworkSource.h"
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>

@implementation OBCLNetworkSource {
    NSLock *_lock;
    dispatch_queue_t _queue;
    uint64_t _generation, _decoded, _decodeGeneration;
    int _fd;
    CVPixelBufferRef _latest;
    double _latestTime;
    NSString *_message;
    // Decoder state is accessed only by the receiver queue / synchronous VT callback.
    VTDecompressionSessionRef _decoder;
    CMVideoFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    BOOL _needsIDR;
}
- (instancetype)init {
    if ((self=[super init])) {
        _lock=[NSLock new]; _fd=-1; _message=@"not connected";
        _queue=dispatch_queue_create("lab.external.vcam.network",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)message:(NSString *)text { [_lock lock]; _message=text; [_lock unlock]; }
- (BOOL)valid:(uint64_t)token { [_lock lock]; BOOL v=token==_generation; [_lock unlock]; return v; }
- (void)stop {
    [_lock lock]; _generation++; if (_fd>=0) shutdown(_fd,SHUT_RDWR);
    if (_latest) { CVPixelBufferRelease(_latest); _latest=NULL; }
    _latestTime=0; _message=@"stopped"; [_lock unlock];
}
- (CVPixelBufferRef)copyLatestWithMaximumAge:(double)age {
    [_lock lock]; CVPixelBufferRef value=NULL;
    if (_latest && CACurrentMediaTime()-_latestTime<=age) value=CVPixelBufferRetain(_latest);
    [_lock unlock]; return value;
}
- (NSString *)status {
    [_lock lock];
    NSString *s=[NSString stringWithFormat:@"NET %llu · age %.0f ms\n%@",(unsigned long long)_decoded,
        _latestTime ? (CACurrentMediaTime()-_latestTime)*1000 : -1, _message];
    [_lock unlock]; return s;
}
static BOOL readAll(int fd,void *bytes,size_t length) {
    uint8_t *p=bytes;
    while (length) {
        ssize_t n=recv(fd,p,length,0);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return NO;
        p+=n; length-=(size_t)n;
    }
    return YES;
}
static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];
}
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p)<<32)|be32(p+4); }
static int connectIP(NSString *host,uint16_t port) {
    struct sockaddr_in addr={0}; addr.sin_family=AF_INET; addr.sin_port=htons(port);
    // Numeric IPv4 only; there is no DNS, credentials, or remote discovery.
    if (inet_pton(AF_INET,host.UTF8String,&addr.sin_addr)!=1) return -1;
    int fd=socket(AF_INET,SOCK_STREAM,0); if (fd<0) return -1;
    int original=fcntl(fd,F_GETFL,0); fcntl(fd,F_SETFL,original|O_NONBLOCK);
    int result=connect(fd,(struct sockaddr *)&addr,sizeof(addr));
    if (result<0) {
        struct pollfd p={.fd=fd,.events=POLLOUT}; int error=0; socklen_t len=sizeof(error);
        if (errno!=EINPROGRESS || poll(&p,1,3000)<=0 || getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&len)<0 || error) {
            close(fd); return -1;
        }
    }
    fcntl(fd,F_SETFL,original);
    int one=1; setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    struct timeval timeout={.tv_sec=3,.tv_usec=0};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    return fd;
}
static NSArray<NSData *> *splitAnnexB(NSData *data) {
    const uint8_t *p=data.bytes; NSUInteger n=data.length,start=NSNotFound;
    NSMutableArray *parts=[NSMutableArray array];
    for (NSUInteger i=0;i+3<=n;) {
        NSUInteger prefix=0;
        if (p[i]==0 && p[i+1]==0) {
            if (p[i+2]==1) prefix=3;
            else if (i+4<=n && p[i+2]==0 && p[i+3]==1) prefix=4;
        }
        if (prefix) {
            if (start!=NSNotFound && i>start) [parts addObject:[data subdataWithRange:NSMakeRange(start,i-start)]];
            start=i+prefix; i+=prefix;
        } else i++;
    }
    if (start!=NSNotFound && n>start) [parts addObject:[data subdataWithRange:NSMakeRange(start,n-start)]];
    return parts;
}
- (void)resetDecoder {
    if (_decoder) { VTDecompressionSessionWaitForAsynchronousFrames(_decoder); VTDecompressionSessionInvalidate(_decoder); CFRelease(_decoder); _decoder=NULL; }
    if (_format) { CFRelease(_format); _format=NULL; }
    _needsIDR=YES;
}
- (void)acceptImage:(CVImageBufferRef)image status:(OSStatus)status {
    if (status || !image) { [self message:[NSString stringWithFormat:@"VT output error %d",(int)status]]; return; }
    [_lock lock];
    if (_decodeGeneration!=_generation) { [_lock unlock]; return; }
    if (_latest) CVPixelBufferRelease(_latest);
    _latest=CVPixelBufferRetain(image); _latestTime=CACurrentMediaTime(); _decoded++;
    [_lock unlock];
}
static void decoded(void *ref,void *source,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration) {
    (void)source; (void)flags; (void)pts; (void)duration;
    [(__bridge OBCLNetworkSource *)ref acceptImage:image status:status];
}
- (BOOL)makeDecoder {
    if (!_sps || !_pps) return NO;
    const uint8_t *sets[]={_sps.bytes,_pps.bytes}; size_t sizes[]={_sps.length,_pps.length};
    OSStatus e=CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,sets,sizes,4,&_format);
    if (e) { [self message:[NSString stringWithFormat:@"SPS/PPS error %d",(int)e]]; return NO; }
    CMVideoDimensions dimensions=CMVideoFormatDescriptionGetDimensions(_format);
    if (dimensions.width<1 || dimensions.height<1 || dimensions.width>4096 || dimensions.height>4096 ||
        (int64_t)dimensions.width*dimensions.height>8388608) {
        [self resetDecoder]; [self message:@"Unsupported video dimensions"]; return NO;
    }
    VTDecompressionOutputCallbackRecord callback={decoded,(__bridge void *)self};
    NSDictionary *spec=@{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES};
    NSDictionary *attrs=@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                          (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    e=VTDecompressionSessionCreate(kCFAllocatorDefault,_format,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)attrs,&callback,&_decoder);
    if (e) { [self resetDecoder]; [self message:[NSString stringWithFormat:@"VT create error %d",(int)e]]; return NO; }
    CFTypeRef hw=NULL;
    VTSessionCopyProperty(_decoder,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,kCFAllocatorDefault,&hw);
    [self message:[NSString stringWithFormat:@"connected :9002 · hardware=%@",hw ? (__bridge id)hw : @"unknown"]];
    if (hw) CFRelease(hw); return YES;
}
- (void)decodeAU:(NSData *)data pts:(uint64_t)pts {
    NSArray<NSData *> *parts=splitAnnexB(data); BOOL key=NO,changed=NO,hasVCL=NO;
    for (NSData *nal in parts) {
        if (!nal.length) continue; uint8_t type=((const uint8_t *)nal.bytes)[0]&31;
        if (type==7 && ![_sps isEqualToData:nal]) { _sps=nal; changed=YES; }
        if (type==8 && ![_pps isEqualToData:nal]) { _pps=nal; changed=YES; }
        if (type==5) key=YES; if (type==1 || type==5) hasVCL=YES;
    }
    if (changed) [self resetDecoder];
    if (!hasVCL || (_needsIDR && !key)) return;
    if (!_decoder && ![self makeDecoder]) return;
    NSMutableData *avcc=[NSMutableData data];
    for (NSData *nal in parts) {
        if (!nal.length) continue; uint8_t type=((const uint8_t *)nal.bytes)[0]&31;
        if (type==7 || type==8 || type==9) continue;
        uint32_t size=htonl((uint32_t)nal.length); [avcc appendBytes:&size length:4]; [avcc appendData:nal];
    }
    if (!avcc.length) return;
    CMBlockBufferRef block=NULL; CMSampleBufferRef sample=NULL;
    OSStatus e=CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,NULL,avcc.length,kCFAllocatorDefault,NULL,0,avcc.length,0,&block);
    if (!e) e=CMBlockBufferReplaceDataBytes(avcc.bytes,block,0,avcc.length);
    CMSampleTimingInfo timing={CMTimeMake(1,30),CMTimeMake((int64_t)pts,1000000),kCMTimeInvalid}; size_t size=avcc.length;
    if (!e) e=CMSampleBufferCreateReady(kCFAllocatorDefault,block,_format,1,1,&timing,1,&size,&sample);
    if (!e) {
        VTDecodeInfoFlags info=0;
        // No asynchronous flag: the worker waits; the guest media/UI queue never waits on VT.
        e=VTDecompressionSessionDecodeFrame(_decoder,sample,0,NULL,&info);
        if (!e) _needsIDR=NO;
    }
    if (sample) CFRelease(sample); if (block) CFRelease(block);
    if (e) { [self resetDecoder]; [self message:[NSString stringWithFormat:@"VT decode error %d",(int)e]]; }
}
- (void)startHost:(NSString *)host port:(uint16_t)port {
    struct in_addr check;
    if (inet_pton(AF_INET,host.UTF8String,&check)!=1) { [self message:@"Enter a numeric PC IPv4 address"]; return; }
    [self stop]; [_lock lock]; uint64_t token=_generation; _decoded=0; [_lock unlock];
    dispatch_async(_queue,^{
        while ([self valid:token]) { @autoreleasepool {
            [self resetDecoder]; self->_sps=nil; self->_pps=nil;
            [self message:@"connecting :9002"];
            int fd=connectIP(host,port);
            if (fd>=0) {
                [self->_lock lock]; BOOL current=token==self->_generation; if (current) self->_fd=fd; [self->_lock unlock];
                if (current) while ([self valid:token]) { @autoreleasepool {
                    uint8_t header[24]; if (!readAll(fd,header,sizeof(header))) break;
                    uint32_t length=be32(header+8);
                    if (memcmp(header,"OBSC",4) || header[4]!=1 || header[5]!=1 || !length || length>8*1024*1024) {
                        [self message:@"invalid OBSC header"]; break;
                    }
                    NSMutableData *data=[NSMutableData dataWithLength:length];
                    if (!readAll(fd,data.mutableBytes,length)) break;
                    if ([self valid:token]) { self->_decodeGeneration=token; [self decodeAU:data pts:be64(header+16)]; }
                }}
                [self->_lock lock]; if (self->_fd==fd) self->_fd=-1; [self->_lock unlock]; close(fd);
            }
            [self resetDecoder];
            if ([self valid:token]) { [self message:@"disconnected · retrying"]; for (int i=0;i<10 && [self valid:token];i++) usleep(100000); }
        }}
        [self resetDecoder];
    });
}
@end
