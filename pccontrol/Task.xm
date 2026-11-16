#include "Task.h"
#include <math.h>
#include <roothide.h>
#include "Touch.h"
#include "ColorPicker.h"
#include "ScreenMatch.h"
#include "Process.h"
#include "AlertBox.h"
#include "Record.h"
#include "Play.h"
#include "SocketServer.h"
#include "Toast.h"
#include "Common.h"
#include "UIKeyboard.h"
#include "DeviceInfo.h"
#include "TouchIndicator/TouchIndicatorWindow.h"
#import <mach/mach.h>
#import <objc/message.h>
#include <Foundation/NSDistributedNotificationCenter.h>
#include <TextRecognization/TextRecognizer.h>
#include "UpdateCache.h"
#include "Screen.h"
#include "Runner.h"

extern CFRunLoopRef recordRunLoop;

static BOOL VF5StopPending = NO;

static BOOL VF5StopTouchCodes(const UInt8 **down, const UInt8 **up) {
    CGSize nativeSize = [UIScreen mainScreen].nativeBounds.size;
    if (fabs(MIN(nativeSize.width, nativeSize.height) - 750.0) > 1.0 ||
        fabs(MAX(nativeSize.width, nativeSize.height) - 1334.0) > 1.0) return NO;

    switch ([Screen getScreenOrientation]) {
        case UIInterfaceOrientationLandscapeRight:
            // Observed orientation=3 with volume buttons down; native touch still needs verification.
            *down = (const UInt8 *)"11000120006640";
            *up   = (const UInt8 *)"10000120006640";
            return YES;
        default:
            return NO; // VF5 dashcam supports the measured landscape orientation only.
    }
}

// The charger shortcut calls this inside SpringBoard. Never lock until the
// newest recording has a complete MP4 index and has stopped changing.
static void VF5Log(NSString *message) {
    NSString *path = @"/var/mobile/Media/Downloads/vf5-automation.log";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (NSException *exception) {
        NSLog(@"VF5 log write failed: %@", exception);
    }
    NSLog(@"VF5 %@", message);
}

static BOOL VF5PowerMatches(BOOL mustBeUnplugged) {
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    UIDeviceBatteryState state = device.batteryState;
    return mustBeUnplugged ? state == UIDeviceBatteryStateUnplugged :
        (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
}

static BOOL VF5DroidForeground(void) {
    id app = getFrontMostApplication();
    return [app respondsToSelector:@selector(bundleIdentifier)] &&
        [[app bundleIdentifier] isEqualToString:@"com.helge.droiddashcam"];
}

static NSString *VF5LatestRecording(void) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    id proxy = (cls && [cls respondsToSelector:lookup])
        ? ((id (*)(id, SEL, id))objc_msgSend)(cls, lookup, @"com.helge.droiddashcam") : nil;
    SEL container = NSSelectorFromString(@"dataContainerURL");
    NSURL *url = (proxy && [proxy respondsToSelector:container])
        ? ((id (*)(id, SEL))objc_msgSend)(proxy, container) : nil;
    NSString *directory = [[url path] stringByAppendingPathComponent:@"Documents/Temporary"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *latestDate = nil;
    NSString *latestPath = nil;
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (![[name.pathExtension lowercaseString] isEqualToString:@"mp4"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *modified = attrs[NSFileModificationDate];
        if (modified && (!latestDate || [modified compare:latestDate] == NSOrderedDescending)) {
            latestDate = modified;
            latestPath = path;
        }
    }
    // Never tap Stop for a stale recording or a clip from a previous trip.
    return (latestDate && -[latestDate timeIntervalSinceNow] <= 60.0) ? latestPath : nil;
}

static BOOL VF5MP4Finalized(NSString *path, unsigned long long *lengthOut) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long length = [attrs[NSFileSize] unsignedLongLongValue];
    if (lengthOut) *lengthOut = length;
    if (length < 1024 * 1024) return NO;
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return NO;
    BOOL ftyp = NO, mdat = NO, moov = NO, valid = YES;
    unsigned long long offset = 0;
    @try {
        for (NSUInteger atom = 0; offset + 8 <= length && atom < 32; atom++) {
            [file seekToFileOffset:offset];
            NSData *data = [file readDataOfLength:16];
            if (data.length < 8) { valid = NO; break; }
            const unsigned char *p = (const unsigned char *)data.bytes;
            unsigned long long atomSize = ((unsigned long long)p[0]<<24) |
                ((unsigned long long)p[1]<<16) | ((unsigned long long)p[2]<<8) | p[3];
            unsigned long long headerSize = 8;
            if (atomSize == 1) {
                if (data.length < 16) { valid = NO; break; }
                atomSize = 0;
                for (NSUInteger j = 8; j < 16; j++) atomSize = (atomSize << 8) | p[j];
                headerSize = 16;
            } else if (atomSize == 0) {
                atomSize = length - offset;
            }
            if (atomSize < headerSize || atomSize > length - offset) { valid = NO; break; }
            if (memcmp(p + 4, "ftyp", 4) == 0) ftyp = YES;
            if (memcmp(p + 4, "mdat", 4) == 0) mdat = YES;
            if (memcmp(p + 4, "moov", 4) == 0) moov = YES;
            offset += atomSize;
        }
        if (offset != length) valid = NO;
        [file closeFile];
    } @catch (NSException *exception) {
        valid = NO;
        @try { [file closeFile]; } @catch (NSException *ignored) {}
    }
    return valid && ftyp && mdat && moov;
}

static void VF5WaitForSavedClip(NSString *path, BOOL unplug, NSUInteger tries,
                                unsigned long long previousLength) {
    if (!VF5PowerMatches(unplug)) {
        VF5Log(@"CANCEL power changed before finalizing");
        VF5StopPending = NO;
        return;
    }
    unsigned long long length = 0;
    BOOL finalized = VF5MP4Finalized(path, &length);
    if (finalized && length == previousLength) {
        if (!unplug) {
            VF5Log([NSString stringWithFormat:@"PASS test-stop finalized MP4 size=%llu", length]);
            VF5StopPending = NO;
            return;
        }
        if (!VF5DroidForeground() || !VF5PowerMatches(YES)) {
            VF5Log(@"CANCEL screen/power changed before lock");
            VF5StopPending = NO;
            return;
        }
        Class cls = NSClassFromString(@"SBLockScreenManager");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        SEL lock = NSSelectorFromString(@"lockUIFromSource:withOptions:");
        id manager = (cls && [cls respondsToSelector:shared])
            ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        if (!manager || ![manager respondsToSelector:lock]) {
            VF5Log(@"FAIL lock API missing; MP4 saved");
            VF5StopPending = NO;
            return;
        }
        VF5Log([NSString stringWithFormat:@"PASS finalized MP4 size=%llu; locking", length]);
        VF5StopPending = NO;
        ((void (*)(id, SEL, int, id))objc_msgSend)(manager, lock, 1, nil);
        return;
    }
    if (tries >= 15) {
        VF5Log([NSString stringWithFormat:@"FAIL MP4 not finalized/stable after 15s size=%llu", length]);
        VF5StopPending = NO;
        return; // Fail open: leave screen on to protect the clip.
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        VF5WaitForSavedClip(path, unplug, tries + 1, finalized ? length : 0);
    });
}

static void VF5StopAndVerify(BOOL unplug) {
    const UInt8 *down = NULL, *up = NULL;
    if (!VF5StopTouchCodes(&down, &up)) {
        VF5Log(@"CANCEL unsupported device or display orientation; Stop coordinates unsafe");
        VF5StopPending = NO;
        return;
    }
    if (!VF5PowerMatches(unplug) || !VF5DroidForeground()) {
        VF5Log(@"CANCEL power or foreground not ready");
        VF5StopPending = NO;
        return;
    }
    NSString *path = VF5LatestRecording();
    unsigned long long bytes = 0;
    if (!path || VF5MP4Finalized(path, &bytes)) {
        VF5Log(@"CANCEL no fresh unfinished MP4; no Stop tap");
        VF5StopPending = NO;
        return;
    }
    performTouchFromRawData((UInt8 *)down);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        performTouchFromRawData((UInt8 *)up);
        VF5Log(@"Stop tapped; waiting for finalized MP4");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            VF5WaitForSavedClip(path, unplug, 1, 0);
        });
    });
}

/*
get task type
*/
static int getTaskType(UInt8* dataArray)
{
	int taskType = 0;
	for (int i = 0; i <= 1; i++)
	{
		taskType += (dataArray[i] - '0')*pow(10, 1-i);
	}
	return taskType;
}

/**
Process Task
*/
void processTask(UInt8 *buff, CFWriteStreamRef writeStreamRef)
{
    //NSLog(@"### com.zjx.springboard: task type: %d. Data: %s", getTaskType(buff), buff);
    UInt8 *eventData = buff + 0x2;
    int taskType = getTaskType(buff);

    //for touching
    if (taskType == TASK_PERFORM_TOUCH)
    {
        @autoreleasepool{
            performTouchFromRawData(eventData);
        }
    }
    else if (taskType == TASK_PROCESS_BRING_FOREGROUND) //bring to foreground
    {
        @autoreleasepool{   
            switchProcessForegroundFromRawData(eventData);
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_SHOW_ALERT_BOX)
    {
        @autoreleasepool{   
            NSError *err = nil;
            showAlertBoxFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_USLEEP)
    {
        if (writeStreamRef)
        {
            int usleepTime = 0;
            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
            notifyClient((UInt8*)"0;;Sleep ends\r\n", writeStreamRef); 
        }
        else
        {
            int usleepTime = 0;

            @try{
                usleepTime = atoi((char*)eventData);
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Debug: %@", exception.reason);
                return;
            }
            //NSLog(@"com.zjx.springboard: sleep %d microseconds", usleepTime);
            usleep(usleepTime);
        }

    }
    else if (taskType == TASK_RUN_SHELL)
    {
        @autoreleasepool{
            if (strcmp((const char *)eventData, "vf5-stop-test") == 0 ||
                strcmp((const char *)eventData, "vf5-stop-unplug") == 0 ||
                strcmp((const char *)eventData, "vf5-stop-verify-test") == 0) {
                // Test-only command. Never call from a charger automation until
                // recording state and saved video have been verified on-device.
                BOOL unplug = strcmp((const char *)eventData, "vf5-stop-unplug") == 0;
                BOOL verify = unplug || strcmp((const char *)eventData, "vf5-stop-verify-test") == 0;
                if (verify) {
                    if (VF5StopPending) {
                        notifyClient((UInt8*)"1;;VF5 stop already in progress\r\n", writeStreamRef);
                    } else {
                        VF5StopPending = YES;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (unplug ? 2 : 0) * NSEC_PER_SEC),
                                       dispatch_get_main_queue(), ^{ VF5StopAndVerify(unplug); });
                        notifyClient((UInt8*)"0;;Stop/MP4 verification queued; lock only on unplug and verified save\r\n", writeStreamRef);
                    }
                } else {
                id frontApp = getFrontMostApplication();
                NSString *bundleId = [frontApp respondsToSelector:@selector(bundleIdentifier)]
                    ? [frontApp bundleIdentifier] : nil;
                UIDevice *device = [UIDevice currentDevice];
                device.batteryMonitoringEnabled = YES;
                const UInt8 *down = NULL, *up = NULL;
                if (![bundleId isEqualToString:@"com.helge.droiddashcam"] ||
                    device.batteryState == UIDeviceBatteryStateUnknown ||
                    (unplug ? device.batteryState != UIDeviceBatteryStateUnplugged :
                        device.batteryState == UIDeviceBatteryStateUnplugged) ||
                    !VF5StopTouchCodes(&down, &up)) {
                    notifyClient((UInt8*)"1;;Stop test requires Droid foreground, supported iPhone 7 orientation and expected power\r\n", writeStreamRef);
                } else {
                    // Debounce unplug events; a reconnect must cancel the Stop tap.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (unplug ? 2 : 0) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        device.batteryMonitoringEnabled = YES;
                        if ((unplug && device.batteryState != UIDeviceBatteryStateUnplugged) ||
                            (!unplug && device.batteryState == UIDeviceBatteryStateUnplugged)) return;
                        id currentApp = getFrontMostApplication();
                        if (![currentApp respondsToSelector:@selector(bundleIdentifier)] ||
                            ![[currentApp bundleIdentifier] isEqualToString:@"com.helge.droiddashcam"]) return;
                        const UInt8 *tapDown = NULL, *tapUp = NULL;
                        if (!VF5StopTouchCodes(&tapDown, &tapUp)) return;
                        performTouchFromRawData((UInt8 *)tapDown);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                            performTouchFromRawData((UInt8 *)tapUp);
                        });
                    });
                    notifyClient((UInt8*)"0;;Stop tap queued; confirm recording and MP4 before enabling automation\r\n", writeStreamRef);
                }
                }
            } else if (strcmp((const char *)eventData, "vf5-status") == 0) {
                UIDevice *device = [UIDevice currentDevice];
                device.batteryMonitoringEnabled = YES;
                id app = getFrontMostApplication();
                NSString *bundle = [app respondsToSelector:@selector(bundleIdentifier)]
                    ? [app bundleIdentifier] : @"(none)";
                CGSize size = [UIScreen mainScreen].nativeBounds.size;
                NSString *message = [NSString stringWithFormat:
                    @"0;;VF5 app=%@ orientation=%d battery=%ld native=%.0fx%.0f touch=%.0fx%.0f\r\n",
                    bundle, [Screen getScreenOrientation], (long)device.batteryState,
                    size.width, size.height, [Screen getScreenWidth], [Screen getScreenHeight]];
                notifyClient((UInt8 *)[message UTF8String], writeStreamRef);
            } else if (strcmp((const char *)eventData, "vf5-file-probe") == 0) {
                Class proxyClass = NSClassFromString(@"LSApplicationProxy");
                SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
                id proxy = (proxyClass && [proxyClass respondsToSelector:lookup])
                    ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, lookup, @"com.helge.droiddashcam") : nil;
                SEL container = NSSelectorFromString(@"dataContainerURL");
                NSURL *dataURL = (proxy && [proxy respondsToSelector:container])
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, container) : nil;
                NSString *directory = [[dataURL path] stringByAppendingPathComponent:@"Documents/Temporary"];
                NSError *error = nil;
                NSArray *names = directory ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:&error] : nil;
                NSString *answer = names
                    ? [NSString stringWithFormat:@"0;;VF5 probe accessible=%lu path=%@\r\n", (unsigned long)[names count], directory]
                    : [NSString stringWithFormat:@"1;;VF5 probe dataURL=%@ error=%@\r\n", dataURL, error];
                notifyClient((UInt8*)[answer UTF8String], writeStreamRef);
            } else if (strcmp((const char *)eventData, "vf5-lock") == 0) {
                Class managerClass = NSClassFromString(@"SBLockScreenManager");
                SEL singleton = NSSelectorFromString(@"sharedInstance");
                SEL lock = NSSelectorFromString(@"lockUIFromSource:withOptions:");
                id manager = (managerClass && [managerClass respondsToSelector:singleton])
                    ? ((id (*)(id, SEL))objc_msgSend)(managerClass, singleton) : nil;
                if (manager && [manager respondsToSelector:lock]) {
                    // Recheck actual power immediately before locking: a stale unplug event
                    // must never lock the screen after the charger is reconnected.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        UIDevice *device = [UIDevice currentDevice];
                        device.batteryMonitoringEnabled = YES;
                        if (device.batteryState == UIDeviceBatteryStateUnplugged) {
                            ((void (*)(id, SEL, int, id))objc_msgSend)(manager, lock, 1, nil);
                        }
                    });
                    notifyClient((UInt8*)"0;;Lock queued with 3s power guard\r\n", writeStreamRef);
                } else {
                    notifyClient((UInt8*)"1;;SpringBoard lock API unavailable\r\n", writeStreamRef);
                }
            } else {
                system2([[NSString stringWithFormat:@"%@ -c \"%s\"", jbroot(@"/bin/sh"), eventData] UTF8String], NULL, NULL);
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_START)
    {
        @autoreleasepool {
            NSError *err = nil;
            startRecording(writeStreamRef, &err);    
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_RECORDING_STOP)
    {
        @autoreleasepool {
            stopRecording(); 
            notifyClient((UInt8*)"0\r\n", writeStreamRef); 
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT)
    {
        @autoreleasepool {
            NSError *err = nil;
            playScript((UInt8*)eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PLAY_SCRIPT_FORCE_STOP)
    {
        @autoreleasepool {
            NSError *err = nil;
            stopScriptPlaying(&err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEMPLATE_MATCH)
    {
        @autoreleasepool {
            NSError *err = nil;
            CGRect result = screenMatchFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%.2f;;%.2f;;%.2f;;%.2f\r\n",
                    result.origin.x, result.origin.y, result.size.width, result.size.height] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SHOW_TOAST)
    {
        @autoreleasepool {
            NSError *err = nil;
            showToastFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_PICKER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSDictionary *result = getRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@;;%@;;%@\r\n",
                    result[@"red"], result[@"green"], result[@"blue"]] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = inputTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_GET_DEVICE_INFO)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *deviceInfo = getDeviceInfoFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", deviceInfo] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TOUCH_INDICATOR)
    {
        @autoreleasepool {
            NSError *err = nil;
            handleTouchIndicatorTaskWithRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)"0\r\n", writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_TEXT_RECOGNIZER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *text = performTextRecognizerTextFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", text] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_COLOR_SEARCHER)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = searchRGBFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_PROMPT_INPUT)
    {
        @autoreleasepool {
            NSError *err = nil;
            NSString *result = promptInputFromRawData(eventData, &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                result = [[result stringByReplacingOccurrencesOfString:@"\r" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                notifyClient((UInt8*)[[NSString stringWithFormat:@"0;;%@\r\n", result] UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_SCREENSHOT)
    {
        @autoreleasepool {
            if (!writeStreamRef) {
                return;
            }

            CGImageRef screenshot = NULL;
            BOOL responseHeaderSent = NO;

            @try {
                screenshot = [Screen createScreenShotCGImageRef];
                if (!screenshot) {
                    notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
                    return;
                }

                UIImageOrientation imageOrientation = UIImageOrientationUp;
                int screenOrientation = [Screen getScreenOrientation];
                if (screenOrientation == 4) {
                    imageOrientation = UIImageOrientationRight;
                } else if (screenOrientation == 3) {
                    imageOrientation = UIImageOrientationLeft;
                } else if (screenOrientation == 2) {
                    imageOrientation = UIImageOrientationDown;
                }

                UIImage *image = [UIImage imageWithCGImage:screenshot
                                                     scale:[Screen getScale]
                                               orientation:imageOrientation];
                if (image && imageOrientation != UIImageOrientationUp) {
                    CGFloat scale = [Screen getScale];
                    CGSize orientedSize = CGSizeMake(CGImageGetWidth(screenshot) / scale,
                                                     CGImageGetHeight(screenshot) / scale);
                    if (imageOrientation == UIImageOrientationLeft ||
                        imageOrientation == UIImageOrientationRight) {
                        orientedSize = CGSizeMake(orientedSize.height, orientedSize.width);
                    }

                    UIGraphicsBeginImageContextWithOptions(orientedSize, YES, scale);
                    [image drawInRect:CGRectMake(0, 0, orientedSize.width, orientedSize.height)];
                    UIImage *orientedImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();
                    image = orientedImage;
                }

                NSData *jpegData = image ? UIImageJPEGRepresentation(image, 0.85) : nil;
                if (!jpegData || [jpegData length] == 0) {
                    notifyClient((UInt8 *)"-1;;Unable to encode screenshot as JPEG\r\n", writeStreamRef);
                    return;
                }

                NSString *header = [NSString stringWithFormat:@"0;;image/jpeg;;%lu\r\n",
                                                             (unsigned long)[jpegData length]];
                NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
                if (!headerData || notifyClientData((const UInt8 *)[headerData bytes],
                                                    (CFIndex)[headerData length],
                                                    writeStreamRef) != 0) {
                    return;
                }
                responseHeaderSent = YES;

                if (notifyClientData((const UInt8 *)[jpegData bytes],
                                     (CFIndex)[jpegData length],
                                     writeStreamRef) != 0) {
                    NSLog(@"com.zjx.springboard: Failed to send screenshot JPEG payload.");
                }
            }
            @catch (NSException *exception) {
                NSLog(@"com.zjx.springboard: Screenshot task failed: %@", exception.reason);
                if (!responseHeaderSent) {
                    notifyClient((UInt8 *)"-1;;Unable to capture screenshot\r\n", writeStreamRef);
                }
            }
            @finally {
                if (screenshot) {
                    CGImageRelease(screenshot);
                }
            }
        }
    }
    else if (taskType == TASK_UPDATE_CACHE)
    {
        @autoreleasepool{
            NSError *err = nil;
            updateCacheFromRawData(eventData,  &err);
            if (err)
            {
                notifyClient((UInt8*)[[err localizedDescription] UTF8String], writeStreamRef);
            }
            else
            {
                notifyClient((UInt8*)[@"0\r\n" UTF8String], writeStreamRef);
            }
        }
    }
    else if (taskType == TASK_RUNNER_REGISTER)
    {
        // No reply on purpose: this connection is the runner's job channel and
        // it reads every line written to it as an instruction.
        zxRunnerRegister((const char *)eventData, writeStreamRef);
    }
    else if (taskType == TASK_RUNNER_EVENT)
    {
        zxRunnerHandleEvent((const char *)eventData, writeStreamRef);
    }
    else if (taskType == TASK_TEST)
    {

    }
}
