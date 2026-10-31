/* Exercise the real shortcut, panel routing and NFP state machine with synthetic tag files. */
#define GAME_BOTW 1
#define GAME_BOTW160 1
#define main command_q_main
#include "../command_q/probe.m"
#undef main
#define runtime_oe_push_message test_applet_oe_push
#include "../../runtime/applet_host.c"
#undef runtime_oe_push_message
#include <assert.h>

static void write_tag(NSString *path,uint8_t uid){
 uint8_t data[532]={0};data[0]=uid;data[0x10]=0xa5;data[0x5b]=2;
 assert([[NSData dataWithBytes:data length:sizeof data] writeToFile:path atomically:YES]);
}
static NSEvent *key2(BOOL repeat){
 return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
  windowNumber:window.windowNumber context:nil characters:@"2" charactersIgnoringModifiers:@"2" isARepeat:repeat keyCode:19];
}
static NSString *last(void){return [NSUserDefaults.standardUserDefaults stringForKey:@"BOTWAmiiboSequenceLast"];}
static NSString *toast(void){return [(NSTextField *)amiiboToast.subviews.firstObject stringValue];}
int main(int argc,char **argv){@autoreleasepool{
 assert(argc==2||argc==3);start=clock_ns();[NSApplication sharedApplication];
 window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 window.contentView=[[TOTKInputView alloc] initWithFrame:window.contentView.bounds];
 NSString *dir=@(argv[1]);
 if(argc==3){
  NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
  assert([[d stringForKey:@"BOTWAmiiboSequenceLast"] isEqual:@"first.bin"]);
  [d setObject:[dir stringByAppendingPathComponent:@"other"] forKey:@"BOTWAmiiboFolder"];
  front_amiibo_next();assert([last() isEqual:@"second.bin"]&&nfp_amiibo.uuid[0]==8);
  puts("pass: Amiibo sequence continues after restart");return 0;
 }
 NSString *folder=[dir stringByAppendingPathComponent:@"tags"];
 assert([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil]);
 write_tag([folder stringByAppendingPathComponent:@"01.bin"],1);
 assert([[NSData dataWithBytes:"x" length:1] writeToFile:[folder stringByAppendingPathComponent:@"02.bin"] atomically:YES]);
 write_tag([folder stringByAppendingPathComponent:@"03.bin"],3);
 NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
 for(NSString *uid in @[@"01000000000000",@"03000000000000",@"07000000000000",@"08000000000000"])
  for(NSString *suffix in @[@"date",@"today",@"total"])
   [d removeObjectForKey:[NSString stringWithFormat:@"BOTWAmiiboUsage.%@.%@",uid,suffix]];
 [d setObject:folder forKey:@"BOTWAmiiboFolder"];
 [d removeObjectForKey:@"BOTWAmiiboSequenceFolder"];[d removeObjectForKey:@"BOTWAmiiboSequenceLast"];
 KeyMap keys;keymap_default(&keys);assert(keymap_assign(&keys,19,-1));runtime_keymap_set(&keys);
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];
 assert([last() isEqual:@"01.bin"]&&nfp_scan_pending&&nfp_amiibo.uuid[0]==1);
 assert([toast() containsString:@"01.bin"]);assert([amiiboToast hitTest:NSMakePoint(5,5)]==nil);assert(front_amiibo_today_count(amiiboCurrentID)==1);
 [(TOTKInputView *)window.contentView keyDown:key2(YES)];
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];
 assert([last() isEqual:@"01.bin"]&&nfp_amiibo.uuid[0]==1&&front_amiibo_today_count(amiiboCurrentID)==1);
 assert([toast() containsString:@"处理"]);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_status==2);
 assert(nfp_mount(nfp_virtual_handle,0,0)==0&&nfp_status==4);
 assert(!runtime_nfp_try_select(&(RuntimeVirtualAmiibo){0}));
 assert(!runtime_nfp_try_scan(&(RuntimeVirtualAmiibo){0}));
 assert(nfp_unmount(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];
 assert([last() isEqual:@"03.bin"]&&nfp_amiibo.uuid[0]==3&&[toast() containsString:@"跳过"]);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];assert([last() isEqual:@"01.bin"]);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 [d setObject:@"missing.bin" forKey:@"BOTWAmiiboSequenceLast"];
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];assert([last() isEqual:@"01.bin"]);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 NSString *folder2=[dir stringByAppendingPathComponent:@"other"];
 assert([NSFileManager.defaultManager createDirectoryAtPath:folder2 withIntermediateDirectories:YES attributes:nil error:nil]);
 write_tag([folder2 stringByAppendingPathComponent:@"first.bin"],7);write_tag([folder2 stringByAppendingPathComponent:@"second.bin"],8);[d setObject:folder2 forKey:@"BOTWAmiiboFolder"];
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];assert([last() isEqual:@"first.bin"]&&nfp_amiibo.uuid[0]==7);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 /* Manual selection and scan use the same busy protection and request counter. */
 NSURL *manual=[NSURL fileURLWithPath:[folder2 stringByAppendingPathComponent:@"first.bin"]];
 assert([amiiboMenuTarget loadAmiiboURL:manual]);
 NSInteger before=front_amiibo_today_count(amiiboCurrentID);
 [amiiboMenuTarget simulateAmiiboScan:nil];assert(nfp_scan_pending&&front_amiibo_today_count(amiiboCurrentID)==before+1);
 [amiiboMenuTarget scanAmiiboURL:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"01.bin"]]];
 assert(nfp_amiibo.uuid[0]==7&&front_amiibo_today_count(amiiboCurrentID)==before+1);
 assert(nfp_start_detection(nfp_virtual_handle)==0&&nfp_stop_detection(nfp_virtual_handle)==0);
 settings_show(1);BOOL found=NO;NSButton *managerButton=nil;
 for(NSView *v in settingsPanel.subviews)if([v isKindOfClass:NSButton.class]){
  if([((NSButton *)v).title containsString:@"2：下一张"])found=YES;
  if([((NSButton *)v).title containsString:@"模组管理"])managerButton=(NSButton *)v;
 }
 assert(found&&managerButton);[(TOTKInputView *)window.contentView keyDown:key2(NO)];assert(!nfp_scan_pending);
 [managerButton performClick:nil];assert(modManagerOpen&&settingsPanel.hidden&&modManagerPanel.superview==window.contentView);
 [modManagerPanel save:nil];
 NSDictionary *managerConfig=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:mod_manager_config_path()] options:0 error:nil];
 assert(managerConfig&&![managerConfig[@"enabled"] boolValue]&&[managerConfig[@"mods"] isEqual:@[]]);
 settings_show(0);assert(!modManagerOpen&&!settingsOpen);
 runtime_keymap_get(&keys);assert(keymap_assign(&keys,19,KEYMAP_DLEFT));runtime_keymap_set(&keys);
 [(TOTKInputView *)window.contentView keyDown:key2(NO)];
 assert([last() isEqual:@"first.bin"]&&!nfp_scan_pending&&[toast() containsString:@"绑定"]);
 assert(keymap_assign(&keys,19,-1));runtime_keymap_set(&keys);
 NSString *empty=[dir stringByAppendingPathComponent:@"empty"];
 assert([NSFileManager.defaultManager createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:nil]);
 [d setObject:empty forKey:@"BOTWAmiiboFolder"];front_amiibo_next();assert([toast() containsString:@"没有"]);
 assert([[NSData dataWithBytes:"x" length:1] writeToFile:[empty stringByAppendingPathComponent:@"bad.bin"] atomically:YES]);
 front_amiibo_next();assert([toast() containsString:@"没有可用"]);
 [d synchronize];
 puts("pass: Amiibo shortcut sequence, NFC busy, wrap, invalid tags, folder changes and key conflict");
 return 0;
}}
