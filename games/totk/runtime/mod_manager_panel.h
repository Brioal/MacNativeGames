/* Breath of the Wild 1.6.0: choose RomFS-only mods from unpacked subfolders, then prepare a new immutable overlay for the
   next launch. The running generation is never replaced. */
#pragma once
#ifdef GAME_BOTW160

static void mod_manager_show(int open);
static NSString *mod_manager_config_path(void) {
 return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/BotW/mod-manager/botw160.json"];
}
static NSString *mod_manager_app_path(void) {
 NSString *path=NSBundle.mainBundle.bundlePath;
 while(![path.pathExtension isEqualToString:@"app"])path=path.stringByDeletingLastPathComponent;
 return path;
}
static NSString *mod_manager_script_path(void) {
 return [mod_manager_app_path() stringByAppendingPathComponent:@"Contents/Resources/totk/scripts/prepare_mod_generation.py"];
}
static id mod_manager_run_task(NSArray<NSString *> *arguments, NSString **problem) {
 NSString *python=@"/opt/homebrew/bin/python3.14";
 NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:python];
 task.arguments=[@[mod_manager_script_path()] arrayByAddingObjectsFromArray:arguments];
 NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=pipe;
 NSError *launchError=nil;
 if(![task launchAndReturnError:&launchError]){if(problem)*problem=launchError.localizedDescription;return nil;}
 NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];
 [task waitUntilExit];
 NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:@"";
 NSError *parseError=nil;id result=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError]:nil;
 if(task.terminationStatus!=0){
  NSString *detail=[result isKindOfClass:NSDictionary.class]&&[result[@"error"] isKindOfClass:NSString.class]?result[@"error"]:text;
  if(problem)*problem=detail.length?detail:(parseError.localizedDescription?:@"The mod helper failed.");
  return nil;
 }
 if(!result){if(problem)*problem=parseError.localizedDescription?:@"The mod helper returned no result.";return nil;}
 return result;
}
static void mod_manager_run(NSArray<NSString *> *arguments, void (^completion)(id result, NSString *problem)) {
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
  NSString *problem=nil;id result=mod_manager_run_task(arguments,&problem);
  dispatch_async(dispatch_get_main_queue(), ^{completion(result,problem);});
 });
}
static NSArray<NSString *> *mod_manager_sorted_names(NSSet<NSString *> *names) {
 return [[names allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return [a localizedStandardCompare:b];}];
}

@interface BOTWModManagerPanel:NSView
@property(copy) NSString *rootPath;
@property(copy) NSArray<NSDictionary *> *mods;
@property(strong) NSMutableSet<NSString *> *selected;
@property(strong) NSArray<NSDictionary *> *conflicts;
@property(strong) NSScrollView *scroll;
@property(strong) NSView *list;
@property(strong) NSTextField *folderLabel;
@property(strong) NSTextField *currentLabel;
@property(strong) NSTextField *statusLabel;
@property(strong) NSButton *saveButton;
@property BOOL scanning;
@property BOOL checkingConflicts;
@property BOOL conflictCheckFailed;
@property BOOL preparing;
@property uint64_t scanRequest;
@property uint64_t conflictRequest;
-(void)refreshMods;
-(void)center;
@end

@implementation BOTWModManagerPanel
-(instancetype)init {
 CGFloat w=690,h=fmin(650,window.contentView.bounds.size.height-32);
 if(!(self=[super initWithFrame:NSMakeRect(0,0,w,h)]))return nil;
 self.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin|NSViewMinYMargin|NSViewMaxYMargin;
 self.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];self.wantsLayer=YES;
 self.layer.backgroundColor=[NSColor colorWithCalibratedRed:0.10 green:0.16 blue:0.20 alpha:0.98].CGColor;
 self.layer.cornerRadius=12;self.layer.borderWidth=1;self.layer.borderColor=[NSColor colorWithCalibratedWhite:1 alpha:0.16].CGColor;
 self.selected=[NSMutableSet set];self.mods=@[];self.conflicts=@[];
 NSData *saved=[NSData dataWithContentsOfFile:mod_manager_config_path()];
 if(saved){NSError *error=nil;id value=[NSJSONSerialization JSONObjectWithData:saved options:0 error:&error];
  if([value isKindOfClass:NSDictionary.class]){
   self.rootPath=[value[@"source"] isKindOfClass:NSString.class]?value[@"source"]:nil;
   if([value[@"enabled"] boolValue]&&[value[@"mods"] isKindOfClass:NSArray.class])for(id name in value[@"mods"])if([name isKindOfClass:NSString.class])[self.selected addObject:name];
  }else fprintf(stderr,"[botw] mod manager config could not be read: %s\n",error.localizedDescription.UTF8String);
 }
 NSTextField *title=[NSTextField labelWithString:@(TOTK_UI("模组管理（旷野之息 1.6.0）","Mod Manager (Breath of the Wild 1.6.0)"))];
 title.font=[NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];title.textColor=NSColor.whiteColor;title.frame=NSMakeRect(22,h-48,560,28);[self addSubview:title];
 NSTextField *hint=[NSTextField wrappingLabelWithString:@(TOTK_UI("只支持 RomFS 资源模组；不支持 ExeFS/代码补丁。不会合并归档内部资源或生成资源大小表，也无法验证版本兼容。需 Python 3.14。","RomFS only; ExeFS/code patches are unsupported. Archive internals and resource-size tables are not merged, and compatibility is not verified. Python 3.14 required."))];
 hint.font=[NSFont systemFontOfSize:11];hint.textColor=[NSColor colorWithCalibratedWhite:0.78 alpha:1];hint.frame=NSMakeRect(22,h-98,w-44,40);hint.maximumNumberOfLines=2;[self addSubview:hint];
 NSButton *close=[NSButton buttonWithTitle:@"✕" target:self action:@selector(close:)];close.bordered=NO;close.refusesFirstResponder=YES;
 close.font=[NSFont systemFontOfSize:15 weight:NSFontWeightBold];close.contentTintColor=NSColor.whiteColor;close.frame=NSMakeRect(w-48,h-48,28,28);[self addSubview:close];
 NSButton *choose=[NSButton buttonWithTitle:@(TOTK_UI("选择模组文件夹…","Choose Mods Folder…")) target:self action:@selector(chooseFolder:)];
 choose.frame=NSMakeRect(22,h-140,170,30);choose.refusesFirstResponder=YES;[self addSubview:choose];
 self.folderLabel=[NSTextField labelWithString:@""];self.folderLabel.font=[NSFont systemFontOfSize:12];
 self.folderLabel.textColor=[NSColor colorWithCalibratedWhite:0.78 alpha:1];self.folderLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
 self.folderLabel.frame=NSMakeRect(204,h-140,w-226,30);[self addSubview:self.folderLabel];
 NSDictionary *environment=NSProcessInfo.processInfo.environment;NSString *active=environment[@"TOTK_ROMFS_MODS"];
 self.currentLabel=[NSTextField labelWithString:active.length?[NSString stringWithFormat:@(TOTK_UI("本次运行：%@","This run: %@")),[active isEqualToString:@"0"]?@(TOTK_UI("未加载模组","no mods")):active]
   :@(TOTK_UI("本次运行的模组状态未知","Current mod state is unavailable"))];
 if([environment[@"TOTK_ROMFS_MODS_OVERRIDE"] isEqualToString:@"1"])
  self.currentLabel.stringValue=[NSString stringWithFormat:@(TOTK_UI("本次启动由 TOTK_ROMFS_MODS 覆盖：%@","TOTK_ROMFS_MODS overrides the manager for this run: %@")),active?:@""];
 self.currentLabel.font=[NSFont systemFontOfSize:11];self.currentLabel.textColor=[NSColor colorWithCalibratedWhite:0.72 alpha:1];
 self.currentLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;self.currentLabel.frame=NSMakeRect(22,h-169,w-44,18);[self addSubview:self.currentLabel];
 self.scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(22,112,w-44,h-300)];
 self.scroll.hasVerticalScroller=YES;self.scroll.borderType=NSBezelBorder;self.scroll.drawsBackground=YES;
 self.scroll.backgroundColor=[NSColor colorWithCalibratedWhite:0 alpha:0.12];
 self.list=[[NSView alloc] initWithFrame:NSMakeRect(0,0,self.scroll.contentSize.width,self.scroll.contentSize.height)];
 self.scroll.documentView=self.list;[self addSubview:self.scroll];
 self.statusLabel=[NSTextField wrappingLabelWithString:@""];self.statusLabel.font=[NSFont systemFontOfSize:11];
 self.statusLabel.textColor=[NSColor colorWithCalibratedWhite:0.84 alpha:1];self.statusLabel.frame=NSMakeRect(22,62,w-44,42);self.statusLabel.maximumNumberOfLines=2;[self addSubview:self.statusLabel];
 NSButton *refresh=[NSButton buttonWithTitle:@(TOTK_UI("刷新列表","Refresh")) target:self action:@selector(refresh:)];
 refresh.frame=NSMakeRect(22,18,110,32);refresh.refusesFirstResponder=YES;[self addSubview:refresh];
 NSButton *closeBottom=[NSButton buttonWithTitle:@(TOTK_UI("返回设置","Back to Settings")) target:self action:@selector(close:)];
 closeBottom.frame=NSMakeRect(w-270,18,115,32);closeBottom.refusesFirstResponder=YES;[self addSubview:closeBottom];
 self.saveButton=[NSButton buttonWithTitle:@(TOTK_UI("保存并准备","Save and Prepare")) target:self action:@selector(save:)];
 self.saveButton.frame=NSMakeRect(w-145,18,123,32);self.saveButton.refusesFirstResponder=YES;[self addSubview:self.saveButton];
 self.folderLabel.stringValue=self.rootPath.length?self.rootPath:@(TOTK_UI("尚未选择文件夹","No folder selected"));
 self.statusLabel.stringValue=@(TOTK_UI("每个子文件夹视为一个模组；可放 romfs/ 子目录或直接放 RomFS 路径。","Each child folder is one mod; use a romfs/ folder or place RomFS paths directly."));
 [self updateSaveButton];if(self.rootPath.length)[self refreshMods];else [self renderMods];
 return self;
}
- (void)updateSaveButton {
 BOOL valid=!self.selected.count&&!self.conflictCheckFailed;
 if(self.selected.count&&self.rootPath.length&&!self.scanning&&!self.checkingConflicts&&!self.conflicts.count){
  valid=YES;
  for(NSDictionary *mod in self.mods)if([self.selected containsObject:mod[@"name"]]&&![mod[@"supported"] boolValue])valid=NO;
  for(NSString *name in self.selected){BOOL found=NO;for(NSDictionary *mod in self.mods)found|=[name isEqualToString:mod[@"name"]];if(!found)valid=NO;}
 }
 self.saveButton.enabled=valid&&!self.preparing&&!self.scanning&&!self.checkingConflicts;
}
-(void)renderMods {
 CGFloat rowHeight=58,width=self.scroll.contentSize.width;
 CGFloat contentHeight=fmax(self.scroll.bounds.size.height,self.mods.count*rowHeight);
 self.list.frame=NSMakeRect(0,0,width,contentHeight);
 for(NSView *view in self.list.subviews)[view removeFromSuperview];
 if(!self.rootPath.length||!self.mods.count){
  NSTextField *empty=[NSTextField labelWithString:self.rootPath.length?@(TOTK_UI("此文件夹下没有模组子文件夹","No mod subfolders in this folder")):@(TOTK_UI("请先选择存放已解压模组的文件夹","Choose a folder containing unpacked mods"))];
  empty.font=[NSFont systemFontOfSize:13];empty.textColor=[NSColor colorWithCalibratedWhite:0.75 alpha:1];empty.alignment=NSTextAlignmentCenter;
  empty.frame=NSMakeRect(12,(contentHeight-24)/2,width-24,24);[self.list addSubview:empty];return;
 }
 [self.mods enumerateObjectsUsingBlock:^(NSDictionary *mod,NSUInteger index,BOOL *stop){
  (void)stop;CGFloat y=contentHeight-(index+1)*rowHeight;NSView *row=[[NSView alloc] initWithFrame:NSMakeRect(4,y+2,width-8,rowHeight-4)];
  row.wantsLayer=YES;row.layer.backgroundColor=[NSColor colorWithCalibratedWhite:1 alpha:0.07].CGColor;row.layer.cornerRadius=6;
  BOOL supported=[mod[@"supported"] boolValue];NSString *name=mod[@"name"];
  NSButton *check=[NSButton checkboxWithTitle:@"" target:self action:@selector(toggleMod:)];check.tag=(NSInteger)index;check.state=[self.selected containsObject:name]?NSControlStateValueOn:NSControlStateValueOff;
  check.enabled=supported;check.frame=NSMakeRect(12,16,26,24);[row addSubview:check];
  NSTextField *label=[NSTextField labelWithString:name];label.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];label.textColor=NSColor.whiteColor;
  label.lineBreakMode=NSLineBreakByTruncatingMiddle;label.frame=NSMakeRect(48,28,width-80,18);[row addSubview:label];
  NSString *detail=supported?[NSString stringWithFormat:@(TOTK_UI("%lu 个 RomFS 文件","%lu RomFS files")),(unsigned long)[mod[@"files"] unsignedIntegerValue]]:mod[@"reason"];
  NSTextField *info=[NSTextField labelWithString:detail];info.font=[NSFont systemFontOfSize:11];info.textColor=supported?[NSColor colorWithCalibratedWhite:0.72 alpha:1]:NSColor.systemOrangeColor;
  info.lineBreakMode=NSLineBreakByTruncatingMiddle;info.frame=NSMakeRect(48,8,width-80,16);[row addSubview:info];[self.list addSubview:row];
 }];
}
-(void)refreshMods {
 if(!self.rootPath.length){self.mods=@[];self.conflicts=@[];self.scanning=NO;self.statusLabel.stringValue=@(TOTK_UI("请先选择模组文件夹。","Choose a mods folder first."));[self renderMods];[self updateSaveButton];return;}
 self.scanning=YES;self.checkingConflicts=NO;self.conflictCheckFailed=NO;self.conflicts=@[];uint64_t request=++self.scanRequest;
 self.folderLabel.stringValue=self.rootPath;self.statusLabel.stringValue=@(TOTK_UI("正在扫描模组文件夹…","Scanning mod folders…"));[self updateSaveButton];
 mod_manager_run(@[@"scan",@"--source",self.rootPath],^(id result,NSString *problem){
  if(!modManagerOpen||request!=self.scanRequest)return;self.scanning=NO;
  if(problem||![result isKindOfClass:NSArray.class]){self.mods=@[];self.statusLabel.stringValue=problem?:@(TOTK_UI("扫描结果无效。","The scan result is invalid."));[self renderMods];[self updateSaveButton];return;}
  self.mods=result;[self renderMods];[self checkConflicts];
 });
}
-(void)checkConflicts {
 uint64_t request=++self.conflictRequest;self.conflicts=@[];self.conflictCheckFailed=NO;
 NSArray<NSString *> *names=mod_manager_sorted_names(self.selected);
 if(!names.count){self.checkingConflicts=NO;self.statusLabel.stringValue=@(TOTK_UI("未选择模组。保存后下次启动不加载管理器模组。","No mods selected. Saving disables managed mods at next launch."));[self updateSaveButton];return;}
 BOOL invalid=NO;
 for(NSString *name in names){BOOL found=NO;for(NSDictionary *mod in self.mods)if([name isEqualToString:mod[@"name"]]){found=YES;if(![mod[@"supported"] boolValue])invalid=YES;}
  if(!found)invalid=YES;
 }
 if(invalid){self.checkingConflicts=NO;self.conflictCheckFailed=YES;self.statusLabel.stringValue=@(TOTK_UI("所选模组已缺失或不受支持；请刷新列表并调整选择。","A selected mod is missing or unsupported; refresh and adjust the selection."));[self updateSaveButton];return;}
 self.checkingConflicts=YES;self.statusLabel.stringValue=@(TOTK_UI("正在检查文件冲突…","Checking file conflicts…"));[self updateSaveButton];
 NSMutableArray<NSString *> *args=[NSMutableArray arrayWithObjects:@"conflicts",@"--source",self.rootPath,nil];
 for(NSString *name in names){[args addObject:@"--mod"];[args addObject:name];}
 mod_manager_run(args,^(id result,NSString *problem){
  if(!modManagerOpen||request!=self.conflictRequest)return;self.checkingConflicts=NO;
  if(problem||![result isKindOfClass:NSArray.class]){self.conflictCheckFailed=YES;self.statusLabel.stringValue=problem?:@(TOTK_UI("冲突检查结果无效。","Conflict check result is invalid."));[self updateSaveButton];return;}
  self.conflicts=result;
  if(self.conflicts.count){NSMutableArray<NSString *> *lines=[NSMutableArray array];for(NSDictionary *item in self.conflicts){
    [lines addObject:[NSString stringWithFormat:@(TOTK_UI("%@：%@","%@ — %@")),[item[@"mods"] componentsJoinedByString:@", "],item[@"path"]]];}
   self.statusLabel.stringValue=[NSString stringWithFormat:@(TOTK_UI("存在文件冲突，不能保存：%@","File conflicts block saving: %@")),[lines componentsJoinedByString:@"\n"]];
  }else self.statusLabel.stringValue=@(TOTK_UI("没有文件冲突。保存后下次启动生效；归档内部资源不会自动合并。","No file conflicts. Changes apply next launch; archive internals are not merged."));
  [self updateSaveButton];
 });
}
-(void)toggleMod:(NSButton *)button {
 if(button.tag<0||(NSUInteger)button.tag>=self.mods.count)return;
 NSString *name=self.mods[(NSUInteger)button.tag][@"name"];
 if(button.state==NSControlStateValueOn)[self.selected addObject:name];else [self.selected removeObject:name];
 [self checkConflicts];
}
-(void)chooseFolder:(id)sender {
 (void)sender;NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;panel.allowsMultipleSelection=NO;
 if(self.rootPath.length)panel.directoryURL=[NSURL fileURLWithPath:self.rootPath isDirectory:YES];
 panel.message=@(TOTK_UI("选择包含各个已解压模组子文件夹的目录","Choose the folder containing unpacked mod subfolders"));
 panel.prompt=@(TOTK_UI("使用此文件夹","Use This Folder"));if([panel runModal]!=NSModalResponseOK)return;
 if(![self.rootPath isEqualToString:panel.URL.path])[self.selected removeAllObjects];
 self.rootPath=panel.URL.path;self.folderLabel.stringValue=self.rootPath;[self refreshMods];
}
-(void)refresh:(id)sender{(void)sender;[self refreshMods];}
-(void)writeConfig:(NSDictionary *)config {
 NSError *error=nil;NSString *path=mod_manager_config_path();
 if(![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error]){
  self.statusLabel.stringValue=error.localizedDescription;return;
 }
 NSData *data=[NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
 if(!data||![data writeToFile:path options:NSDataWritingAtomic error:&error]){self.statusLabel.stringValue=error.localizedDescription?:@(TOTK_UI("无法保存模组设置。","Could not save mod settings."));return;}
 self.statusLabel.stringValue=@(TOTK_UI("已准备完成；当前游戏不变，下次启动生效。","Prepared. The running game is unchanged; changes take effect next launch."));
 [self updateSaveButton];
}
-(void)save:(id)sender {
 (void)sender;if(self.preparing||self.scanning||self.checkingConflicts)return;
 NSArray<NSString *> *names=mod_manager_sorted_names(self.selected);
 if(!names.count){
  [self writeConfig:@{@"enabled":@NO,@"source":self.rootPath?:@"",@"mods":@[]}];return;
 }
 self.preparing=YES;self.saveButton.title=@(TOTK_UI("正在准备…","Preparing…"));self.statusLabel.stringValue=@(TOTK_UI("正在复制资源并生成 RomFS 清单；不会改动本次运行使用的文件。","Copying resources and building the RomFS manifest; the current files are untouched."));[self updateSaveButton];
 NSMutableArray<NSString *> *args=[NSMutableArray arrayWithObjects:@"prepare",@"--source",self.rootPath,
  @"--app",mod_manager_app_path(),@"--generations",[mod_manager_config_path().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"generations"],
  @"--version",@"botw160",nil];
 for(NSString *name in names){[args addObject:@"--mod"];[args addObject:name];}
 __weak BOTWModManagerPanel *weak=self;
 mod_manager_run(args,^(id result,NSString *problem){
  BOTWModManagerPanel *strong=weak;if(!strong)return;strong.preparing=NO;strong.saveButton.title=@(TOTK_UI("保存并准备","Save and Prepare"));
  if(problem||![result isKindOfClass:NSDictionary.class]){strong.statusLabel.stringValue=problem?:@(TOTK_UI("模组准备结果无效。","The preparation result is invalid."));[strong updateSaveButton];return;}
  NSString *generation=[result[@"generation"] isKindOfClass:NSString.class]?result[@"generation"]:nil;
  if(!generation.length){strong.statusLabel.stringValue=@(TOTK_UI("准备工具没有返回生成目录。","The helper returned no generation directory."));[strong updateSaveButton];return;}
  [strong writeConfig:@{@"enabled":@YES,@"source":strong.rootPath,@"mods":names,@"generation":generation}];
 });
}
-(void)close:(id)sender{(void)sender;mod_manager_show(0);}
-(void)center{if(self.superview)[self setFrameOrigin:NSMakePoint(floor((self.superview.bounds.size.width-self.frame.size.width)/2),floor((self.superview.bounds.size.height-self.frame.size.height)/2))];}
-(void)viewDidMoveToSuperview{[super viewDidMoveToSuperview];[self center];}
@end

static BOTWModManagerPanel *modManagerPanel;
static void mod_manager_show(int open) {
 open=!!open;if(!window||open==modManagerOpen)return;
 if(open){if(!settingsOpen)return;modManagerOpen=YES;if(!modManagerPanel)modManagerPanel=[BOTWModManagerPanel new];else [modManagerPanel refreshMods];
  runtime_input_clear();settingsPanel.hidden=YES;[window.contentView addSubview:modManagerPanel];[modManagerPanel center];[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:NO];
 }else{
  modManagerOpen=NO;[modManagerPanel removeFromSuperview];if(settingsOpen)settingsPanel.hidden=NO;[window makeFirstResponder:window.contentView];
  if(window.isKeyWindow&&(window.styleMask&NSWindowStyleMaskFullScreen))[(TOTKInputView *)window.contentView setCursorAutoHideEnabled:YES];
 }
 front_mouse_update();fprintf(stderr,"[botw] mod manager panel %s\n",open?"open":"closed");
}
#endif
