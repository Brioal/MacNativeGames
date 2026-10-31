/* Native macOS window and VI service adapter. No guest frame is synthesized. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "runtime.h"
#include "keyboard_map.h"
#include "game_version.h"
#include "totk_ui_lang.h"
#include "gamepad_layout.h"
#import "playtime.h"
#include "../third_party/d2r_gfx/gfx/nvn/totk_mfx_mode.h"
#include "../third_party/d2r_gfx/gfx/nvn/fps_overlay.h"
static NSWindow *window;
uint64_t dm_nvn_frame_count(void);   /* gfx/nvn/hle_nvn.c: game frames presented so far */
static CAMetalLayer *metalLayer;
static NSView *bootOverlay;
static NSTextField *bootStage,*bootDetail;
static NSProgressIndicator *bootProgress;
static NSView *hudBox;   /* the FPS / shader / load box (TOTKHudBox), nil with TOTK_HUD=corners */
static NSView *fpsGraphBox;
static int fpsGraphEnabled;
/* The settings panel (key 1, settings_panel.h): while it is open the game gets no keyboard or mouse input. */
static int settingsOpen;
static void settings_show(int open);
#ifdef GAME_BOTW160
static int amiiboPanelOpen;
static void amiibo_panel_show(int open);
static BOOL modManagerOpen;
static void mod_manager_show(int open);
static void front_amiibo_next(void);
static void front_amiibo_toast(NSString *message);
#endif
/* Mouse mode (the settings panel, runtime/gamepad.m): while it is on and the window has the keyboard, the window holds the
   pointer -- moved to the window's centre, detached from the mouse and hidden -- and sends the mouse's buttons and
   movement to gamepad.m. It lets go when the window loses the keyboard (Command-Tab, a click elsewhere), during text
   entry, while the settings panel is open and when mouse mode goes off (front_mouse_update). */
static BOOL mouseHeld;
static int textEntryOpen;
static void front_mouse_update(void);
int taa_enabled(void);   /* third_party/d2r_gfx/gfx/nvn/totk_taa.m: edge smoothing in the settings panel */
void taa_set(int on);
static uint64_t bootStartNS;
static _Atomic uint64_t presentedFrames;
static _Atomic int warmPending;
/* Counts foreground time after warm-up, including menus, like Screen Time.
   Diagnostic profiles have their own counter and never update the user's file. */
static TOTKPlaytime *playtime;
static NSTimer *playtimeTimer;
static BOOL playtimeSleeping;
static void front_playtime_tick(BOOL stopping) {
 if(!playtime)return;
 BOOL running=!stopping&&!playtimeSleeping&&NSApp.isActive&&window.isKeyWindow
  &&!window.miniaturized&&atomic_load(&presentedFrames)&&!atomic_load(&warmPending);
 [playtime tick:runtime_now_ns()/1e9 active:running];
 if(stopping)[playtime save];
}
static void front_playtime_start(void) {
 const char *profile=getenv("TOTK_PROFILE_DIR");
 NSString *dir=[NSString stringWithUTF8String:profile?profile:"user-data"];
 playtime=[[TOTKPlaytime alloc] initWithPath:[dir stringByAppendingPathComponent:@"playtime.json"]];
 /* Keep counting independent of HUD visibility, the legacy corner layout and its refresh timer. */
 playtimeTimer=[NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;front_playtime_tick(NO);}];
 [NSRunLoop.mainRunLoop addTimer:playtimeTimer forMode:NSRunLoopCommonModes];
 NSNotificationCenter *nc=NSWorkspace.sharedWorkspace.notificationCenter;
 for(NSString *name in @[NSWorkspaceWillSleepNotification,NSWorkspaceScreensDidSleepNotification,NSWorkspaceSessionDidResignActiveNotification])
  [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
   (void)n;front_playtime_tick(YES);playtimeSleeping=YES;
  }];
 for(NSString *name in @[NSWorkspaceDidWakeNotification,NSWorkspaceScreensDidWakeNotification,NSWorkspaceSessionDidBecomeActiveNotification])
  [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
   (void)n;playtimeSleeping=NO;[playtime tick:runtime_now_ns()/1e9 active:NO];
  }];
}
static CVDisplayLinkRef displayLink;
static _Atomic int focused;
static pthread_mutex_t vsyncLock=PTHREAD_MUTEX_INITIALIZER;
static void *vsyncEvents[16];
static unsigned vsyncCount;
void hle_bind_system_event(void *,int);
void hle_signal_system_event(void *);
/* TOTK_STATE_REPORTING (gfx/nvn/totk_state_report.m; absent in tests): the game's states for Apple's performance tools on
   macOS 27. Main-thread events only; each call stores a few values and returns. */
extern void totk_sr_start(const char *game,const char *version) __attribute__((weak_import));
extern void totk_sr_picture(int key,int visible) __attribute__((weak_import));
extern void totk_sr_window(int key,int visible) __attribute__((weak_import));
extern void totk_sr_view(int w,int h,int display_hz,int fullscreen) __attribute__((weak_import));
extern void totk_sr_closing(void) __attribute__((weak_import));
extern void totk_sr_settings(int open) __attribute__((weak_import));
int runtime_front_window_visible(void);   /* below: 1 seen, 0 covered, -1 not known yet */
void *front_metal_layer(void){return (__bridge void *)metalLayer;}
/* The start-up screen goes once a frame was presented and the warm-up is done: the player sees the game from here on. */
static void boot_overlay_hide(void){
 if(!bootOverlay||bootOverlay.hidden)return;
 bootOverlay.hidden=YES;
 if(totk_sr_picture)totk_sr_picture(window.isKeyWindow,runtime_front_window_visible()!=0);
}
void front_frame_presented(void){
 if(atomic_fetch_add_explicit(&presentedFrames,1,memory_order_relaxed)==0){
  fprintf(stderr,"[totk-boot] %.3f first presented frame\n",(runtime_now_ns()-bootStartNS)/1e9);
  dispatch_async(dispatch_get_main_queue(), ^{if(!atomic_load(&warmPending))boot_overlay_hide();});
 }
}
void runtime_boot_progress(const char *stage,uint64_t done,uint64_t total){
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;
  if(total){bootDetail.stringValue=[NSString stringWithFormat:@"%.1f / %.1f GB",done/1e9,total/1e9];
   bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
  else {bootDetail.stringValue=@(TOTK_UI("正在处理，请稍候","Working, please wait"));bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];}
 });
}
void runtime_boot_count(const char *stage,uint64_t done,uint64_t total){
 /* Steps counted in items, not bytes (the shader import: tens of thousands of files, minutes on a phone). */
 static const char *last;
 if(stage!=last){fprintf(stderr,"[totk-boot] %.3f %s\n",bootStartNS?(runtime_now_ns()-bootStartNS)/1e9:0,stage?stage:"startup");last=stage;}
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=[NSString stringWithFormat:@"%llu / %llu",(unsigned long long)done,(unsigned long long)total];
  if(total){bootProgress.indeterminate=NO;bootProgress.doubleValue=(double)done/(double)total*100.0;}
 });
}
void runtime_boot_status(const char *stage,const char *detail){
 if(bootStartNS)fprintf(stderr,"[totk-boot] %.3f %s — %s\n",(runtime_now_ns()-bootStartNS)/1e9,stage?stage:"startup",detail?detail:"");
 NSString *s=[NSString stringWithUTF8String:stage?stage:TOTK_UI("正在启动","Starting")];
 NSString *d=[NSString stringWithUTF8String:detail?detail:TOTK_UI("正在处理，请稍候","Working, please wait")];
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  bootStage.stringValue=s;bootDetail.stringValue=d;
  bootProgress.indeterminate=YES;[bootProgress startAnimation:nil];
 });
}
void runtime_warm_progress(uint64_t done,uint64_t total,uint64_t shaders,uint64_t shader_total,uint64_t pipelines,uint64_t pipeline_total){
 atomic_store(&warmPending,1);
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!bootOverlay||bootOverlay.hidden)return;
  double percent=total ? fmin(100.0,(double)done/(double)total*100.0) : 100.0;
  bootStage.stringValue=[NSString stringWithFormat:@(TOTK_UI("预热着色器与管线 %.0f%%","Warming shaders and pipelines %.0f%%")),floor(percent)];
  bootDetail.stringValue=[NSString stringWithFormat:@(TOTK_UI("着色器 %llu/%llu · 管线 %llu/%llu","shaders %llu/%llu · pipelines %llu/%llu")),
      (unsigned long long)shaders,(unsigned long long)shader_total,
      (unsigned long long)pipelines,(unsigned long long)pipeline_total];
  bootProgress.indeterminate=NO;
  bootProgress.doubleValue=percent;
 });
}
void runtime_warm_done(void){
 atomic_store(&warmPending,0);
 dispatch_async(dispatch_get_main_queue(), ^{if(atomic_load(&presentedFrames))boot_overlay_hide();});
}
uint64_t front_game_res(int docked){(void)docked;return (720ULL<<32)|1280;}
/* TOTK_ASSUME_FOCUS=1: unattended test runs. macOS refuses to activate an app launched from the background while the user is working in
   another one; the window then never becomes key, GetCurrentFocusState stays 0 and the game waits before its first frame. In this mode the
   game is told it is focused, and the window is shown without taking the keyboard from the user (scripted input does not need it). */
static int assume_focus(void){static int v=-1;if(v<0){const char *e=getenv("TOTK_ASSUME_FOCUS");v=e&&atoi(e);}return v;}
/* Keep the guest active when the macOS window loses key status. Native input is still cleared
   in windowDidResignKey so a held key cannot remain stuck while another app has focus. */
int runtime_front_focus(void){return 1;}
static CVReturn vsync_callback(CVDisplayLinkRef link,const CVTimeStamp *now,const CVTimeStamp *output,CVOptionFlags flags,CVOptionFlags *out,void *ctx){
 (void)link;(void)now;(void)output;(void)flags;(void)out;(void)ctx;
 pthread_mutex_lock(&vsyncLock);for(unsigned i=0;i<vsyncCount;i++)hle_signal_system_event(vsyncEvents[i]);pthread_mutex_unlock(&vsyncLock);return kCVReturnSuccess;
}
/* 1 / 0: the modifier key e (a flag change) is down / up; -1: not one the layout takes (Command, Caps Lock, fn). Each side
   has its own device bit; a flag change without them (a synthesized event) goes by the shared flag. */
static int front_modifier_down(NSEvent *e){
 NSEventModifierFlags f=e.modifierFlags,shared;unsigned long side,pair;
 switch(e.keyCode){
  case 56:shared=NSEventModifierFlagShift;side=0x2;pair=0x6;break;case 60:shared=NSEventModifierFlagShift;side=0x4;pair=0x6;break;
  case 59:shared=NSEventModifierFlagControl;side=0x1;pair=0x2001;break;case 62:shared=NSEventModifierFlagControl;side=0x2000;pair=0x2001;break;
  case 58:shared=NSEventModifierFlagOption;side=0x20;pair=0x60;break;case 61:shared=NSEventModifierFlagOption;side=0x40;pair=0x60;break;
  default:return -1;}
 if(!(f&shared))return 0;
 return f&pair?!!(f&side):1;
}
@interface TOTKInputView:NSView
@property(strong) NSTimer *cursorHideTimer;
@property BOOL cursorAutoHideActive;
@property BOOL cursorIsHidden;
-(void)setCursorAutoHideEnabled:(BOOL)enabled;
@end
@implementation TOTKInputView
-(BOOL)acceptsFirstResponder{return YES;}
/* Amiibo entry stays available alongside the upstream keyboard/mouse layout and settings tabs. */
-(void)keyDown:(NSEvent *)e{
#ifdef GAME_BOTW160
 if(!settingsOpen&&!textEntryOpen&&e.keyCode==0&&(e.modifierFlags&NSEventModifierFlagOption)){amiibo_panel_show(!amiiboPanelOpen);return;}
 if(amiiboPanelOpen){if(e.keyCode==53)amiibo_panel_show(0);return;}
 if(modManagerOpen){if(e.keyCode==18)settings_show(0);else if(e.keyCode==53)mod_manager_show(0);return;}
#endif
 if(textEntryOpen)return;
#ifdef GAME_BOTW160
 if(!settingsOpen&&e.keyCode==19&&!(e.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))){
  KeyMap keymap;runtime_keymap_get(&keymap);
  BOOL conflict=keymap_action_of(&keymap,(int)e.keyCode,NULL)>=0;
  if(!conflict){if(!e.isARepeat)front_amiibo_next();return;}
  if(!e.isARepeat)front_amiibo_toast(@(TOTK_UI("按键 2 已绑定游戏操作，请在键位设置中解除","Key 2 is bound to a game action; clear it in Key bindings")));
 }
#endif
 if(settingsOpen&&e.keyCode!=18){if(e.keyCode==53)settings_show(0);return;}runtime_input_key(e.keyCode,1);}
-(void)keyUp:(NSEvent *)e{
#ifdef GAME_BOTW160
 if(amiiboPanelOpen||modManagerOpen)return;
#endif
 runtime_input_key(e.keyCode,0);}
-(void)flagsChanged:(NSEvent *)e{
#ifdef GAME_BOTW160
 if(amiiboPanelOpen||modManagerOpen)return;
#endif
 int down=front_modifier_down(e);
 if(down>=0&&(!(settingsOpen||textEntryOpen)||!down))runtime_input_key(e.keyCode,down);
}
/* The game has no mouse controls. In native full screen, keep the pointer out of the picture while idle, but show it again
   as soon as it moves; restore it when the window loses focus or leaves full screen. */
-(void)hideCursorIfIdle:(NSTimer *)timer{
 (void)timer;self.cursorHideTimer=nil;
 if(!self.cursorAutoHideActive||!self.window.isKeyWindow||!(self.window.styleMask&NSWindowStyleMaskFullScreen))return;
 if(!self.cursorIsHidden){[NSCursor hide];self.cursorIsHidden=YES;}
}
-(void)mouseMoved:(NSEvent *)e{
 if(mouseHeld){runtime_mouse_move(e.deltaX,e.deltaY);return;}
 if(!self.cursorAutoHideActive)return;
 [self.cursorHideTimer invalidate];self.cursorHideTimer=nil;
 if(self.cursorIsHidden){[NSCursor unhide];self.cursorIsHidden=NO;}
 self.cursorHideTimer=[NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(hideCursorIfIdle:) userInfo:nil repeats:NO];
}
-(void)mouseDragged:(NSEvent *)e{if(mouseHeld)runtime_mouse_move(e.deltaX,e.deltaY);}
-(void)rightMouseDragged:(NSEvent *)e{if(mouseHeld)runtime_mouse_move(e.deltaX,e.deltaY);}
-(void)otherMouseDragged:(NSEvent *)e{if(mouseHeld)runtime_mouse_move(e.deltaX,e.deltaY);}
-(void)mouseDown:(NSEvent *)e{(void)e;if(mouseHeld)runtime_mouse_button(0,1);}
-(void)mouseUp:(NSEvent *)e{(void)e;runtime_mouse_button(0,0);}
-(void)rightMouseDown:(NSEvent *)e{(void)e;if(mouseHeld)runtime_mouse_button(1,1);}   /* no context menu */
-(void)rightMouseUp:(NSEvent *)e{(void)e;runtime_mouse_button(1,0);}
-(void)otherMouseDown:(NSEvent *)e{if(mouseHeld)runtime_mouse_button((int)e.buttonNumber,1);}   /* 2 middle, 3 and 4 the side buttons */
-(void)otherMouseUp:(NSEvent *)e{runtime_mouse_button((int)e.buttonNumber,0);}
-(void)setCursorAutoHideEnabled:(BOOL)enabled{
 self.cursorAutoHideActive=enabled;
 [self.cursorHideTimer invalidate];self.cursorHideTimer=nil;
 if(enabled){
  self.window.acceptsMouseMovedEvents=YES;
  self.cursorHideTimer=[NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(hideCursorIfIdle:) userInfo:nil repeats:NO];
 }else{
  if(self.cursorIsHidden){[NSCursor unhide];self.cursorIsHidden=NO;}
  self.window.acceptsMouseMovedEvents=mouseHeld;
 }
}
@end
static void front_mouse_update(void){   /* main thread; also runtime/gamepad.m's hook when mouse mode changes */
 BOOL want=window&&runtime_mouse_enabled()&&window.isKeyWindow&&!textEntryOpen&&!settingsOpen
#ifdef GAME_BOTW160
  &&!amiiboPanelOpen&&!modManagerOpen
#endif
  ;
 if(want==mouseHeld)return;
 mouseHeld=want;
 if(want){
  NSRect f=[window convertRectToScreen:window.contentView.frame];CGFloat top=NSMaxY(NSScreen.screens.firstObject.frame);
  CGWarpMouseCursorPosition(CGPointMake(NSMidX(f),top-NSMidY(f)));   /* clicks land in the window */
  CGAssociateMouseAndMouseCursorPosition(false);[NSCursor hide];window.acceptsMouseMovedEvents=YES;
 }else{
  CGAssociateMouseAndMouseCursorPosition(true);[NSCursor unhide];runtime_mouse_release();
  window.acceptsMouseMovedEvents=((TOTKInputView *)window.contentView).cursorAutoHideActive;
 }
 fprintf(stderr,"[totk] mouse %s\n",want?"held by the window (the settings panel, key 1, or Command-Tab lets it go)":"let go");
}
enum { FPS_GRAPH_SAMPLES = 61, FPS_GRAPH_WIDTH = 220, FPS_GRAPH_HEIGHT = 90 };
@interface TOTKHudBox:NSView
@property(strong) NSTextField *label;
@property(strong) NSTimer *timer;
@property NSSize textSize;
-(void)position;
-(void)refresh;
@end
/* Compact HUD (default): one small box in the window's top-right corner with the FPS, shader and load lines (published by
   gfx/nvn/fps_overlay.c, refreshed twice a second); the settings panel's overlay row picks all, FPS + playtime or none.
   TOTK_HUD=corners: the lines stay in the picture's corners and there is no box. */
static int settings_pad_family(void);                 /* settings_panel.h: the controller family button names follow */
static NSString *settings_panel_pad_text(int family);  /* settings_panel.h: the controller's way to the panel */
/* The box's last line (user 2026-10-30): how to open the settings panel, as it is bound now: key 1, and with a
   controller connected its button or chord (L3 + R3 unless the key bindings set one). */
static NSString *hud_settings_hint(void) {
 int detected=-1;runtime_gamepad_type(&detected);
 if(detected<=GAMEPAD_TYPE_AUTO)return @(TOTK_UI("设置：键盘 1","Settings: key 1"));
 return [NSString stringWithFormat:@(TOTK_UI("设置：键盘 1 · 手柄 %@","Settings: key 1 · controller %@")),settings_panel_pad_text(settings_pad_family())];
}
@implementation TOTKHudBox
-(instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){self.wantsLayer=YES;self.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0.04 alpha:0.72].CGColor;self.layer.cornerRadius=7;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:0.14].CGColor;
 self.label=[NSTextField labelWithString:@""];self.label.alignment=NSTextAlignmentLeft;self.label.maximumNumberOfLines=0;self.label.lineBreakMode=NSLineBreakByClipping;[self addSubview:self.label];
 [self refresh];if(hud_compact()){__weak TOTKHudBox *weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;[weak refresh];}];}}return self;}
-(void)refresh{
 BOOL showText=hud_compact()&&fps_overlay_hud_mode()!=HUD_MODE_OFF;
 self.hidden=!showText&&!fpsGraphEnabled;self.label.hidden=!showText;
 if(showText){
  NSFont *mono=[NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium];
  NSColor *green=[NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1],*yellow=[NSColor colorWithCalibratedRed:1 green:230/255.0 blue:40/255.0 alpha:1];
  NSMutableAttributedString *a=[NSMutableAttributedString new];
  int full=fps_overlay_full_hud();   // FPS only: the FPS line (line 0); the others keep their last text, so skip them
  for(int i=0;i<4;i++){char t[128];int hl=0;if((!full&&i!=0)||!hud_snapshot(i,t,sizeof t,&hl))continue;   // FPS, shaders, render pipelines, load
   [a appendAttributedString:[[NSAttributedString alloc] initWithString:[([NSString stringWithUTF8String:t] ?: @"") stringByAppendingString:@"\n"] attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:hl?yellow:green}]];}
  if(!a.length)[a appendAttributedString:[[NSAttributedString alloc] initWithString:@"FPS --\n" attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:green}]];
  if(playtime)[a appendAttributedString:[[NSAttributedString alloc] initWithString:[playtime.text stringByAppendingString:@"\n"]
   attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:green}]];
  int bpct=runtime_gamepad_battery_percent(),bleft=runtime_gamepad_battery_left_percent();
  if(bpct>=0)[a appendAttributedString:[[NSAttributedString alloc] initWithString:bleft>=0?[NSString stringWithFormat:@(TOTK_UI("手柄电量 左 %d%% 右 %d%%\n","Controller L %d%% R %d%%\n")),bleft,bpct]:[NSString stringWithFormat:@(TOTK_UI("手柄电量 %d%%\n","Controller %d%%\n")),bpct]
   attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:green}]];
  /* The commit the app was built from (user 2026-10-25), last and grey: TOTK_SOURCE_COMMIT from the launcher. */
  const char *commit=getenv("TOTK_SOURCE_COMMIT");
  if(commit&&*commit)[a appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@(TOTK_UI("版本 %s\n","build %s\n")),commit]
   attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.6 alpha:1]}]];
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:[hud_settings_hint() stringByAppendingString:@"\n"]
   attributes:@{NSFontAttributeName:mono,NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.6 alpha:1]}]];
  [a deleteCharactersInRange:NSMakeRange(a.length-1,1)];   // no empty line under the last one
  BOOL changed=![a isEqualToAttributedString:self.label.attributedStringValue];
  if(changed)self.label.attributedStringValue=a;
  if(changed||self.textSize.height==0){
   NSSize z=[self.label sizeThatFits:NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX)];
   self.textSize=NSMakeSize(ceil(z.width),ceil(z.height));
  }
 }else self.textSize=NSZeroSize;
 [self position];}
-(NSView *)hitTest:(NSPoint)p{(void)p;return nil;}
-(void)viewDidMoveToSuperview{[super viewDidMoveToSuperview];[self position];}
-(void)layout{[super layout];[self position];}
-(void)position{if(!self.superview)return;
 CGFloat graphH=fpsGraphEnabled?FPS_GRAPH_HEIGHT:0,graphW=fpsGraphEnabled?FPS_GRAPH_WIDTH:0;
 CGFloat contentW=fmax(self.textSize.width,graphW);
 CGFloat w=contentW+16,h=self.textSize.height+graphH+10,m=10;
 NSRect f=NSMakeRect(floor(self.superview.bounds.size.width-w-m),floor(self.superview.bounds.size.height-h-m),w,h);
 if(!NSEqualRects(self.frame,f))self.frame=f;
 self.label.frame=NSMakeRect(8,graphH+5,self.textSize.width,self.textSize.height);
 if(fpsGraphEnabled)fpsGraphBox.frame=NSMakeRect(8,5,contentW,FPS_GRAPH_HEIGHT);}
@end
@interface TOTKFpsGraph:NSView {
 int _samples[FPS_GRAPH_SAMPLES];
 NSUInteger _sampleCount;
}
@property(strong) NSTimer *timer;
-(void)setEnabled:(BOOL)enabled;
-(void)sample;
@end
@implementation TOTKFpsGraph
-(instancetype)initWithFrame:(NSRect)frame {
 if((self=[super initWithFrame:frame]))self.hidden=YES;
 return self;
}
-(void)setEnabled:(BOOL)enabled {
 self.hidden=!enabled;
 [self.timer invalidate];
 self.timer=nil;
 _sampleCount=0;
 if(!enabled)return;

 [self sample];
 __weak TOTKFpsGraph *weak=self;
 self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;[weak sample];}];
}
-(void)sample {
 int fps=fps_overlay_value();
 if(_sampleCount<FPS_GRAPH_SAMPLES)_samples[_sampleCount++]=fps;
 else {
  for(NSUInteger i=1;i<FPS_GRAPH_SAMPLES;i++)_samples[i-1]=_samples[i];
  _samples[FPS_GRAPH_SAMPLES-1]=fps;
 }
 [self setNeedsDisplay:YES];
}
-(void)drawRect:(NSRect)dirtyRect {
 (void)dirtyRect;
 int minFPS=-1,maxFPS=-1;
 for(NSUInteger i=0;i<_sampleCount;i++) {
  int fps=_samples[i];
  if(fps<0)continue;
  if(minFPS<0||fps<minFPS)minFPS=fps;
  if(fps>maxFPS)maxFPS=fps;
 }

 int currentFPS=_sampleCount?_samples[_sampleCount-1]:-1;
 NSString *currentText=currentFPS<0?@"--":[NSString stringWithFormat:@"%d",currentFPS];
 NSString *stats=maxFPS<0?@"min --   max --   cur --":
  [NSString stringWithFormat:@"min %d   max %d   cur %@",minFPS,maxFPS,currentText];
 NSDictionary *statsStyle=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightMedium],
  NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.88 alpha:1]};
 [stats drawAtPoint:NSMakePoint(8,58) withAttributes:statsStyle];
 if(maxFPS<0)return;

 NSRect plot=NSMakeRect(40,12,self.bounds.size.width-50,36);
 double axisLow=0,axisHigh=fmax(30,ceil(maxFPS*1.10/30)*30);
 double axisMid=(axisLow+axisHigh)/2;

 NSColor *axisColor=[NSColor colorWithCalibratedWhite:0.75 alpha:0.65];
 NSColor *gridColor=[NSColor colorWithCalibratedWhite:0.75 alpha:0.18];
 NSBezierPath *grid=[NSBezierPath bezierPath];
 CGFloat midY=NSMinY(plot)+(axisMid-axisLow)/(axisHigh-axisLow)*plot.size.height;
 [grid moveToPoint:NSMakePoint(NSMinX(plot),midY)];
 [grid lineToPoint:NSMakePoint(NSMaxX(plot),midY)];
 [gridColor setStroke];
 grid.lineWidth=0.5;
 [grid stroke];

 NSBezierPath *axis=[NSBezierPath bezierPath];
 [axis moveToPoint:NSMakePoint(35,NSMinY(plot))];
 [axis lineToPoint:NSMakePoint(35,NSMaxY(plot))];
 NSDictionary *axisStyle=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular],
  NSForegroundColorAttributeName:axisColor};
 double axisLabels[]={axisLow,axisMid,axisHigh};
 for(int i=0;i<3;i++) {
  CGFloat y=NSMinY(plot)+(axisLabels[i]-axisLow)/(axisHigh-axisLow)*plot.size.height;
  [axis moveToPoint:NSMakePoint(35,y)];
  [axis lineToPoint:NSMakePoint(39,y)];
  [[NSString stringWithFormat:@"%.0f",axisLabels[i]] drawAtPoint:NSMakePoint(8,y-5) withAttributes:axisStyle];
 }
 [axisColor setStroke];
 axis.lineWidth=0.75;
 [axis stroke];

 NSBezierPath *line=[NSBezierPath bezierPath];
 NSPoint last=NSZeroPoint;
 NSUInteger points=0;
 for(NSUInteger i=0;i<_sampleCount;i++) {
  int fps=_samples[i];
  if(fps<0)continue;
  double xFraction=(double)i/(FPS_GRAPH_SAMPLES-1);
  double yFraction=fmax(0,fmin(1,(fps-axisLow)/(axisHigh-axisLow)));
  NSPoint point=NSMakePoint(NSMinX(plot)+xFraction*plot.size.width,
                            NSMinY(plot)+yFraction*plot.size.height);
  if(points)[line lineToPoint:point];else[line moveToPoint:point];
  last=point;
  points++;
 }

 NSColor *totk_colour=[NSColor colorWithCalibratedRed:0.541 green:0.969 blue:0.588 alpha:1];
 [totk_colour setStroke];
 [totk_colour setFill];
 line.lineWidth=1.5;
 [line stroke];
 if(points==1)[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(last.x-1,last.y-1,2,2)] fill];
}
@end
#include "settings_panel.h"
#include "mod_manager_panel.h"

/* The live FPS in the menu bar: a menu of the game's own, after its app menu on the left, whose title is the frame rate
   ("60 FPS", "50+50 FPS" while frame interpolation shows generated frames), refreshed twice a second with the value the
   overlay uses. Part of the app's own menu bar, so macOS shows it whenever the game is in front (a status item next to
   the clock can be hidden by System Settings > Menu Bar). Independent of key 1; hidden in full screen with the menu bar.
   TOTK_MENUBAR_FPS=0 leaves the menu bar alone. */
extern int dm_gfx_fps_now(int *generated) __attribute__((weak_import));   // gfx/nvn/nvn_mtl.m (absent in tests)
static NSMenu *fpsMenu;static NSMenuItem *fpsMenuItem;static NSTimer *fpsTimer;
static int menubar_fps_enabled(void){const char *e=getenv("TOTK_MENUBAR_FPS");return !(e&&!strcmp(e,"0"));}
static void front_menubar_fps_add(NSMenu *bar){   // from front_install_menu
 if(!menubar_fps_enabled())return;
 fpsMenu=[[NSMenu alloc] initWithTitle:@"FPS --"];
 NSMenuItem *about=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("实时帧率（TOTK_MENUBAR_FPS=0 可隐藏）","Live frame rate (TOTK_MENUBAR_FPS=0 hides it)")) action:nil keyEquivalent:@""];
 about.enabled=NO;[fpsMenu addItem:about];fpsMenu.autoenablesItems=NO;
 const char *commit=getenv("TOTK_SOURCE_COMMIT");   /* the commit the app was built from (build_app.py, the launcher) */
 if(commit&&*commit){NSMenuItem *build=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@(TOTK_UI("版本 %s","Build %s")),commit] action:nil keyEquivalent:@""];build.enabled=NO;[fpsMenu addItem:build];}
 fpsMenuItem=[[NSMenuItem alloc] initWithTitle:@"FPS --" action:nil keyEquivalent:@""];fpsMenuItem.submenu=fpsMenu;[bar addItem:fpsMenuItem];
}
/* TOTK_TITLE_FPS=1: the window title also ends in the frame rate ("Tears of the Kingdom  Mac — Ver. 1.4.3 — 60 FPS"),
   kept after whatever title the game set. Off by default: the menu bar already shows it. */
static int title_fps_enabled(void){const char *e=getenv("TOTK_TITLE_FPS");return e&&!strcmp(e,"1");}
static NSString *titleBase,*titleShown;
static void front_title_fps(NSString *fps){
 if(!title_fps_enabled()||!window)return;
 NSString *now=window.title;
 if(!titleShown||![now isEqualToString:titleShown])titleBase=now;   // the game changed its title: keep that one as the base
 titleShown=[NSString stringWithFormat:@"%@ — %@",titleBase,fps];
 if(![now isEqualToString:titleShown])window.title=titleShown;
}
static void front_menubar_fps(void){   // starts the refresh once the window exists
 if((!fpsMenu&&!title_fps_enabled())||fpsTimer)return;
 fpsTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){(void)t;
  int gen=0,fps=dm_gfx_fps_now?dm_gfx_fps_now(&gen):-1;
  NSString *title=fps<0?@"FPS --":gen>0?[NSString stringWithFormat:@"%d+%d FPS",fps,gen]:[NSString stringWithFormat:@"%d FPS",fps];
  if(fpsMenu&&![fpsMenu.title isEqualToString:title]){fpsMenu.title=title;fpsMenuItem.title=title;}
  front_title_fps(title);}];
}
/* The drawable follows the window's pixel size; the present pass scales the game picture (1920x1080 docked) into it and
   keeps 16:9 (black bars on other shapes), so a larger window or full screen shows the game at its own resolution instead
   of a fixed small drawable that the compositor stretches. */
/* TOTK_DRAWABLE_SCALE=<f> (test scripts only): the drawable is that many times the window's pixels and the window server
   scales it down for the screen. It lets a test exercise the 2K output path (a 2560x1440 picture) on a screen smaller than
   that (2026-10-17: the Mac reported a 1920x1080 display); the desktop launcher never sets it. */
static CGFloat drawable_scale(void){static CGFloat f=-1;if(f<0){const char *e=getenv("TOTK_DRAWABLE_SCALE");f=e?atof(e):1;if(f<0.25||f>4)f=1;}return f;}
/* TOTK_STATE_REPORTING: the drawable, the refresh rate of the screen the window is on, full screen. */
static void front_sr_view(void){
 if(!totk_sr_view||!window||!metalLayer)return;
 CGSize px=metalLayer.drawableSize;
 totk_sr_view((int)px.width,(int)px.height,window.screen?(int)window.screen.maximumFramesPerSecond:0,(window.styleMask&NSWindowStyleMaskFullScreen)!=0);
}
static void front_sr_window(void){if(totk_sr_window&&window)totk_sr_window(window.isKeyWindow,runtime_front_window_visible()!=0);}
static void front_sync_drawable(void){
 NSView *v=window.contentView;if(!v||!metalLayer)return;
 CGFloat s=window.backingScaleFactor>0?window.backingScaleFactor:1,ts=drawable_scale();CGSize px=CGSizeMake(round(v.bounds.size.width*s*ts),round(v.bounds.size.height*s*ts));
 if(px.width<1||px.height<1||CGSizeEqualToSize(metalLayer.drawableSize,px))return;
 metalLayer.contentsScale=s;metalLayer.drawableSize=px;fprintf(stderr,"[totk] window drawable %.0fx%.0f (scale %.0f)\n",px.width,px.height,s);runtime_aspect_view(px.width,px.height);
 front_sr_view();
}
/* BotW, the settings panel's aspect ratio: the window takes the selected camera ratio. Keep the chosen height across toggles, even when a wide
   window has to shrink to fit the display; a manual resize establishes a new height. AppKit stays on the main queue. */
void runtime_front_resize_aspect(double ratio){
 if(!isfinite(ratio)||ratio<0.5||ratio>8)return;
 dispatch_async(dispatch_get_main_queue(), ^{
  if(!window||(window.styleMask&NSWindowStyleMaskFullScreen))return;
  NSScreen *screen=window.screen?:NSScreen.mainScreen;if(!screen)return;
  static NSSize lastSize;static CGFloat preferredHeight;
  NSRect oldFrame=window.frame;NSSize current=window.contentView.bounds.size;
  if(preferredHeight<=0||fabs(current.width-lastSize.width)>1||fabs(current.height-lastSize.height)>1)preferredHeight=current.height;
  NSRect visible=screen.visibleFrame;
  NSRect content=[window contentRectForFrameRect:visible];
  CGFloat h=fmin(preferredHeight,fmin(content.size.height,content.size.width/ratio));
  if(h<=0)return;
  NSRect frame=[window frameRectForContentRect:NSMakeRect(0,0,round(h*ratio),round(h))];
  frame.origin=NSMakePoint(NSMidX(oldFrame)-frame.size.width/2,NSMidY(oldFrame)-frame.size.height/2);
  frame.origin.x=fmax(NSMinX(visible),fmin(frame.origin.x,NSMaxX(visible)-frame.size.width));
  frame.origin.y=fmax(NSMinY(visible),fmin(frame.origin.y,NSMaxY(visible)-frame.size.height));
  [window setFrame:frame display:YES];
  lastSize=window.contentView.bounds.size;
  front_sync_drawable();
 });
}
@interface TOTKWindowDelegate:NSObject<NSWindowDelegate>
@end
@implementation TOTKWindowDelegate
-(void)windowDidBecomeKey:(NSNotification *)n{(void)n;front_playtime_tick(NO);atomic_store(&focused,1);if(window.styleMask&NSWindowStyleMaskFullScreen)[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:YES];runtime_oe_push_message(15);front_mouse_update();fprintf(stderr,"[totk] window gained focus\n");front_sr_window();}
-(void)windowDidResignKey:(NSNotification *)n{(void)n;front_playtime_tick(YES);atomic_store(&focused,0);[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:NO];front_mouse_update();runtime_input_clear();runtime_oe_push_message(15);fprintf(stderr,"[totk] window lost focus\n");front_sr_window();}
/* The process ends with the window. Save writes go straight to the files (runtime/fs_host.c), so a close in the middle of a
   save waits (up to 15 s, the window already gone) until the game has written and committed it (runtime_fs_save_busy). */
-(void)windowWillClose:(NSNotification *)n{(void)n;front_playtime_tick(YES);
 if(totk_sr_closing)totk_sr_closing();
 [(TOTKInputView *)window.contentView setCursorAutoHideEnabled:NO];
 if(mouseHeld){mouseHeld=NO;CGAssociateMouseAndMouseCursorPosition(true);[NSCursor unhide];}
 runtime_triggers_release();   /* _exit skips atexit; a save can also keep the game running a while without its window */
 if(!runtime_fs_save_busy()){fprintf(stderr,"[totk] window closed; graceful guest shutdown pending\n");_exit(0);}
 fprintf(stderr,"[totk] window closed while the game is saving: quitting when the save is done\n");
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
  uint64_t t0=runtime_now_ns();while(runtime_fs_save_busy()&&runtime_now_ns()-t0<15000000000ull)usleep(20000);
  fprintf(stderr,"[totk] save %s after %.2f s; quitting\n",runtime_fs_save_busy()?"still in progress (gave up)":"done",(runtime_now_ns()-t0)/1e9);_exit(0);});
}
-(void)windowDidResize:(NSNotification *)n{(void)n;front_sync_drawable();}
-(void)windowDidEnterFullScreen:(NSNotification *)n{(void)n;[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:window.isKeyWindow];front_sr_view();}
-(void)windowDidExitFullScreen:(NSNotification *)n{(void)n;[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:NO];front_sr_view();}
-(void)windowDidChangeScreen:(NSNotification *)n{(void)n;front_sr_view();}
/* Whether any part of the window can be seen (TOTK, 2026-10-16 night): macOS stops the display link's callbacks for a
   fully covered window, so presents stop and per-picture measurements of that stretch are void; a test session's log
   says when (the user working in other apps covered the test windows of the frame interpolation tests). */
static _Atomic int windowVisible=-1;   /* -1 not known yet; read by the present path's stall lines (runtime_front_window_visible) */
static void note_occlusion(const char *when){int v=(window.occlusionState&NSWindowOcclusionStateVisible)!=0;atomic_store(&windowVisible,v);
 fprintf(stderr,"[totk] window %s%s (frame %llu)\n",v?"visible":"covered (or on another Space): no presents until it is visible again",when,(unsigned long long)dm_nvn_frame_count());
 front_sr_window();}
-(void)windowDidChangeOcclusionState:(NSNotification *)n{(void)n;note_occlusion("");}
-(void)windowDidChangeBackingProperties:(NSNotification *)n{(void)n;front_sync_drawable();}
@end
static TOTKWindowDelegate *windowDelegate;
int runtime_front_window_visible(void){return atomic_load(&windowVisible);}
void runtime_front_request_close(void){dispatch_async(dispatch_get_main_queue(), ^{[window performClose:nil];});}
/* The 1.6.0 host can provide Emuiibo metadata or a raw Amiibo dump and trigger NFP detection in-game. */
#ifdef GAME_BOTW160
static BOOL front_amiibo_read_uint(id value, uint64_t max, uint64_t *out) {
 if(![value isKindOfClass:NSNumber.class])return NO;
 double number=[value doubleValue];
 if(!isfinite(number)||number<0||number>(double)max||floor(number)!=number)return NO;
 *out=(uint64_t)number;return YES;
}
static BOOL front_amiibo_read_date(id value,uint16_t *year,uint8_t *month,uint8_t *day) {
 if(![value isKindOfClass:NSDictionary.class])return NO;
 NSDictionary *date=value;uint64_t y,m,d;
 if(!front_amiibo_read_uint(date[@"y"],UINT16_MAX,&y)||!front_amiibo_read_uint(date[@"m"],12,&m)||m<1||
    !front_amiibo_read_uint(date[@"d"],31,&d)||d<1)return NO;
 *year=(uint16_t)y;*month=(uint8_t)m;*day=(uint8_t)d;return YES;
}
@class BOTWAmiiboMenuTarget, BOTWAmiiboPanel;
static BOTWAmiiboMenuTarget *amiiboMenuTarget;
static BOTWAmiiboPanel *amiiboPanel;
static NSString *amiiboCurrentID;
static NSURL *amiiboCurrentURL;
@interface BOTWAmiiboPanel:NSView
@property(strong) NSScrollView *listScrollView;
@property(strong) NSView *fileList;
@property(strong) NSTextField *folderLabel;
@property(strong) NSTextField *keyLabel;
@property(copy) NSArray<NSURL *> *files;
-(void)refreshFiles;
-(void)center;
@end
static NSString *front_amiibo_today_key(void) {
 NSCalendar *calendar=[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
 calendar.timeZone=NSTimeZone.localTimeZone;
 NSDateComponents *date=[calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:[NSDate date]];
 return [NSString stringWithFormat:@"%04ld-%02ld-%02ld",(long)date.year,(long)date.month,(long)date.day];
}
static NSString *front_amiibo_identifier(const RuntimeVirtualAmiibo *amiibo) {
 NSMutableString *identifier=[NSMutableString string];
 for(NSUInteger i=0;i<amiibo->uid_length;i++)[identifier appendFormat:@"%02x",amiibo->uuid[i]];
 return identifier;
}
static NSString *front_amiibo_identifier_for_url(NSURL *url) {
 NSError *error=nil;NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
 if(!data){fprintf(stderr,"[botw] cannot read Amiibo file for usage count: %s\n",error.localizedDescription.UTF8String);return nil;}
 RuntimeVirtualAmiibo amiibo={0};
 if([[url.pathExtension lowercaseString] isEqualToString:@"json"]){
  id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  NSArray *uuid=[parsed isKindOfClass:NSDictionary.class]&&[parsed[@"uuid"] isKindOfClass:NSArray.class]?parsed[@"uuid"]:nil;
  if(uuid.count!=10)return nil;
  uint64_t value=0;
  for(NSUInteger i=0;i<7;i++)if(!front_amiibo_read_uint(uuid[i],UINT8_MAX,&value))return nil;else amiibo.uuid[i]=(uint8_t)value;
 }else{
  if(data.length<7)return nil;
  memcpy(amiibo.uuid,data.bytes,7);
 }
 amiibo.uid_length=7;
 return front_amiibo_identifier(&amiibo);
}
static NSString *front_amiibo_key_path(NSURL *amiiboURL) {
 NSFileManager *manager=NSFileManager.defaultManager;
 NSString *directory=amiiboURL.URLByDeletingLastPathComponent.path;
 if(!directory.length)directory=[[NSUserDefaults.standardUserDefaults stringForKey:@"BOTWAmiiboFolder"] copy];
 if(directory.length){
  NSString *sameFolder=[directory stringByAppendingPathComponent:@"key_retail.bin"];
  if([manager fileExistsAtPath:sameFolder])return sameFolder;
 }
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 NSString *saved=[defaults stringForKey:@"BOTWAmiiboRetailKey"];
 if(saved.length)return saved;
 NSString *download=[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads/key_retail.bin"];
 return [manager fileExistsAtPath:download]?download:nil;
}
static NSData *front_amiibo_retail_key(NSURL *amiiboURL,NSString **problem) {
 NSString *path=front_amiibo_key_path(amiiboURL);
 if(!path){if(problem)*problem=@(TOTK_UI("请选择 key_retail.bin 解密密钥","Choose the key_retail.bin retail key first"));return nil;}
 NSError *error=nil;NSData *key=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
 if(!key){if(problem)*problem=error.localizedDescription;return nil;}
 if(key.length!=0xa0){if(problem)*problem=@(TOTK_UI("密钥文件大小无效，key_retail.bin 应为 160 字节","Invalid key file size; key_retail.bin must be 160 bytes"));return nil;}
 return key;
}
static NSString *front_amiibo_usage_prefix(NSString *identifier) { return [@"BOTWAmiiboUsage." stringByAppendingString:identifier]; }
static NSInteger front_amiibo_today_count(NSString *identifier) {
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSString *prefix=front_amiibo_usage_prefix(identifier);
 return [[defaults stringForKey:[prefix stringByAppendingString:@".date"]] isEqualToString:front_amiibo_today_key()]
  ?[defaults integerForKey:[prefix stringByAppendingString:@".today"]]:0;
}
static NSInteger front_amiibo_total_count(NSString *identifier) {
 return [NSUserDefaults.standardUserDefaults integerForKey:[front_amiibo_usage_prefix(identifier) stringByAppendingString:@".total"]];
}
static NSArray<NSURL *> *front_amiibo_files(NSString *folder,NSError **error) {
 NSArray<NSURL *> *urls=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:folder isDirectory:YES] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:error];
 if(!urls)return nil;
 return [urls sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];}];
}
static void front_amiibo_record_scan(void) {
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSString *prefix=front_amiibo_usage_prefix(amiiboCurrentID);
 NSString *date=front_amiibo_today_key();NSInteger today=front_amiibo_today_count(amiiboCurrentID)+1;
 NSInteger total=front_amiibo_total_count(amiiboCurrentID)+1;
 [defaults setObject:date forKey:[prefix stringByAppendingString:@".date"]];
 [defaults setInteger:today forKey:[prefix stringByAppendingString:@".today"]];
 [defaults setInteger:total forKey:[prefix stringByAppendingString:@".total"]];
 [amiiboPanel refreshFiles];
}
@interface BOTWAmiiboMenuTarget:NSObject
-(void)chooseAmiibo:(id)sender;
-(void)chooseAmiiboFolder:(id)sender;
-(void)chooseAmiiboKey:(id)sender;
-(void)simulateAmiiboScan:(id)sender;
-(void)scanAmiiboURL:(NSURL *)url;
-(BOOL)loadAmiiboURL:(NSURL *)url;
-(BOOL)parseAmiiboURL:(NSURL *)url into:(RuntimeVirtualAmiibo *)out error:(NSString **)outProblem;
@end
@implementation BOTWAmiiboMenuTarget
-(void)chooseAmiibo:(id)sender{
 (void)sender;
 NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=YES;panel.canChooseDirectories=NO;
 panel.allowsMultipleSelection=NO;panel.allowedFileTypes=@[@"json",@"bin"];
 panel.message=@(TOTK_UI("选择 Emuiibo JSON 或原始 Amiibo .bin 文件","Choose an Emuiibo JSON or raw Amiibo .bin file"));
 panel.prompt=@(TOTK_UI("加载 Amiibo","Load Amiibo"));
 if([panel runModal]!=NSModalResponseOK)return;
 if([self loadAmiiboURL:panel.URL])[amiiboPanel refreshFiles];
}
-(void)chooseAmiiboFolder:(id)sender{
 (void)sender;
 NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=NO;
 NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"BOTWAmiiboFolder"];
 if(saved.length)panel.directoryURL=[NSURL fileURLWithPath:saved isDirectory:YES];
 panel.message=@(TOTK_UI("选择存放 Amiibo 文件的文件夹","Choose the folder containing Amiibo files"));
 panel.prompt=@(TOTK_UI("使用此文件夹","Use This Folder"));
 if([panel runModal]!=NSModalResponseOK)return;
 [[NSUserDefaults standardUserDefaults] setObject:panel.URL.path forKey:@"BOTWAmiiboFolder"];
 [amiiboPanel refreshFiles];
}
-(void)chooseAmiiboKey:(id)sender{
 (void)sender;
 NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=YES;panel.canChooseDirectories=NO;panel.allowsMultipleSelection=NO;
 panel.allowedFileTypes=@[@"bin"];
 NSString *saved=front_amiibo_key_path(nil);if(saved.length)panel.directoryURL=[NSURL fileURLWithPath:saved].URLByDeletingLastPathComponent;
 panel.message=@(TOTK_UI("优先读取 Amiibo 文件同目录的 key_retail.bin；此处选择的密钥作为备用，不会复制进 App","key_retail.bin beside the Amiibo file takes priority; the selected key is a fallback and is not copied into the app"));
 panel.prompt=@(TOTK_UI("使用此密钥","Use This Key"));
 if([panel runModal]!=NSModalResponseOK)return;
 [[NSUserDefaults standardUserDefaults] setObject:panel.URL.path forKey:@"BOTWAmiiboRetailKey"];
 [amiiboPanel refreshFiles];
}
-(BOOL)parseAmiiboURL:(NSURL *)url into:(RuntimeVirtualAmiibo *)out error:(NSString **)outProblem{
 NSError *error=nil;NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error];
 BOOL isJSON=[[url.pathExtension lowercaseString] isEqualToString:@"json"];
 id parsed=data&&isJSON?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
 NSString *problem=nil;
 if(!data)problem=error.localizedDescription;
 else if(isJSON&&![parsed isKindOfClass:NSDictionary.class])problem=@(TOTK_UI("JSON 根节点无效","Invalid JSON root object"));
 RuntimeVirtualAmiibo amiibo={0};
 NSString *name=nil;
 if(!problem&&!isJSON){
  const uint8_t *bytes=data.bytes;
  if((data.length!=532&&data.length!=540)||bytes[0x10]!=0xa5||bytes[0x5b]!=0x02)
   problem=@(TOTK_UI("文件不是受支持的 532/540 字节 Amiibo 转储","File is not a supported 532/540-byte Amiibo dump"));
  else{
   memcpy(amiibo.uuid,bytes,7);amiibo.uid_length=7;
   amiibo.game_character_id=(uint16_t)bytes[0x54]|((uint16_t)bytes[0x55]<<8);
   amiibo.character_variant=bytes[0x56];amiibo.figure_type=bytes[0x57];
   amiibo.model_number=((uint16_t)bytes[0x58]<<8)|bytes[0x59];amiibo.series=bytes[0x5a];
   amiibo.write_counter=((uint16_t)bytes[0x11]<<8)|bytes[0x12];
   amiibo.first_write_year=amiibo.last_write_year=2000;
   amiibo.first_write_month=amiibo.last_write_month=1;
   amiibo.first_write_day=amiibo.last_write_day=1;
   name=[[url.lastPathComponent stringByDeletingPathExtension] copy];
   NSString *keyProblem=nil;NSData *key=front_amiibo_retail_key(url,&keyProblem);uint8_t plain[0x208];
   if(!key)problem=keyProblem;
   else if(!runtime_amiibo_decode(bytes,data.length,key.bytes,key.length,plain))
    problem=@(TOTK_UI("Amiibo 数据校验失败；请确认密钥与转储文件匹配且文件未损坏","Amiibo authentication failed; confirm the retail key matches this dump and the file is intact"));
   else{
    amiibo.application_area_exists=(plain[0x2c]&0x20)!=0;
    amiibo.application_area_id=((uint32_t)plain[0xb6]<<24)|((uint32_t)plain[0xb7]<<16)|((uint32_t)plain[0xb8]<<8)|plain[0xb9];
    memcpy(amiibo.application_area,plain+0xdc,sizeof amiibo.application_area);
    if(amiibo.game_character_id==0x0301&&amiibo.application_area_exists&&amiibo.application_area_id==0x1019c800){
     uint8_t oldLevel=amiibo.application_area[0x11],hearts=amiibo.application_area[0x12];
     amiibo.application_area[0x11]=40;
     fprintf(stderr,"[botw] Wolf Link TPHD app data %s: level %u -> 40, hearts raw %u\n",url.lastPathComponent.UTF8String,oldLevel,hearts);
    }
   }
  }
 }
 if(!problem&&isJSON){
  NSDictionary *json=parsed,*identity=json[@"id"];
  name=[json[@"name"] isKindOfClass:NSString.class]?json[@"name"]:nil;
  NSArray *uuid=[json[@"uuid"] isKindOfClass:NSArray.class]?json[@"uuid"]:nil;
  if(!name.length||![identity isKindOfClass:NSDictionary.class]||uuid.count!=10||
     !front_amiibo_read_date(json[@"first_write_date"],&amiibo.first_write_year,&amiibo.first_write_month,&amiibo.first_write_day)||
     !front_amiibo_read_date(json[@"last_write_date"],&amiibo.last_write_year,&amiibo.last_write_month,&amiibo.last_write_day))
   problem=@"文件不是受支持的 Emuiibo amiibo.json";
  uint64_t field=0;
  if(!problem){
   for(NSUInteger i=0;i<10;i++){if(!front_amiibo_read_uint(uuid[i],UINT8_MAX,&field)){problem=@"UUID 字节无效";break;}amiibo.uuid[i]=(uint8_t)field;}
   amiibo.uid_length=7;
  }
  if(!problem&&!front_amiibo_read_uint(identity[@"game_character_id"],UINT16_MAX,&field))problem=@"game_character_id 无效";else if(!problem)amiibo.game_character_id=(uint16_t)field;
  if(!problem&&!front_amiibo_read_uint(identity[@"character_variant"],UINT8_MAX,&field))problem=@"character_variant 无效";else if(!problem)amiibo.character_variant=(uint8_t)field;
  if(!problem&&!front_amiibo_read_uint(identity[@"figure_type"],UINT8_MAX,&field))problem=@"figure_type 无效";else if(!problem)amiibo.figure_type=(uint8_t)field;
  if(!problem&&!front_amiibo_read_uint(identity[@"model_number"],UINT16_MAX,&field))problem=@"model_number 无效";else if(!problem)amiibo.model_number=(uint16_t)field;
  if(!problem&&!front_amiibo_read_uint(identity[@"series"],UINT8_MAX,&field))problem=@"series 无效";else if(!problem)amiibo.series=(uint8_t)field;
  if(!problem&&!front_amiibo_read_uint(json[@"write_counter"],UINT16_MAX,&field))problem=@"write_counter 无效";else if(!problem)amiibo.write_counter=(uint16_t)field;
  if(!problem&&!front_amiibo_read_uint(json[@"version"],UINT16_MAX,&field))problem=@"version 无效";else if(!problem)amiibo.version=(uint16_t)field;
 }
 if(!problem&&!name.length)problem=@(TOTK_UI("文件名为空","The file name is empty"));
 if(problem){if(outProblem)*outProblem=problem;return NO;}
 NSString *shortName=[name substringToIndex:MIN((NSUInteger)10,name.length)];
 snprintf(amiibo.name,sizeof amiibo.name,"%s",shortName.UTF8String);
 *out=amiibo;return YES;
}
-(BOOL)loadAmiiboURL:(NSURL *)url{
 RuntimeVirtualAmiibo amiibo={0};NSString *problem=nil;
 if(![self parseAmiiboURL:url into:&amiibo error:&problem]){
  NSAlert *alert=[NSAlert new];alert.messageText=@(TOTK_UI("无法加载 Amiibo","Could not load Amiibo"));alert.informativeText=problem;
  [alert addButtonWithTitle:@(TOTK_UI("好","OK"))];[alert runModal];return NO;
 }
 if(!runtime_nfp_try_select(&amiibo)){front_amiibo_toast(@(TOTK_UI("上一张 Amiibo 仍在处理，请稍后","Previous Amiibo is still being processed")));return NO;}
 amiiboCurrentID=front_amiibo_identifier(&amiibo);amiiboCurrentURL=url;
 fprintf(stderr,"[botw] virtual Amiibo loaded\n");return YES;
}
-(void)simulateAmiiboScan:(id)sender{
 (void)sender;if(!amiiboCurrentID)return;
 if(!runtime_nfp_try_scan(NULL)){front_amiibo_toast(@(TOTK_UI("上一张 Amiibo 仍在处理，请稍后","Previous Amiibo is still being processed")));return;}
 front_amiibo_record_scan();
 fprintf(stderr,"[botw] virtual Amiibo scan requested: today=%ld total=%ld\n",(long)front_amiibo_today_count(amiiboCurrentID),(long)front_amiibo_total_count(amiiboCurrentID));
}
-(void)scanAmiiboURL:(NSURL *)url{
 RuntimeVirtualAmiibo amiibo={0};NSString *problem=nil;
 if(![self parseAmiiboURL:url into:&amiibo error:&problem]){
  NSAlert *alert=[NSAlert new];alert.messageText=@(TOTK_UI("无法加载 Amiibo","Could not load Amiibo"));alert.informativeText=problem;
  [alert addButtonWithTitle:@(TOTK_UI("好","OK"))];[alert runModal];return;
 }
 if(!runtime_nfp_try_scan(&amiibo)){front_amiibo_toast(@(TOTK_UI("上一张 Amiibo 仍在处理，请稍后","Previous Amiibo is still being processed")));return;}
 amiiboCurrentID=front_amiibo_identifier(&amiibo);amiiboCurrentURL=url;front_amiibo_record_scan();
}

@end
/* A temporary, non-interactive label in the game window. */
@interface BOTWAmiiboToast:NSView
@end
@implementation BOTWAmiiboToast
-(NSView *)hitTest:(NSPoint)point{(void)point;return nil;}
@end
static NSView *amiiboToast;
static void front_amiibo_toast(NSString *message){
 if(!window)return;
 [amiiboToast removeFromSuperview];
 CGFloat w=fmin(520,window.contentView.bounds.size.width-24),h=38;
 BOTWAmiiboToast *box=[[BOTWAmiiboToast alloc] initWithFrame:NSMakeRect((window.contentView.bounds.size.width-w)/2,window.contentView.bounds.size.height-h-18,w,h)];
 box.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin;box.wantsLayer=YES;
 box.layer.backgroundColor=[NSColor colorWithCalibratedWhite:0 alpha:.82].CGColor;box.layer.cornerRadius=8;
 NSTextField *label=[NSTextField labelWithString:message];label.frame=NSMakeRect(12,9,w-24,22);
 label.textColor=NSColor.whiteColor;label.alignment=NSTextAlignmentCenter;label.lineBreakMode=NSLineBreakByTruncatingMiddle;
 [box addSubview:label];[window.contentView addSubview:box];amiiboToast=box;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(amiiboToast==box){[box removeFromSuperview];amiiboToast=nil;}});
}
static void front_amiibo_next(void){
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 NSString *folder=[defaults stringForKey:@"BOTWAmiiboFolder"];
 if(!folder.length){front_amiibo_toast(@(TOTK_UI("请先在 1 菜单中选择 Amiibo 文件夹","Choose an Amiibo folder from the 1 menu first")));return;}
 NSError *error=nil;NSArray<NSURL *> *urls=front_amiibo_files(folder,&error);
 if(!urls){front_amiibo_toast([NSString stringWithFormat:@(TOTK_UI("无法读取 Amiibo 文件夹：%@","Cannot read Amiibo folder: %@")),error.localizedDescription]);return;}
 NSMutableArray<NSURL *> *files=[NSMutableArray array];
 for(NSURL *url in urls)if(([url.pathExtension.lowercaseString isEqualToString:@"bin"]||[url.pathExtension.lowercaseString isEqualToString:@"json"])&&[url.lastPathComponent caseInsensitiveCompare:@"key_retail.bin"]!=NSOrderedSame)[files addObject:url];
 if(!files.count){front_amiibo_toast(@(TOTK_UI("Amiibo 文件夹中没有可扫描的文件","No Amiibo files in the folder")));return;}
 NSString *lastFolder=[defaults stringForKey:@"BOTWAmiiboSequenceFolder"],*last=[defaults stringForKey:@"BOTWAmiiboSequenceLast"];
 NSUInteger start=0;
 if([lastFolder isEqualToString:folder]&&last){
  for(NSUInteger i=0;i<files.count;i++)if([files[i].lastPathComponent isEqualToString:last]){start=(i+1)%files.count;break;}
 }
 if(!amiiboMenuTarget)amiiboMenuTarget=[BOTWAmiiboMenuTarget new];
 for(NSUInteger skipped=0;skipped<files.count;skipped++){
  NSUInteger i=(start+skipped)%files.count;NSURL *url=files[i];RuntimeVirtualAmiibo amiibo={0};NSString *problem=nil;
  if(![amiiboMenuTarget parseAmiiboURL:url into:&amiibo error:&problem]){
   fprintf(stderr,"[botw] skipping invalid Amiibo %s: %s\n",url.lastPathComponent.UTF8String,problem.UTF8String);continue;
  }
  if(!runtime_nfp_try_scan(&amiibo)){front_amiibo_toast(@(TOTK_UI("上一张 Amiibo 仍在处理，请稍后再按 2","Previous Amiibo is still being processed; try 2 again")));return;}
  amiiboCurrentID=front_amiibo_identifier(&amiibo);amiiboCurrentURL=url;
  [defaults setObject:folder forKey:@"BOTWAmiiboSequenceFolder"];[defaults setObject:url.lastPathComponent forKey:@"BOTWAmiiboSequenceLast"];
  front_amiibo_record_scan();
  NSString *message=[NSString stringWithFormat:@(TOTK_UI("已请求扫描：%@（%lu/%lu）","Scan requested: %@ (%lu/%lu)")),url.lastPathComponent,(unsigned long)i+1,(unsigned long)files.count];
  if(skipped)message=[message stringByAppendingFormat:@(TOTK_UI(" · 跳过 %lu 个无效文件"," · skipped %lu invalid files")),(unsigned long)skipped];
  front_amiibo_toast(message);return;
 }
 front_amiibo_toast(@(TOTK_UI("没有可用的 Amiibo 文件，请检查文件夹","No valid Amiibo files; check the folder")));
}
@implementation BOTWAmiiboPanel
-(instancetype)init{
 CGFloat w=620,h=fmin(540,window.contentView.bounds.size.height-32);
 if(!(self=[super initWithFrame:NSMakeRect(0,0,w,h)]))return nil;
 self.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
 self.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];self.wantsLayer=YES;
 self.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.10 green:0.16 blue:0.20 alpha:0.97].CGColor;
 self.layer.cornerRadius=12;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:0.16].CGColor;
 NSTextField *title=[NSTextField labelWithString:@(TOTK_UI("虚拟 Amiibo","Virtual Amiibo"))];
 title.font=[NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];title.textColor=NSColor.whiteColor;title.frame=NSMakeRect(22,h-48,400,28);[self addSubview:title];
 NSTextField *hint=[NSTextField labelWithString:@(TOTK_UI("点击列表中 Amiibo 后面的扫描按钮 · 也可从 1 菜单打开 · Esc 关闭面板","Click Scan beside an Amiibo · also available from the 1 menu · Esc closes this panel"))];
 hint.font=[NSFont systemFontOfSize:12];hint.textColor=[NSColor colorWithCalibratedWhite:0.75 alpha:1];hint.frame=NSMakeRect(22,h-78,w-44,20);[self addSubview:hint];
 NSButton *close=[NSButton buttonWithTitle:@"✕" target:self action:@selector(close:)];close.bordered=NO;close.refusesFirstResponder=YES;
 close.font=[NSFont systemFontOfSize:15 weight:NSFontWeightBold];close.contentTintColor=NSColor.whiteColor;close.frame=NSMakeRect(w-48,h-48,28,28);[self addSubview:close];
 NSButton *folder=[NSButton buttonWithTitle:@(TOTK_UI("选择文件夹…","Choose Folder…")) target:self action:@selector(chooseFolder:)];
 folder.frame=NSMakeRect(22,h-128,145,30);folder.refusesFirstResponder=YES;[self addSubview:folder];
 self.folderLabel=[NSTextField labelWithString:@""];self.folderLabel.font=[NSFont systemFontOfSize:12];
 self.folderLabel.textColor=[NSColor colorWithCalibratedWhite:0.78 alpha:1];self.folderLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 self.folderLabel.frame=NSMakeRect(180,h-128,w-202,30);[self addSubview:self.folderLabel];
 self.listScrollView=[[NSScrollView alloc] initWithFrame:NSMakeRect(22,62,w-44,h-210)];
 self.listScrollView.hasVerticalScroller=YES;self.listScrollView.borderType=NSBezelBorder;
 self.listScrollView.drawsBackground=YES;self.listScrollView.backgroundColor=[NSColor colorWithCalibratedWhite:0 alpha:0.12];
 self.fileList=[[NSView alloc] initWithFrame:NSMakeRect(0,0,self.listScrollView.contentSize.width,self.listScrollView.contentSize.height)];
 self.listScrollView.documentView=self.fileList;[self addSubview:self.listScrollView];
 NSButton *load=[NSButton buttonWithTitle:@(TOTK_UI("加载单个文件…","Load One File…")) target:self action:@selector(loadOneFile:)];
 load.frame=NSMakeRect(22,18,160,32);load.refusesFirstResponder=YES;[self addSubview:load];
 NSButton *key=[NSButton buttonWithTitle:@(TOTK_UI("选择解密密钥…","Choose Key…")) target:self action:@selector(chooseKey:)];
 key.frame=NSMakeRect(194,18,132,32);key.refusesFirstResponder=YES;[self addSubview:key];
 self.keyLabel=[NSTextField labelWithString:@""];self.keyLabel.font=[NSFont systemFontOfSize:11];
 self.keyLabel.textColor=[NSColor colorWithCalibratedWhite:0.78 alpha:1];self.keyLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 self.keyLabel.frame=NSMakeRect(338,20,w-360,28);[self addSubview:self.keyLabel];
 [self refreshFiles];return self;
}
-(void)refreshFiles{
 NSString *keyPath=front_amiibo_key_path(nil);
 self.keyLabel.stringValue=keyPath.length?[keyPath lastPathComponent]:@(TOTK_UI("原始 .bin 需要 key_retail.bin","Raw .bin files need key_retail.bin"));
 NSString *folder=[[NSUserDefaults standardUserDefaults] stringForKey:@"BOTWAmiiboFolder"];
 self.folderLabel.stringValue=folder.length?folder:@(TOTK_UI("尚未选择文件夹","No folder selected"));
 NSString *emptyMessage=nil;NSMutableArray<NSURL *> *files=[NSMutableArray array];
 if(!folder.length)emptyMessage=@(TOTK_UI("请先选择 Amiibo 文件夹","Choose an Amiibo folder first"));
 else{
  NSError *error=nil;NSArray<NSURL *> *urls=front_amiibo_files(folder,&error);
  if(!urls){fprintf(stderr,"[botw] cannot read Amiibo folder: %s\n",error.localizedDescription.UTF8String);emptyMessage=@(TOTK_UI("无法读取文件夹","Could not read folder"));}
  else for(NSURL *url in urls){
   NSString *extension=url.pathExtension.lowercaseString;
   if(([extension isEqualToString:@"bin"]||[extension isEqualToString:@"json"])&&[url.lastPathComponent caseInsensitiveCompare:@"key_retail.bin"]!=NSOrderedSame)[files addObject:url];
  }
  if(urls&&!files.count)emptyMessage=@(TOTK_UI("文件夹中没有 .bin 或 .json 文件","No .bin or .json files in this folder"));
 }
 self.files=files;
 CGFloat rowHeight=56,listWidth=self.listScrollView.contentSize.width;
 CGFloat documentHeight=fmax(self.listScrollView.bounds.size.height,self.files.count*rowHeight);
 self.fileList.frame=NSMakeRect(0,0,listWidth,documentHeight);
 for(NSView *view in self.fileList.subviews)[view removeFromSuperview];
 if(emptyMessage){
  NSTextField *empty=[NSTextField labelWithString:emptyMessage];empty.font=[NSFont systemFontOfSize:13];
  empty.textColor=[NSColor colorWithCalibratedWhite:0.75 alpha:1];empty.alignment=NSTextAlignmentCenter;
  empty.frame=NSMakeRect(12,(documentHeight-24)/2,listWidth-24,24);[self.fileList addSubview:empty];return;
 }
 [self.files enumerateObjectsUsingBlock:^(NSURL *url,NSUInteger index,BOOL *stop){
  (void)stop;CGFloat y=documentHeight-(index+1)*rowHeight;
  NSView *row=[[NSView alloc] initWithFrame:NSMakeRect(4,y+2,listWidth-8,rowHeight-4)];row.wantsLayer=YES;
  row.layer.backgroundColor=[NSColor colorWithCalibratedWhite:1 alpha:0.07].CGColor;row.layer.cornerRadius=6;
  NSString *identifier=front_amiibo_identifier_for_url(url);
  NSString *count=identifier?[NSString stringWithFormat:@(TOTK_UI("今日 %ld 次 · 累计 %ld 次","Today %ld · Total %ld")),(long)front_amiibo_today_count(identifier),(long)front_amiibo_total_count(identifier)]
                            :@(TOTK_UI("次数未知","Count unavailable"));
  NSTextField *countLabel=[NSTextField labelWithString:count];countLabel.font=[NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
  countLabel.textColor=[NSColor colorWithCalibratedWhite:0.78 alpha:1];countLabel.frame=NSMakeRect(12,27,listWidth-142,16);[row addSubview:countLabel];
  NSTextField *name=[NSTextField labelWithString:url.lastPathComponent];name.font=[NSFont systemFontOfSize:12];
  name.textColor=NSColor.whiteColor;name.lineBreakMode=NSLineBreakByTruncatingMiddle;name.frame=NSMakeRect(12,8,listWidth-142,18);[row addSubview:name];
  NSButton *scan=[NSButton buttonWithTitle:@(TOTK_UI("扫描","Scan")) target:self action:@selector(scanRow:)];
  scan.tag=(NSInteger)index;scan.refusesFirstResponder=YES;scan.frame=NSMakeRect(listWidth-100,11,86,30);[row addSubview:scan];
  [self.fileList addSubview:row];
 }];
}
-(void)scanRow:(NSButton *)button{
 NSInteger index=button.tag;
 if(index>=0&&(NSUInteger)index<self.files.count)[amiiboMenuTarget scanAmiiboURL:self.files[(NSUInteger)index]];
}
-(void)chooseFolder:(id)sender{(void)sender;[amiiboMenuTarget chooseAmiiboFolder:nil];}
-(void)chooseKey:(id)sender{(void)sender;[amiiboMenuTarget chooseAmiiboKey:nil];}
-(void)loadOneFile:(id)sender{(void)sender;[amiiboMenuTarget chooseAmiibo:nil];}
-(void)close:(id)sender{(void)sender;amiibo_panel_show(0);}
-(void)center{if(self.superview)[self setFrameOrigin:NSMakePoint(floor((self.superview.bounds.size.width-self.frame.size.width)/2),floor((self.superview.bounds.size.height-self.frame.size.height)/2))];}
-(void)viewDidMoveToSuperview{[super viewDidMoveToSuperview];[self center];}
@end
static void amiibo_panel_show(int open){
 open=!!open;if(!window||open==amiiboPanelOpen)return;
 if(open){if(settingsOpen)return;if(!amiiboMenuTarget)amiiboMenuTarget=[BOTWAmiiboMenuTarget new];if(!amiiboPanel)amiiboPanel=[BOTWAmiiboPanel new];
  amiiboPanelOpen=1;runtime_input_clear();[window.contentView addSubview:amiiboPanel];[amiiboPanel refreshFiles];[amiiboPanel center];[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:NO];}
 else{amiiboPanelOpen=0;[amiiboPanel removeFromSuperview];[window makeFirstResponder:window.contentView];
  if(window.isKeyWindow&&(window.styleMask&NSWindowStyleMaskFullScreen))[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:YES];}
 front_mouse_update();fprintf(stderr,"[botw] virtual Amiibo panel %s\n",open?"open":"closed");
}
#endif
/* Use the window-close path, not terminate:, so Command-Q also waits for active saves. */
static void front_install_menu(void){
 NSMenu *menu=[NSMenu new],*appMenu=[NSMenu new];
 NSMenuItem *appItem=[NSMenuItem new];appItem.submenu=appMenu;[menu addItem:appItem];
 NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@(TOTK_UI("退出 " GAME_NAME,"Quit " GAME_NAME)) action:@selector(performClose:) keyEquivalent:@"q"];
 quit.keyEquivalentModifierMask=NSEventModifierFlagCommand;quit.target=window;
 [appMenu addItem:quit];
 front_menubar_fps_add(menu);NSApp.mainMenu=menu;
}
static void *guest_main(void *callback){@autoreleasepool{((void(*)(void))callback)();}return NULL;}
void runtime_front_run(void(*callback)(void)){
 @autoreleasepool{
  bootStartNS=runtime_now_ns();
  {const char *commit=getenv("TOTK_SOURCE_COMMIT");fprintf(stderr,"[totk] built from commit %s\n",commit&&*commit?commit:"(not recorded)");}
#ifdef GAME_BOTW
  if(totk_sr_start)totk_sr_start("botw",TOTK_GAME_VERSION);   /* TOTK_STATE_REPORTING=1: starting */
#else
  if(totk_sr_start)totk_sr_start("totk",TOTK_GAME_VERSION);
#endif
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  runtime_mouse_set_hook(front_mouse_update);
  runtime_gamepad_start();
  /* Default window: the docked output size, 1920x1080, scaled down (16:9 kept) when the screen's visible area is smaller. */
  /* TOTK_WINDOW_SIZE=<w>x<h> (test scripts only, e.g. the 2K output test; the desktop launcher never sets it): another starting size. */
  NSRect vis=NSScreen.mainScreen?NSScreen.mainScreen.visibleFrame:NSMakeRect(0,0,1920,1080+28);CGFloat ww=1920,wh=1080;
  {const char *e=getenv("TOTK_WINDOW_SIZE");int w=0,h=0;if(e&&sscanf(e,"%dx%d",&w,&h)==2&&w>=320&&h>=180&&w<=8192&&h<=8192){ww=w;wh=h;}}
  CGFloat k=fmin(1,fmin(vis.size.width/ww,(vis.size.height-28)/wh));ww=floor(ww*k);wh=floor(wh*k);
  window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,ww,wh) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;   /* a close that waits for a save (windowWillClose) must not free the window the static pointer still holds */
  /* An agent's test game (TOTK_SLOT_OWNER other than user) says so in its title: it plays a save copy and its script closes it. */
  const char *owner=getenv("TOTK_SLOT_OWNER"),*purpose=getenv("TOTK_SLOT_PURPOSE");
  window.title=owner&&*owner&&strcmp(owner,"user")?[NSString stringWithFormat:@(TOTK_UI("测试局（%s）Ver. %s：%s — 存档副本，进度不会存进你的存档，脚本会自己关闭","Test session (%s) Ver. %s: %s — save copy, progress is not saved to your save, the script closes it")),owner,TOTK_GAME_VERSION,purpose&&*purpose?purpose:TOTK_UI("代理测试","agent test")]:[NSString stringWithFormat:@GAME_NAME "  Mac — Ver. %s",TOTK_GAME_VERSION];
  windowDelegate=[TOTKWindowDelegate new];window.delegate=windowDelegate;
  front_install_menu();
  window.collectionBehavior|=NSWindowCollectionBehaviorFullScreenPrimary;
  window.contentView=[[TOTKInputView alloc] initWithFrame:NSMakeRect(0,0,ww,wh)];
  metalLayer=[CAMetalLayer layer];metalLayer.device=MTLCreateSystemDefaultDevice();metalLayer.pixelFormat=MTLPixelFormatBGRA8Unorm;metalLayer.drawableSize=CGSizeMake(ww,wh);runtime_aspect_view(ww,wh);
  metalLayer.framebufferOnly=NO;window.contentView.wantsLayer=YES;window.contentView.layer=metalLayer;
  bootOverlay=[[NSView alloc] initWithFrame:window.contentView.bounds];bootOverlay.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  bootOverlay.wantsLayer=YES;bootOverlay.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.035 green:0.075 blue:0.09 alpha:1].CGColor;
  bootStage=[NSTextField labelWithString:@(TOTK_UI("正在启动海拉鲁","Starting Hyrule"))];
  bootStage.font=[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold];bootStage.textColor=NSColor.whiteColor;
  bootStage.alignment=NSTextAlignmentCenter;bootStage.frame=NSMakeRect(0,wh/2+20,ww,40);bootStage.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootDetail=[NSTextField labelWithString:@(TOTK_UI("正在准备游戏环境","Preparing the game environment"))];
  bootDetail.font=[NSFont systemFontOfSize:14];bootDetail.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];
  bootDetail.alignment=NSTextAlignmentCenter;bootDetail.frame=NSMakeRect(0,wh/2-20,ww,28);bootDetail.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
  bootProgress=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(ww/2-140,wh/2-55,280,10)];
  bootProgress.minValue=0;bootProgress.maxValue=100;bootProgress.indeterminate=YES;bootProgress.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
  [bootOverlay addSubview:bootStage];[bootOverlay addSubview:bootDetail];[bootOverlay addSubview:bootProgress];
  [window.contentView addSubview:bootOverlay];[bootProgress startAnimation:nil];
  front_menubar_fps();
  settings_restore_start();
  settings_controller_start();
  front_playtime_start();
  /* The FPS, shader and load lines: in the corner box (compact HUD), or with TOTK_HUD=corners drawn into the game picture's
     corners by the present encoder (gfx/nvn/fps_overlay.c). The box sits under the opaque boot overlay until it is hidden. */
  TOTKHudBox *box=[[TOTKHudBox alloc] initWithFrame:NSZeroRect];box.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;
  [window.contentView addSubview:box positioned:NSWindowBelow relativeTo:bootOverlay];hudBox=box;
  /* The settings panel's FPS graph switch, one for both games (user 2026-10-29: "改成两个游戏共用 默认打开"): fps-graph.txt
     in the folder above the game's ("on" / "off"), on when there is none. */
  {char word[16];fpsGraphEnabled=1;if(runtime_shared_setting_word("fps-graph.txt",word,sizeof word))fpsGraphEnabled=!!strncmp(word,"off",3);}
  TOTKFpsGraph *graph=[[TOTKFpsGraph alloc] initWithFrame:NSZeroRect];[box addSubview:graph];fpsGraphBox=graph;[graph setEnabled:fpsGraphEnabled];[box refresh];
  [window makeFirstResponder:window.contentView];[window center];front_sync_drawable();
  if(assume_focus()){[window orderFrontRegardless];}else{[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}   /* in front of other apps' windows, keyboard left alone */
  front_sr_view();
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;front_sr_view();}];   /* a refresh rate changed on the same screen */
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{note_occlusion(" 3 s after opening");});
  atomic_store(&focused,1);
  if(CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)||CVDisplayLinkSetOutputCallback(displayLink,vsync_callback,NULL)||CVDisplayLinkStart(displayLink))runtime_fail("native display link initialization");
  pthread_t guest;pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,8*1024*1024);int err=pthread_create(&guest,&attr,guest_main,(void *)callback);pthread_attr_destroy(&attr);if(err)runtime_fail("native game thread creation");
  [NSApp run];runtime_fail("native event loop returned unexpectedly");
 }
}
/* AppKit text entry, including controller navigation; independent of the renderer. */
#include "text_keyboard.h"
static __weak TOTKTextBar *openBar;   /* main thread only */
void runtime_front_text_test(const char *op,const char *text){
 NSString *o=[NSString stringWithUTF8String:op],*t=[NSString stringWithUTF8String:text?text:""]?:@"";
 dispatch_async(dispatch_get_main_queue(), ^{
  TOTKTextBar *bar=openBar;if(!bar){fprintf(stderr,"[totk] keyboard test: no text entry bar is open\n");return;}
  if([o isEqualToString:@"type"]){bar.field.stringValue=[bar.field.stringValue stringByAppendingString:t];[bar refilter];}
  else if([o isEqualToString:@"enter"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(insertNewline:)];
  else if([o isEqualToString:@"shot"]){   /* the bar as drawn (window screenshots of the game picture do not include AppKit views) */
   NSBitmapImageRep *rep=[bar bitmapImageRepForCachingDisplayInRect:bar.bounds];[bar cacheDisplayInRect:bar.bounds toBitmapImageRep:rep];
   NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];BOOL ok=[png writeToFile:t atomically:YES];
   fprintf(stderr,"[totk] keyboard test: bar picture %s %s\n",t.UTF8String,ok?"written":"FAILED");return;}
  else if([o isEqualToString:@"esc"])[bar control:bar.field textView:(NSTextView *)bar.field.currentEditor doCommandBySelector:@selector(cancelOperation:)];
  fprintf(stderr,"[totk] keyboard test: %s -> field \"%s\"\n",o.UTF8String,bar.field.stringValue.UTF8String);
 });
}
int runtime_front_text_input(const RuntimeTextRequest *req,char *out,size_t out_size){
 if(!window||!req||!out||!out_size){fprintf(stderr,"[totk] keyboard: no game window for text entry; cancelled\n");return 0;}
 NSString *prompt=[NSString stringWithUTF8String:req->prompt?req->prompt:""]?:@"",*initial=[NSString stringWithUTF8String:req->initial?req->initial:""]?:@"";
 int maxU=req->max_units,minU=req->min_units,digits=req->digits_only,secure=req->secure;uint32_t dis=req->disabled;
 __block NSString *result=nil;dispatch_semaphore_t sem=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_main_queue(), ^{
  if(openBar){dispatch_semaphore_signal(sem);return;}   /* do not strand an earlier guest request */
  if(settingsOpen)settings_show(0);
  NSView *cv=window.contentView;
  TOTKTextBar *bar=[[TOTKTextBar alloc] initWithFrame:cv.bounds];
  bar.maxUnits=maxU;bar.minUnits=minU;bar.digitsOnly=digits;bar.disabled=dis;
  [bar buildWithPrompt:prompt initial:initial secure:secure];
  __weak TOTKTextBar *weakBar=bar;
  bar.done=^(NSString *text){result=[text copy];[weakBar removeFromSuperview];openBar=nil;
   runtime_gamepad_text_capture(0);[window makeFirstResponder:window.contentView];
   textEntryOpen=0;front_mouse_update();dispatch_semaphore_signal(sem);};
  [cv addSubview:bar];openBar=bar;
  runtime_input_clear();
  if(window.miniaturized)[window deminiaturize:nil];
  if(!assume_focus()){[NSApp activateIgnoringOtherApps:YES];[window makeKeyAndOrderFront:nil];}   /* test windows never take the keyboard */
  [window makeFirstResponder:bar.field];
  runtime_gamepad_text_capture(1);[bar startController];
  textEntryOpen=1;front_mouse_update();   /* the pointer is the player's while typing */
  fprintf(stderr,"[totk] keyboard: text entry bar shown (%s)\n",prompt.UTF8String);
 });
 dispatch_semaphore_wait(sem,DISPATCH_TIME_FOREVER);
 if(!result)return 0;
 snprintf(out,out_size,"%s",result.UTF8String?result.UTF8String:"");
 return 1;
}
static int viReady;
static unsigned displayIdentity,layerIdentity;
static void vi_initialize(void){if(!metalLayer)runtime_fail("VI requires native macOS window");viReady=1;fprintf(stderr,"[totk] native VI display initialized\n");}
static uint32_t vi_open(void **out){if(!viReady||!out)return 0xf601;*out=&displayIdentity;return 0;}
static uint32_t vi_layer(void **out,void *display){if(!out||display!=&displayIdentity)return 0xf601;*out=&layerIdentity;return 0;}
static uint32_t vi_window(void **out,void *layer){if(!out||layer!=&layerIdentity)return 0xf601;*out=front_metal_layer();return 0;}
static uint32_t vi_vsync(void *ev,void *display){
 if(!ev||display!=&displayIdentity)return 0xf601;hle_bind_system_event(ev,1);
 pthread_mutex_lock(&vsyncLock);if(vsyncCount>=16)runtime_fail("VI display event limit");vsyncEvents[vsyncCount++]=ev;pthread_mutex_unlock(&vsyncLock);return 0;
}
#ifdef GAME_BOTW
static uint32_t vi_scaling_mode(void *layer,int mode){(void)layer;(void)mode;return 0;}
#endif
void *runtime_front_override(const char *name){
 static const struct{const char *name;void *fn;} entries[]={
 {"_ZN2nn2vi10InitializeEv",vi_initialize},{"_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE",vi_open},
 {"_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE",vi_layer},{"_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE",vi_window},
 {"_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE",vi_vsync}
#ifdef GAME_BOTW
 ,{"_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE",vi_scaling_mode}   /* SDK 7: the window scales itself */
#endif
 };
 for(unsigned i=0;i<sizeof(entries)/sizeof(*entries);i++)if(!strcmp(name,entries[i].name))return entries[i].fn;return NULL;
}
