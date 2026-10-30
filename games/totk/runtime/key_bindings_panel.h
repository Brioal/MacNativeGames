/* Keyboard and mouse bindings shown from the settings panel. All UI and mouse map changes run on the main thread. */
#pragma once
#include "controller_map.h"
static NSView *bindingsPanel;
static BOOL bindingsOpen;
static int bindingAction=-1,bindingSlot;
static NSTextField *bindingsHint;
static NSScrollView *bindingsScroll;
static CGFloat bindingsScrollY=-1;
static BOOL bindingsMouseOverride;
static void bindings_show(int open);

static NSString *bindings_path(void){
 const char *p=getenv("TOTK_CONTROLS");if(!p||!*p)return nil;
 return [[@(p) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"keyboard-mouse.json"];
}
static NSString *binding_key_name(int k){
 if(k<0)return @(TOTK_UI("未设置","None"));
 static NSDictionary *names;
 if(!names)names=@{@0:@"A",@1:@"S",@2:@"D",@3:@"F",@4:@"H",@5:@"G",@6:@"Z",@7:@"X",@8:@"C",@9:@"V",
 @11:@"B",@12:@"Q",@13:@"W",@14:@"E",@15:@"R",@16:@"Y",@17:@"T",@18:@"1",@19:@"2",@20:@"3",@21:@"4",
 @22:@"6",@23:@"5",@24:@"=",@25:@"9",@26:@"7",@27:@"-",@28:@"8",@29:@"0",@30:@"]",@31:@"O",@32:@"U",
 @33:@"[",@34:@"I",@35:@"P",@36:@"Return",@37:@"L",@38:@"J",@39:@"'",@40:@"K",@41:@";",@42:@"\\",
 @43:@",",@44:@"/",@45:@"N",@46:@"M",@47:@".",@48:@"Tab",@49:@"Space",@50:@"`",@51:@"Delete",@53:@"Esc",
 @56:@"左 Shift",@57:@"Caps Lock",@58:@"左 Option",@59:@"左 Control",@60:@"右 Shift",@61:@"右 Option",@62:@"右 Control",
 @123:@"←",@124:@"→",@125:@"↓",@126:@"↑"};
 return names[@(k)]?:[NSString stringWithFormat:@"Key %d",k];
}
static NSArray<NSString *> *binding_actions(void){
 return @[@(TOTK_UI("A · 确定 / 互动","A · Confirm / interact")),@(TOTK_UI("B · 跑步 / 取消","B · Run / cancel")),
 @(TOTK_UI("X · 跳跃","X · Jump")),@(TOTK_UI("Y · 攻击","Y · Attack")),
 @(TOTK_UI("左摇杆按下","Left stick click")),@(TOTK_UI("右摇杆按下","Right stick click")),
 @"L",@"R",@"ZL",@"ZR",@"+ · 菜单",@"− · 地图",@(TOTK_UI("方向键 ←","D-pad ←")),@(TOTK_UI("方向键 ↑","D-pad ↑")),@(TOTK_UI("方向键 →","D-pad →")),@(TOTK_UI("方向键 ↓","D-pad ↓")),
 @(TOTK_UI("左摇杆 ←","Left stick ←")),@(TOTK_UI("左摇杆 →","Left stick →")),@(TOTK_UI("左摇杆 ↓","Left stick ↓")),@(TOTK_UI("左摇杆 ↑","Left stick ↑")),@(TOTK_UI("右摇杆 ←","Right stick ←")),@(TOTK_UI("右摇杆 →","Right stick →")),@(TOTK_UI("右摇杆 ↓","Right stick ↓")),@(TOTK_UI("右摇杆 ↑","Right stick ↑"))];
}
static NSArray<NSString *> *binding_mouse_names(void){
 return @[@(TOTK_UI("左键","Left")),@(TOTK_UI("右键","Right")),@(TOTK_UI("中键","Middle")),
 @(TOTK_UI("侧键 1","Side 1")),@(TOTK_UI("侧键 2","Side 2"))];
}
static BOOL bindings_save(const int keys[24][2],const uint16_t map[5],const uint8_t modes[5],BOOL mouseChange){
 NSString *path=bindings_path();
 if(!path){bindingsHint.stringValue=@(TOTK_UI("无法找到配置目录，未保存","Settings folder unavailable; not saved"));return NO;}
 NSMutableArray *k=[NSMutableArray array],*m=[NSMutableArray array];
 for(int i=0;i<24;i++)[k addObject:@[@(keys[i][0]),@(keys[i][1])]];
 for(int i=0;i<5;i++)[m addObject:@[@(map[i]),@(modes[i])]];
 NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"keys":k,@"mouse":(mouseChange||bindingsMouseOverride)?m:NSNull.null} options:NSJSONWritingPrettyPrinted error:&error];
 if(!data||![data writeToFile:path options:NSDataWritingAtomic error:&error]){
  bindingsHint.stringValue=[NSString stringWithFormat:@(TOTK_UI("保存失败：%@","Could not save: %@")),error.localizedDescription];return NO;
 }
 bindingsMouseOverride|=mouseChange;runtime_bindings_set(keys);if(mouseChange)runtime_mouse_bindings_set(map,modes);return YES;
}
static void bindings_load(void){
 NSString *path=bindings_path();if(!path||![NSFileManager.defaultManager fileExistsAtPath:path])return;
 NSError *error=nil;NSData *data=[NSData dataWithContentsOfFile:path options:0 error:&error];
 id obj=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&error]:nil;
 NSArray *keys=[obj isKindOfClass:NSDictionary.class]?obj[@"keys"]:nil;id mouse=[obj isKindOfClass:NSDictionary.class]?obj[@"mouse"]:nil;
 int k[24][2];uint16_t map[5];uint8_t modes[5];BOOL hasMouse=[mouse isKindOfClass:NSArray.class];BOOL valid=[keys isKindOfClass:NSArray.class]&&keys.count==24&&(mouse==NSNull.null||(hasMouse&&[mouse count]==5));
 if(valid)for(int i=0;i<24&&valid;i++){
  id row=keys[i];valid=[row isKindOfClass:NSArray.class]&&[row count]==2;
  for(int j=0;j<2&&valid;j++){id v=row[j];valid=[v isKindOfClass:NSNumber.class]&&[v integerValue]>=-1&&[v integerValue]<128&&[v integerValue]!=18;if(valid)k[i][j]=[v intValue];}
 }
 if(valid&&hasMouse)for(int i=0;i<5&&valid;i++){
  id row=mouse[i];valid=[row isKindOfClass:NSArray.class]&&[row count]==2;
  if(!valid)break;id a=row[0],b=row[1];
  valid=[a isKindOfClass:NSNumber.class]&&[b isKindOfClass:NSNumber.class];
  if(!valid)break;NSInteger x=[a integerValue],y=[b integerValue];
  valid=x>=0&&x<=65535&&(!x||!(x&(x-1)))&&y>=0&&y<=255&&(y&7)<=CONTROLLER_AIM;
  if(valid&&(y&7)==CONTROLLER_AIM)valid=(y>>3)<CONTROLLER_BUTTONS;
  if(valid){map[i]=(uint16_t)x;modes[i]=(uint8_t)y;}
 }
 if(!valid){NSAlert *alert=[NSAlert new];alert.messageText=@(TOTK_UI("键位配置无法读取","Cannot read key bindings"));
  alert.informativeText=error.localizedDescription?:path;[alert runModal];return;}
 bindingsMouseOverride=hasMouse;runtime_bindings_set(k);if(hasMouse)runtime_mouse_bindings_set(map,modes);
}

@interface TOTKBindingsPanel:NSView
-(void)bind:(NSButton *)button;
-(void)clear:(NSButton *)button;
-(void)mouseChanged:(NSPopUpButton *)popup;
-(void)aimChanged:(NSPopUpButton *)popup;
-(void)reset:(id)sender;
-(void)back:(id)sender;
@end
static void bindings_refresh(void);
@implementation TOTKBindingsPanel
-(void)bind:(NSButton *)button{
 bindingAction=(int)button.tag/2;bindingSlot=(int)button.tag%2;
 bindingsHint.stringValue=@(TOTK_UI("请按新键；按 1 不可绑定。点击返回可取消。","Press a key; 1 is reserved. Back cancels."));
 [window makeFirstResponder:window.contentView];
}
-(void)clear:(NSButton *)button{
 int k[24][2];uint16_t m[5];uint8_t modes[5];runtime_bindings_get(k);runtime_mouse_bindings_get(m,modes);
 k[button.tag/2][button.tag%2]=-1;if(bindings_save(k,m,modes,NO))bindings_refresh();
}
-(void)mouseChanged:(NSPopUpButton *)popup{
 int k[24][2];uint16_t m[5];uint8_t modes[5];runtime_bindings_get(k);runtime_mouse_bindings_get(m,modes);
 int n=(int)popup.indexOfSelectedItem,i=(int)popup.tag;m[i]=n?(uint16_t)(1u<<(n-1)):0;if(!n||(controller_mode_kind(modes[i])==CONTROLLER_AIM&&n!=10))modes[i]=CONTROLLER_HOLD;
 if(bindings_save(k,m,modes,YES))bindings_refresh();
}
-(void)aimChanged:(NSPopUpButton *)popup{
 int k[24][2];uint16_t m[5];uint8_t modes[5];runtime_bindings_get(k);runtime_mouse_bindings_get(m,modes);
 int aim=-1,fire=0;
 for(int i=0;i<5;i++)if(controller_mode_kind(modes[i])==CONTROLLER_AIM){aim=i;int f=controller_mode_fire(modes[i])-CONTROLLER_MOUSE_FIRST;if(f>=0&&f<5)fire=f;}
 if(popup.tag==100)aim=(int)popup.indexOfSelectedItem-1;else fire=(int)popup.indexOfSelectedItem;
 if(aim>=0&&aim==fire){bindings_refresh();bindingsHint.stringValue=@(TOTK_UI("拉弓和射击必须使用不同鼠标键","Aim and fire must use different mouse buttons"));return;}
 for(int i=0;i<5;i++)if(controller_mode_kind(modes[i])==CONTROLLER_AIM)modes[i]=CONTROLLER_HOLD;
 if(aim>=0){m[aim]=1u<<9;modes[aim]=(uint8_t)(CONTROLLER_AIM|((fire+CONTROLLER_MOUSE_FIRST)<<3));}
 if(bindings_save(k,m,modes,YES))bindings_refresh();
}
-(void)reset:(id)sender{
 (void)sender;NSAlert *a=[NSAlert new];a.messageText=@(TOTK_UI("恢复默认键位？","Restore default bindings?"));
 a.informativeText=@(TOTK_UI("键盘恢复默认，鼠标恢复 controls.txt 中的设置。","Keyboard defaults are restored and mouse mappings follow controls.txt."));
 [a addButtonWithTitle:@(TOTK_UI("恢复","Restore"))];[a addButtonWithTitle:@(TOTK_UI("取消","Cancel"))];
 if([a runModal]!=NSAlertFirstButtonReturn)return;
 NSString *path=bindings_path();NSError *error=nil;
 if(!path){bindingsHint.stringValue=@(TOTK_UI("无法找到配置目录","Settings folder unavailable"));return;}
 if([NSFileManager.defaultManager fileExistsAtPath:path]&&![NSFileManager.defaultManager removeItemAtPath:path error:&error]){
  bindingsHint.stringValue=error.localizedDescription;return;
 }
 int k[24][2];runtime_bindings_default(k);runtime_bindings_set(k);runtime_mouse_bindings_reset();bindingsMouseOverride=NO;bindings_refresh();
}
-(void)back:(id)sender{(void)sender;bindings_show(0);}
@end

static int bindings_capture_key(unsigned code){
 if(!bindingsOpen||bindingAction<0)return 0;
#ifdef GAME_BOTW160
 if(code==19){bindingsHint.stringValue=@(TOTK_UI("按键 2 保留给 Amiibo 顺序扫描","Key 2 is reserved for Amiibo scanning"));return 1;}
#endif
 if(code==18||code==54||code==55||code>=128){bindingsHint.stringValue=@(TOTK_UI("这个键由系统或设置面板保留，请换一个","This key is reserved; choose another"));return 1;}
 int k[24][2];uint16_t m[5];uint8_t modes[5];runtime_bindings_get(k);runtime_mouse_bindings_get(m,modes);
 int other=-1;
 for(int i=0;i<24;i++)for(int j=0;j<2;j++)if(k[i][j]==(int)code&&(i!=bindingAction||j!=bindingSlot))other=i;
 if(other>=0){
  NSAlert *a=[NSAlert new];a.messageText=[NSString stringWithFormat:@(TOTK_UI("%@ 已绑定到 %@","%@ is assigned to %@")),binding_key_name((int)code),binding_actions()[other]];
  [a addButtonWithTitle:@(TOTK_UI("替换","Replace"))];[a addButtonWithTitle:@(TOTK_UI("取消","Cancel"))];
  if([a runModal]!=NSAlertFirstButtonReturn){bindingAction=-1;bindings_refresh();return 1;}
  for(int i=0;i<24;i++)for(int j=0;j<2;j++)if(k[i][j]==(int)code)k[i][j]=-1;
 }
 k[bindingAction][bindingSlot]=(int)code;
 if(bindings_save(k,m,modes,NO)){bindingAction=-1;bindings_refresh();}
 return 1;
}
static NSTextField *bindings_label(NSString *s,NSRect f){NSTextField *l=[NSTextField labelWithString:s];l.frame=f;l.textColor=NSColor.whiteColor;return l;}
static void bindings_refresh(void){
 if(!bindingsOpen)return;
 if(bindingsPanel&&bindingsScroll)bindingsScrollY=bindingsScroll.contentView.bounds.origin.y;
 [bindingsPanel removeFromSuperview];
 CGFloat w=520,h=fmin(700,window.contentView.bounds.size.height-16);h=fmax(h,300);
 TOTKBindingsPanel *p=[[TOTKBindingsPanel alloc] initWithFrame:NSMakeRect(0,0,w,h)];
 p.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];p.wantsLayer=YES;p.layer.backgroundColor=[NSColor colorWithCalibratedRed:.10 green:.16 blue:.20 alpha:.96].CGColor;p.layer.cornerRadius=12;
 p.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
 NSSize size=window.contentView.bounds.size;[p setFrameOrigin:NSMakePoint(fmax(0,(size.width-w)/2),fmax(0,(size.height-h)/2))];
 [p addSubview:bindings_label(@(TOTK_UI("键位设置","Key bindings")),NSMakeRect(16,h-34,250,22))];
 NSButton *back=[NSButton buttonWithTitle:@(TOTK_UI("返回","Back")) target:p action:@selector(back:)];
 back.frame=NSMakeRect(w-88,h-38,72,28);[p addSubview:back];
 NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(12,76,w-24,h-122)];
 scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;[p addSubview:scroll];bindingsScroll=scroll;
 CGFloat row=34,docH=31*row+26;NSView *doc=[[NSView alloc] initWithFrame:NSMakeRect(0,0,w-40,docH)];scroll.documentView=doc;
 int keys[24][2];uint16_t map[5];uint8_t modes[5];runtime_bindings_get(keys);runtime_mouse_bindings_get(map,modes);
 CGFloat y=docH-30;
 for(int i=0;i<24;i++,y-=row){
  [doc addSubview:bindings_label(binding_actions()[i],NSMakeRect(4,y,194,22))];
  for(int j=0;j<2;j++){
   NSButton *b=[NSButton buttonWithTitle:binding_key_name(keys[i][j]) target:p action:@selector(bind:)];
   b.tag=i*2+j;b.frame=NSMakeRect(198+j*136,y-2,100,26);[doc addSubview:b];
   NSButton *clear=[NSButton buttonWithTitle:@"×" target:p action:@selector(clear:)];clear.tag=b.tag;clear.frame=NSMakeRect(299+j*136,y-2,28,26);[doc addSubview:clear];
  }
 }
 NSArray *mouseNames=binding_mouse_names();
 for(int i=0;i<5;i++,y-=row){
  [doc addSubview:bindings_label([NSString stringWithFormat:@(TOTK_UI("鼠标 %@", "Mouse %@")),mouseNames[i]],NSMakeRect(4,y,180,22))];
  NSPopUpButton *pop=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(198,y-2,235,26) pullsDown:NO];
  [pop addItemWithTitle:@(TOTK_UI("未设置","None"))];for(int n=0;n<16;n++)[pop addItemWithTitle:binding_actions()[n]];
  int selected=0;for(int n=0;n<16;n++)if(map[i]==(1u<<n))selected=n+1;[pop selectItemAtIndex:selected];
  pop.tag=i;pop.target=p;pop.action=@selector(mouseChanged:);[doc addSubview:pop];
 }
 int aim=-1,fire=0;
 for(int i=0;i<5;i++)if(controller_mode_kind(modes[i])==CONTROLLER_AIM){aim=i;int f=controller_mode_fire(modes[i])-CONTROLLER_MOUSE_FIRST;if(f>=0&&f<5)fire=f;}
 for(int i=0;i<2;i++,y-=row){
  [doc addSubview:bindings_label(i?@(TOTK_UI("联动：射击键","Fire button")):@(TOTK_UI("联动：拉弓键","Aim button")),NSMakeRect(4,y,180,22))];
  NSPopUpButton *pop=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(198,y-2,235,26) pullsDown:NO];
  if(!i)[pop addItemWithTitle:@(TOTK_UI("关闭","Off"))];[pop addItemsWithTitles:mouseNames];
  [pop selectItemAtIndex:i?fire:aim+1];if(i&&aim<0)pop.enabled=NO;pop.tag=100+i;pop.target=p;pop.action=@selector(aimChanged:);[doc addSubview:pop];
 }
 CGFloat top=fmax(0,docH-scroll.contentView.bounds.size.height);
 [scroll.contentView scrollToPoint:NSMakePoint(0,bindingsScrollY<0?top:fmin(top,fmax(0,bindingsScrollY)))];[scroll reflectScrolledClipView:scroll.contentView];
 NSButton *reset=[NSButton buttonWithTitle:@(TOTK_UI("恢复默认","Restore defaults")) target:p action:@selector(reset:)];
 reset.frame=NSMakeRect(16,40,110,28);[p addSubview:reset];
 bindingsHint=bindings_label(@(TOTK_UI("点击键位后按新键；× 清除。鼠标操作需开启。","Click a binding, then press a key; × clears it. Enable mouse mode to use it.")),NSMakeRect(16,8,w-32,27));
 bindingsHint.font=[NSFont systemFontOfSize:11];[p addSubview:bindingsHint];
 bindingsPanel=p;[window.contentView addSubview:p];[window makeFirstResponder:window.contentView];
}
