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
            if (strcmp((const char *)eventData, "vf5-stop-test") == 0) {
                // Test-only command. Never call from a charger automation until
                // recording state and saved video have been verified on-device.
                id frontApp = getFrontMostApplication();
                NSString *bundleId = [frontApp respondsToSelector:@selector(bundleIdentifier)]
                    ? [frontApp bundleIdentifier] : nil;
                UIDevice *device = [UIDevice currentDevice];
                device.batteryMonitoringEnabled = YES;
                CGSize size = [UIScreen mainScreen].bounds.size;
                if (![bundleId isEqualToString:@"com.helge.droiddashcam"] ||
                    device.batteryState == UIDeviceBatteryStateUnknown ||
                    device.batteryState == UIDeviceBatteryStateUnplugged ||
                    fabs(size.width - 375.0) > 1.0 || fabs(size.height - 667.0) > 1.0) {
                    notifyClient((UInt8*)"1;;Stop test requires Droid foreground, portrait iPhone 7 and external power\r\n", writeStreamRef);
                } else {
                    // ZXTouch expects physical pixels (750x1334), not UIKit points (375x667).
                    performTouchFromRawData((UInt8*)"11000370011720");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                        performTouchFromRawData((UInt8*)"10000370011720");
                    });
                    notifyClient((UInt8*)"0;;Stop tap sent; verify the recording and MP4 manually\r\n", writeStreamRef);
                }
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
