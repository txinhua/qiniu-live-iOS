//
//  QNPiliCameraVC.m
//  QNPilePlayDemo
//
//  Created by   何舒 on 15/11/3.
//  Copyright © 2015年   何舒. All rights reserved.
//

#import "QNPiliCameraVC.h"
#import "Reachability.h"
#import <PLMediaStreamingKit/PLMediaStreamingKit.h>
#import <asl.h>

const char *stateNames[] = {
    "Unknow",
    "Connecting",
    "Connected",
    "Disconnecting",
    "Disconnected",
    "Error"
};

const char *networkStatus[] = {
    "Not Reachable",
    "Reachable via WiFi",
    "Reachable via CELL"
};

#define kReloadConfigurationEnable  0

// 假设在 videoFPS 低于预期 50% 的情况下就触发降低推流质量的操作，这里的 40% 是一个假定数值，你可以更改数值来尝试不同的策略
#define kMaxVideoFPSPercent 0.5

// 假设当 videoFPS 在 10s 内与设定的 fps 相差都小于 5% 时，就尝试调高编码质量
#define kMinVideoFPSPercent 0.05
#define kHigherQualityTimeInterval  10

#define kBrightnessAdjustRatio  1.03
#define kSaturationAdjustRatio  1.03

#define kDeviceWidth [UIScreen mainScreen].bounds.size.width        //屏幕宽
#define KDeviceHeight [UIScreen mainScreen].bounds.size.height      //屏幕高

@interface QNPiliCameraVC ()<
PLMediaStreamingSessionDelegate,
PLStreamingSendingBufferDelegate,PLAudioPlayerDelegate
>
@property (nonatomic, assign) NSInteger orientationNum;
@property (nonatomic, strong) NSDictionary *streamDic;
@property (nonatomic, strong) NSDictionary * startStreamDic;
@property (nonatomic, strong) NSString * streamName;
@property (nonatomic, strong) NSString * quality;
@property (nonatomic, strong) PLMediaStreamingSession  *session;
@property (nonatomic, strong) Reachability *internetReachability;
@property (nonatomic, strong) dispatch_queue_t sessionQueue;
@property (nonatomic, strong) NSArray<PLVideoCaptureConfiguration *>   *videoCaptureConfigurations;
@property (nonatomic, strong) NSArray<PLVideoStreamingConfiguration *>   *videoStreamingConfigurations;
@property (nonatomic, strong) NSDate    *keyTime;
@property (nonatomic, strong) NSMutableArray *filterHandlers;
@property (nonatomic, assign) BOOL isStart;
@property (nonatomic, strong) PLAudioPlayer * plAudioPlayer;
@property (nonatomic, assign) BOOL audioEffectOn;


@end

@implementation QNPiliCameraVC

- (instancetype)initWithOrientation:(NSInteger)orientationNum
                      withStreamDic:(NSDictionary *)streamDic
                          withTitle:(NSString *)streamName
{
    self = [super init];
    
    
    if (self) {
        self.streamDic = streamDic;
        self.streamName = streamName;
        self.orientationNum = orientationNum;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    
    self.title = @"视频录播";
    [[UIApplication sharedApplication] setStatusBarHidden:YES];
    
    
    // 预先设定几组编码质量，之后可以切换
    CGSize videoSize;
    if(self.orientationNum)
    {
        videoSize = CGSizeMake(kDeviceWidth, KDeviceHeight);
    }else
    {
        videoSize = CGSizeMake(KDeviceHeight, kDeviceWidth);
    }
    self.videoStreamingConfigurations = @[
                                          [[PLVideoStreamingConfiguration alloc] initWithVideoSize:videoSize expectedSourceVideoFrameRate:15 videoMaxKeyframeInterval:45 averageVideoBitRate:800 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                          [[PLVideoStreamingConfiguration alloc] initWithVideoSize:videoSize expectedSourceVideoFrameRate:24 videoMaxKeyframeInterval:72 averageVideoBitRate:800 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                          [[PLVideoStreamingConfiguration alloc] initWithVideoSize:videoSize expectedSourceVideoFrameRate:30 videoMaxKeyframeInterval:90 averageVideoBitRate:800 * 1000 videoProfileLevel:AVVideoProfileLevelH264Baseline31],
                                          ];
    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    if (!self.orientationNum) {
        orientation = AVCaptureVideoOrientationLandscapeRight;
    }
    self.videoCaptureConfigurations = @[[[PLVideoCaptureConfiguration alloc] initWithVideoFrameRate:15 sessionPreset:AVCaptureSessionPresetiFrame960x540 previewMirrorFrontFacing:YES previewMirrorRearFacing:NO streamMirrorFrontFacing:NO streamMirrorRearFacing:NO cameraPosition:AVCaptureDevicePositionFront videoOrientation:orientation],[[PLVideoCaptureConfiguration alloc] initWithVideoFrameRate:24 sessionPreset:AVCaptureSessionPresetiFrame960x540 previewMirrorFrontFacing:YES previewMirrorRearFacing:NO streamMirrorFrontFacing:NO streamMirrorRearFacing:NO cameraPosition:AVCaptureDevicePositionFront videoOrientation:orientation],[[PLVideoCaptureConfiguration alloc] initWithVideoFrameRate:30 sessionPreset:AVCaptureSessionPresetiFrame960x540 previewMirrorFrontFacing:YES previewMirrorRearFacing:NO streamMirrorFrontFacing:NO streamMirrorRearFacing:NO cameraPosition:AVCaptureDevicePositionFront videoOrientation:orientation]];
    self.sessionQueue = dispatch_queue_create("pili.queue.streaming", DISPATCH_QUEUE_SERIAL);
    
    // 网络状态监控
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
    self.internetReachability = [Reachability reachabilityForInternetConnection];
    [self.internetReachability startNotifier];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:[AVAudioSession sharedInstance]];
    
    
#warning 如果要运行 demo 这里应该填写服务端返回的某个流的 json 信息
    if (self.streamDic[@"stream"] == nil) {
        [SVProgressHUD showAlterMessage:@"当前没有可用流，请退出重进"];
    }else{
        NSDictionary * dicStream = [Help dictionaryWithJsonString:self.streamDic[@"stream"]];
        PLStream *stream = [PLStream streamWithJSON:dicStream];
        
        void (^permissionBlock)(void) = ^{
            dispatch_async(self.sessionQueue, ^{
                PLVideoCaptureConfiguration *videoCaptureConfiguration = [self.videoCaptureConfigurations lastObject];
                PLAudioCaptureConfiguration *audioCaptureConfiguration = [PLAudioCaptureConfiguration defaultConfiguration];
                // 视频编码配置
                PLVideoStreamingConfiguration *videoStreamingConfiguration = [self.videoStreamingConfigurations lastObject];
                // 音频编码配置
                PLAudioStreamingConfiguration *audioStreamingConfiguration = [PLAudioStreamingConfiguration defaultConfiguration];
                AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
                if (!self.orientationNum) {
                    orientation = AVCaptureVideoOrientationLandscapeRight;
                }
                // 推流 session
                self.session = [[PLMediaStreamingSession alloc] initWithVideoCaptureConfiguration:videoCaptureConfiguration audioCaptureConfiguration:audioCaptureConfiguration videoStreamingConfiguration:videoStreamingConfiguration audioStreamingConfiguration:audioStreamingConfiguration stream:stream];
                self.session.delegate = self;
                [self.session setBeautifyModeOn:YES];
                NSString * path = [[NSBundle mainBundle] pathForResource: @"xxxxxx" ofType: @"mp3"];
                self.plAudioPlayer = [self.session audioPlayerWithFilePath:path];
                self.plAudioPlayer.delegate = self;
                UIImage *waterMark = [UIImage imageNamed:@"qiniu"];
                [self.session setWaterMarkWithImage:waterMark position:CGPointMake(0, 0)];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.session.previewView.frame =self.view.frame;
                    
                    self.view.backgroundColor = [UIColor clearColor];
                    [self.view insertSubview:self.session.previewView atIndex:0];
                });
            });
        };
        
        void (^noAccessBlock)(void) = ^{
            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"No Access", nil)
                                                                message:NSLocalizedString(@"!", nil)
                                                               delegate:nil
                                                      cancelButtonTitle:NSLocalizedString(@"Cancel", nil)
                                                      otherButtonTitles:nil];
            [alertView show];
        };
        
        switch ([PLCameraStreamingSession cameraAuthorizationStatus]) {
            case PLAuthorizationStatusAuthorized:
                permissionBlock();
                break;
            case PLAuthorizationStatusNotDetermined: {
                [PLCameraStreamingSession requestCameraAccessWithCompletionHandler:^(BOOL granted) {
                    granted ? permissionBlock() : noAccessBlock();
                }];
            }
                break;
            default:
                noAccessBlock();
                break;
        }
    }
}





- (void)startStream
{
    NSDictionary * dic = @{@"sessionId":[UserInfoClass sheardUserInfo].sessionID,
                           @"accessToken":[Help transformAccessToken:[UserInfoClass sheardUserInfo].sessionID],
                           @"streamId":self.streamDic[@"streamId"],
                           @"streamQuality":@"4",
                           @"streamTitle":self.streamName,
                           @"streamOrientation":[NSString stringWithFormat:@"%ld",(long)self.orientationNum]};
    [HTTPRequestPost hTTPRequest_PostpostBody:dic andUrl:@"start/publish" andSucceed:^(NSURLSessionDataTask *task, id responseObject) {
        self.startStreamDic = responseObject;
    } andFailure:^(NSURLSessionDataTask *task, NSError *error) {
    } andISstatus:NO];
}

- (BOOL)shouldAutorotate
{
    return NO;
}

-(UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
        if (self.orientationNum) {
            return UIInterfaceOrientationPortrait;
    
        }else{
            return UIInterfaceOrientationLandscapeRight;
        }
    
    
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations

{
        if (self.orientationNum) {
            return UIInterfaceOrientationMaskPortrait;
        }else
        {
            return UIInterfaceOrientationMaskLandscapeRight;
        }
}

- (IBAction)backAction:(id)sender
{
    if(self.isStart){
        NSDictionary * dic = @{@"sessionId":[UserInfoClass sheardUserInfo].sessionID,@"accessToken":[Help transformAccessToken:[UserInfoClass sheardUserInfo].sessionID],@"publishId":self.startStreamDic[@"publishId"]};
        [HTTPRequestPost hTTPRequest_PostpostBody:dic andUrl:@"stop/publish" andSucceed:^(NSURLSessionDataTask *task, id responseObject) {
            [SVProgressHUD showAlterMessage:responseObject[@"desc"]];
//            [self.session stop];
            [self.session stopStreaming];
        } andFailure:^(NSURLSessionDataTask *task, NSError *error) {
        } andISstatus:NO];
    }
    [self dismissViewControllerAnimated:YES completion:^{
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kReachabilityChangedNotification object:nil];
    
    dispatch_sync(self.sessionQueue, ^{
        [self.plAudioPlayer stopAndRelease];
        [self.session destroy];
    });
    self.session = nil;
    self.sessionQueue = nil;
}

#pragma mark - Notification Handler

- (void)reachabilityChanged:(NSNotification *)notif{
    Reachability *curReach = [notif object];
    NSParameterAssert([curReach isKindOfClass:[Reachability class]]);
    NetworkStatus status = [curReach currentReachabilityStatus];
    
    if (NotReachable == status) {
        // 对断网情况做处理
        [self stopSession];
    }
    
    NSString *log = [NSString stringWithFormat:@"Networkt Status: %s", networkStatus[status]];
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

#pragma mark - <PLAudioPlayerDelegate>
- (void)audioPlayer:(PLAudioPlayer *)audioPlayer audioDidPlayedRateChanged:(double)audioDidPlayedRate
{
    NSLog(@"PlayedRate : %f",audioDidPlayedRate);
}

- (void)audioPlayer:(PLAudioPlayer *)audioPlayer findFileError:(PLAudioPlayerFileError)fileError
{
    NSLog(@"PLAudioPlayerFileError == %u", fileError);
}

- (BOOL)didAudioFilePlayingFinishedAndShouldAudioPlayerPlayAgain:(PLAudioPlayer *)audioPlayer
{
    return  YES;
}

#pragma mark - <PLStreamingSendingBufferDelegate>

- (void)streamingSessionSendingBufferDidFull:(id)session {
    NSString *log = @"Buffer is full";
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

- (void)handleInterruption:(NSNotification *)notification {
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
        NSLog(@"Interruption notification");
        
        if ([[notification.userInfo valueForKey:AVAudioSessionInterruptionTypeKey] isEqualToNumber:[NSNumber numberWithInt:AVAudioSessionInterruptionTypeBegan]]) {
            NSLog(@"InterruptionTypeBegan");
        } else {
            // the facetime iOS 9 has a bug: 1 does not send interrupt end 2 you can use application become active, and repeat set audio session acitve until success.  ref http://blog.corywiles.com/broken-facetime-audio-interruptions-in-ios-9
            NSLog(@"InterruptionTypeEnded");
            AVAudioSession *session = [AVAudioSession sharedInstance];
            [session setActive:YES error:nil];
        }
    }
}

- (void)streamingSession:(id)session sendingBufferDidDropItems:(NSArray *)items {
    NSString *log = @"Frame dropped";
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
}

#pragma mark - <PLMediaStreamingSessionDelegate>

- (void)mediaStreamingSession:(PLMediaStreamingSession *)session streamStateDidChange:(PLStreamState)state {
    NSString *log = [NSString stringWithFormat:@"Stream State: %s", stateNames[state]];
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
        // 除 PLStreamStateError 外的其余状态会回调在这个方法
        // 这个回调会确保在主线程，所以可以直接对 UI 做操作
        if (PLStreamStateConnected == state) {
            [self.actionButton setTitle:NSLocalizedString(@"Stop", nil) forState:UIControlStateNormal];
        } else if (PLStreamStateDisconnected == state) {
            [self.actionButton setTitle:NSLocalizedString(@"Start", nil) forState:UIControlStateNormal];
        }
    
    
}

- (void)mediaStreamingSession:(PLMediaStreamingSession *)session didDisconnectWithError:(NSError *)error {
    NSString *log = [NSString stringWithFormat:@"Stream State: Error. %@", error];
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
        [self.actionButton setTitle:NSLocalizedString(@"Reconnecting", nil) forState:UIControlStateNormal];
    // PLStreamStateError 都会回调在这个方法
    // 尝试重连，注意这里需要你自己来处理重连尝试的次数以及重连的时间间隔
    [self.actionButton setTitle:NSLocalizedString(@"Reconnecting", nil) forState:UIControlStateNormal];
    [self startSession];
}

- (void)mediaStreamingSession:(PLMediaStreamingSession *)session streamStatusDidUpdate:(PLStreamStatus *)status {
    NSString *log = [NSString stringWithFormat:@"%@", status];
    NSLog(@"%@", log);
        self.textView.text = [NSString stringWithFormat:@"%@\%@", self.textView.text, log];
    
#if kReloadConfigurationEnable
    NSDate *now = [NSDate date];
    if (!self.keyTime) {
        self.keyTime = now;
    }
    
    double expectedVideoFPS = (double)self.session.videoConfiguration.videoFrameRate;
    double realtimeVideoFPS = status.videoFPS;
    if (realtimeVideoFPS < expectedVideoFPS * (1 - kMaxVideoFPSPercent)) {
        // 当得到的 status 中 video fps 比设定的 fps 的 50% 还小时，触发降低推流质量的操作
        self.keyTime = now;
        
        [self lowerQuality];
    } else if (realtimeVideoFPS >= expectedVideoFPS * (1 - kMinVideoFPSPercent)) {
        if (-[self.keyTime timeIntervalSinceNow] > kHigherQualityTimeInterval) {
            self.keyTime = now;
            
            [self higherQuality];
        }
    }
#endif  // #if kReloadConfigurationEnable
}

#pragma mark -

- (void)higherQuality {
    NSUInteger idx = [self.videoStreamingConfigurations indexOfObject:self.session.videoStreamingConfiguration];
    NSAssert(idx != NSNotFound, @"Oops");
    
    if (idx >= self.videoStreamingConfigurations.count - 1) {
        return;
    }
    PLVideoStreamingConfiguration *newStreamingConfiguration = self.videoStreamingConfigurations[idx + 1];
    [self.session reloadVideoStreamingConfiguration:newStreamingConfiguration];
}

- (void)lowerQuality {
    NSUInteger idx = [self.videoStreamingConfigurations indexOfObject:self.session.videoStreamingConfiguration];
    NSAssert(idx != NSNotFound, @"Oops");
    
    if (0 == idx) {
        return;
    }
    PLVideoStreamingConfiguration *newStreamingConfiguration = self.videoStreamingConfigurations[idx - 1];
    [self.session reloadVideoStreamingConfiguration:newStreamingConfiguration];
}

#pragma mark - Operation

- (void)stopSession {
    dispatch_async(self.sessionQueue, ^{
        self.keyTime = nil;
        [self.session stopStreaming];
    });
}

//- (void)startSession {
//    self.keyTime = nil;
//    self.actionButton.enabled = NO;
//    dispatch_async(self.sessionQueue, ^{
//        [self.session startWithCompleted:^(BOOL success) {
//            dispatch_async(dispatch_get_main_queue(), ^{
//                self.actionButton.enabled = YES;
//            });
//        }];
//    });
//}

- (IBAction)screenCaptureAction:(id)sender
{
    [self.session getScreenshotWithCompletionHandler:^(UIImage * _Nullable image) {
        if (image) {
            UIImageWriteToSavedPhotosAlbum(image, self, @selector(image:didFinishSavingWithError:contextInfo:), nil);
        }

    }];
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    // Was there an error?
    if (error != NULL)
    {
        // Show error message...
        [SVProgressHUD showAlterMessage:@"保存出错，请重新截取"];
        
    }
    else  // No errors
    {
        // Show message image successfully saved
        [SVProgressHUD showAlterMessage:@"截取成功，请到系统相册中去查看"];
    }
}

- (void)startSession {
    self.keyTime = nil;
    self.actionButton.enabled = NO;
    dispatch_async(self.sessionQueue, ^{
        [self.session startStreamingWithFeedback:^(PLStreamStartStateFeedback feedback) {
            if (feedback == PLStreamStartStateSuccess) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.actionButton.enabled = YES;
                });
            }
        }];
    });
}

#pragma mark - Action

- (IBAction)segmentedControlValueDidChange:(id)sender {
    PLVideoCaptureConfiguration *videoCaptureConfiguration;
        videoCaptureConfiguration = self.videoCaptureConfigurations[self.segementedControl.selectedSegmentIndex];
    [self.session reloadVideoStreamingConfiguration:self.session.videoStreamingConfiguration];
}

- (IBAction)zoomSliderValueDidChange:(id)sender {
        self.session.videoZoomFactor = self.zoomSlider.value;
}

- (IBAction)actionButtonPressed:(id)sender {
    if (!self.isStart) {
        [self startStream];
        self.isStart = YES;
    }
    if (PLStreamStateConnected == self.session.streamState) {
        [self stopSession];
    } else {
        [self startSession];
    }
}

- (IBAction)toggleCameraButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        [self.session toggleCamera];
    });
}

- (IBAction)torchButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        self.session.torchOn = !self.session.isTorchOn;
        
    });
}

- (IBAction)muteButtonPressed:(id)sender {
    dispatch_async(self.sessionQueue, ^{
        self.session.muted = !self.session.isMuted;
    });
}

-(IBAction)switchAction:(id)sender
{
    UISwitch *switchButton = (UISwitch*)sender;
    BOOL isButtonOn = [switchButton isOn];
    [self.session setBeautifyModeOn:isButtonOn];
        self.beautyView.hidden = !isButtonOn;
        self.beauty.value = 50;
        self.whiten.value = 50;
        self.redden.value = 50;
    
    
}

-(IBAction)beautyAction:(id)sender
{
    UIStepper *beautyStepperButton = (UIStepper*)sender;
    NSLog(@"beautyStepperButton.value/100 == %f",beautyStepperButton.value/100);
    [self.session setBeautify:beautyStepperButton.value/100];
    [SVProgressHUD showAlterMessage:[NSString stringWithFormat:@"%.2f",beautyStepperButton.value/100]];
}

-(IBAction)whiteAction:(id)sender
{
    UIStepper *whiteStepperButton = (UIStepper*)sender;
    CGFloat withe = whiteStepperButton.value/100;
    [self.session setWhiten:withe];
    [SVProgressHUD showAlterMessage:[NSString stringWithFormat:@"%.2f",withe]];
    
}

-(IBAction)reddenAction:(id)sender
{
    UIStepper *reddenStepperButton = (UIStepper*)sender;
    NSLog(@"reddenStepperButton.value/100 == %f",reddenStepperButton.value/100);
    [self.session setRedden:reddenStepperButton.value/100];
    [SVProgressHUD showAlterMessage:[NSString stringWithFormat:@"%.2f",reddenStepperButton.value/100]];
}

-(IBAction)beauty1Action:(id)sender
{
    UISlider *beautyStepperButton = (UISlider*)sender;
    NSLog(@"beautyStepperButton.value/100 == %f",beautyStepperButton.value/100);
    [self.session setBeautify:beautyStepperButton.value/100];
}

-(IBAction)white1Action:(id)sender
{
    UISlider *whiteStepperButton = (UISlider*)sender;
    CGFloat withe = whiteStepperButton.value/100;
    [self.session setWhiten:withe];
    
}

-(IBAction)redden1Action:(id)sender
{
    UISlider *reddenStepperButton = (UISlider*)sender;
    NSLog(@"reddenStepperButton.value/100 == %f",reddenStepperButton.value/100);
    [self.session setRedden:reddenStepperButton.value/100];
}

- (IBAction)playbackButtonPressed:(id)sender
{
    self.session.playback = !self.session.playback;
}

- (IBAction)audioEffectButtonPressed:(id)sender
{
//    NSArray<PLAudioEffectConfiguration *> *effects;
    
    if (!self.audioEffectOn) {
//
//                PLAudioEffectConfiguration *configuration = [PLAudioEffectModeConfiguration reverbHeightLevelModeConfiguration];
//                effects = @[configuration];
        [self.plAudioPlayer play];
    } else {
//        effects = @[];
        [self.plAudioPlayer pause];
    }
    self.audioEffectOn = !self.audioEffectOn;
//    self.session.audioEffectConfigurations = effects;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

/*
 #pragma mark - Navigation
 
 // In a storyboard-based application, you will often want to do a little preparation before navigation
 - (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
 // Get the new view controller using [segue destinationViewController].
 // Pass the selected object to the new view controller.
 }
 */

@end
