/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */


#import <Cordova/CDVURLSchemeHandler.h>
#import <Cordova/CDVViewController.h>
#import <Cordova/CDVPlugin.h>
#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>

#import <objc/message.h>

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

static const NSUInteger FILE_BUFFER_SIZE = 1024 * 1024 * 4; // 4 MiB

@interface CDVURLSchemeHandler ()

@end

@implementation CDVURLSchemeHandler

- (instancetype)initWithViewController:(CDVViewController *)controller
{
    self = [super init];
    if (self) {
        _viewController = controller;
        _handlerMap = [NSMapTable weakToWeakObjectsMapTable];
    }
    return self;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id <WKURLSchemeTask>)urlSchemeTask
{
    // Give plugins the chance to handle the url
    NSDictionary *pluginObjects = [[self.viewController pluginObjects] copy];
    for (NSString* pluginName in pluginObjects) {
        CDVPlugin *plugin = [self.viewController.pluginObjects objectForKey:pluginName];
        SEL selector = NSSelectorFromString(@"overrideSchemeTask:");
        if ([plugin respondsToSelector:selector]) {
            BOOL handledRequest = (((BOOL (*)(id, SEL, id <WKURLSchemeTask>))objc_msgSend)(plugin, selector, urlSchemeTask));
            if (handledRequest) {
                // Store the plugin that is handling this particular request
                [self.handlerMap setObject:plugin forKey:urlSchemeTask];
                return;
            }
        }
    }

    NSURLRequest *req = urlSchemeTask.request;
    if (![req.URL.scheme isEqualToString:self.viewController.appScheme]) {
        return;
    }

    // Indicate that we are handling this task, by adding an entry with a null plugin
    // We do this so that we can (in future) detect if the task is cancelled before we finished feeding it response data
    [self.handlerMap setObject:(id)[NSNull null] forKey:urlSchemeTask];

    [self.viewController.commandDelegate runInBackground:^{
        NSURL *fileURL = [self fileURLForRequestURL:req.URL];
        NSError *error;

        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:&error];
        if (!fileHandle || error) {
            if ([self taskActive:urlSchemeTask]) {
                [urlSchemeTask didFailWithError:error];
            }

            @synchronized(self.handlerMap) {
                [self.handlerMap removeObjectForKey:urlSchemeTask];
            }
            return;
        }

        NSInteger statusCode = 200; // Default to 200 OK status
        NSString *mimeType = [self getMimeType:fileURL] ?: @"application/octet-stream";
        NSNumber *fileLength;
        [fileURL getResourceValue:&fileLength forKey:NSURLFileSizeKey error:nil];

        NSNumber *responseSize = fileLength;
        NSUInteger responseSent = 0;

        NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithCapacity:5];
        headers[@"Content-Type"] = mimeType;
        headers[@"Cache-Control"] = @"no-cache";
        headers[@"Content-Length"] = [responseSize stringValue];

        // Check for Range header - only for media files
        NSString *rangeHeader = [urlSchemeTask.request valueForHTTPHeaderField:@"Range"];
        if (rangeHeader && [self isMediaFile:fileURL mimeType:mimeType]) {
            NSRange range = NSMakeRange(NSNotFound, 0);

            if ([rangeHeader hasPrefix:@"bytes="]) {
                NSString *byteRange = [rangeHeader substringFromIndex:6];
                NSArray<NSString *> *rangeParts = [byteRange componentsSeparatedByString:@"-"];
                NSUInteger start = (NSUInteger)[rangeParts[0] integerValue];
                NSUInteger end = rangeParts.count > 1 && ![rangeParts[1] isEqualToString:@""] ? (NSUInteger)[rangeParts[1] integerValue] : [fileLength unsignedIntegerValue] - 1;
                range = NSMakeRange(start, end - start + 1);
            }

            if (range.location != NSNotFound) {
                // Ensure range is valid
                if (range.location >= [fileLength unsignedIntegerValue] && [self taskActive:urlSchemeTask]) {
                    headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%@", fileLength];
                    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:416 HTTPVersion:@"HTTP/1.1" headerFields:headers];
                    [urlSchemeTask didReceiveResponse:response];
                    [urlSchemeTask didFinish];

                    @synchronized(self.handlerMap) {
                        [self.handlerMap removeObjectForKey:urlSchemeTask];
                    }
                    return;
                }

                [fileHandle seekToFileOffset:range.location];
                responseSize = [NSNumber numberWithUnsignedInteger:range.length];
                statusCode = 206; // Partial Content
                headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lu-%lu/%@", (unsigned long)range.location, (unsigned long)(range.location + range.length - 1), fileLength];
                headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)range.length];
            }
        }

        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers];
        if ([self taskActive:urlSchemeTask]) {
            [urlSchemeTask didReceiveResponse:response];
        }

        // Use chunked reading only for media files, otherwise read entire file
        if ([self isMediaFile:fileURL mimeType:mimeType]) {
            while ([self taskActive:urlSchemeTask] && responseSent < [responseSize unsignedIntegerValue]) {
                @autoreleasepool {
                    NSData *data = [self readFromFileHandle:fileHandle upTo:FILE_BUFFER_SIZE error:&error];
                    if (!data || error) {
                        if ([self taskActive:urlSchemeTask]) {
                            [urlSchemeTask didFailWithError:error];
                        }
                        break;
                    }

                    if ([self taskActive:urlSchemeTask]) {
                        [urlSchemeTask didReceiveData:data];
                    }

                    responseSent += data.length;
                }
            }
        } else {
            // For non-media files, read entire file at once (original behavior)
            NSData *data = [self readFromFileHandle:fileHandle upTo:[responseSize unsignedIntegerValue] error:&error];
            if (data && [self taskActive:urlSchemeTask]) {
                [urlSchemeTask didReceiveData:data];
            } else if (error && [self taskActive:urlSchemeTask]) {
                [urlSchemeTask didFailWithError:error];
            }
        }

        [fileHandle closeFile];

        if ([self taskActive:urlSchemeTask]) {
            [urlSchemeTask didFinish];
        }

        @synchronized(self.handlerMap) {
            [self.handlerMap removeObjectForKey:urlSchemeTask];
        }
    }];
}

- (void)webView:(nonnull WKWebView *)webView stopURLSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask
{
    CDVPlugin *plugin;
    @synchronized(self.handlerMap) {
        plugin = [self.handlerMap objectForKey:urlSchemeTask];
    }

    if (![plugin isEqual:[NSNull null]] && [plugin respondsToSelector:@selector(stopSchemeTask:)]) {
    SEL selector = NSSelectorFromString(@"stopSchemeTask:");
        (((void (*)(id, SEL, id <WKURLSchemeTask>))objc_msgSend)(plugin, selector, urlSchemeTask));
    }

    @synchronized(self.handlerMap) {
        [self.handlerMap removeObjectForKey:urlSchemeTask];
    }
}

#pragma mark - Utility methods

- (NSURL *)fileURLForRequestURL:(NSURL *)url
{
    NSURL *resDir = [[NSBundle mainBundle] URLForResource:self.viewController.wwwFolderName withExtension:nil];
    NSURL *filePath;

    if ([url.path hasPrefix:@"/_app_file_"]) {
        NSString *path = [url.path stringByReplacingOccurrencesOfString:@"/_app_file_" withString:@""];
        filePath = [resDir URLByAppendingPathComponent:path];
    } else {
        if ([url.path isEqualToString:@""] || [url.pathExtension isEqualToString:@""]) {
            filePath = [resDir URLByAppendingPathComponent:self.viewController.startPage];
        } else {
            filePath = [resDir URLByAppendingPathComponent:url.path];
        }
    }

    return filePath.URLByStandardizingPath;
}

-(NSString *)getMimeType:(NSURL *)url
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        UTType *uti;
        [url getResourceValue:&uti forKey:NSURLContentTypeKey error:nil];
        return [uti preferredMIMEType];
    }
#endif

    NSString *type;
    [url getResourceValue:&type forKey:NSURLTypeIdentifierKey error:nil];
    return (NSString *)UTTypeCopyPreferredTagWithClass((CFStringRef)type, kUTTagClassMIMEType);
}

- (nullable NSData *)readFromFileHandle:(NSFileHandle *)handle upTo:(NSUInteger)length error:(NSError **)err
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        return [handle readDataUpToLength:length error:err];
    }
#endif

    @try {
        return [handle readDataOfLength:length];
    }
    @catch (NSError *error) {
        if (err != nil) {
            *err = error;
        }
        return nil;
    }
}

- (BOOL)taskActive:(id <WKURLSchemeTask>)task
{
    @synchronized(self.handlerMap) {
        return [self.handlerMap objectForKey:task] != nil;
    }
}

- (BOOL)isMediaExtension:(NSString *)pathExtension
{
    NSArray *mediaExtensions = @[@"m4v", @"mov", @"mp4", @"mpeg",
                           @"aac", @"ac3", @"aiff", @"au", @"flac", @"m4a", @"mp3", @"wav", @"wave"];
    if ([mediaExtensions containsObject:pathExtension.lowercaseString]) {
        return YES;
    }
    return NO;
}

- (BOOL)isMediaFile:(NSURL *)fileURL mimeType:(NSString *)mimeType
{
    // Check by file extension
    if ([self isMediaExtension:fileURL.pathExtension]) {
        return YES;
    }
    
    // Check by MIME type
    NSArray *audioMimeTypes = @[@"audio/m4a", @"audio/mp3", @"audio/mp4", @"audio/mpeg", @"audio/vnd.wave", @"audio/wav"];
    NSArray *videoMimeTypes = @[@"video/mp4", @"video/quicktime"];
    
    if ([audioMimeTypes containsObject:mimeType.lowercaseString] || 
        [videoMimeTypes containsObject:mimeType.lowercaseString]) {
        return YES;
    }
    
    return NO;
}

@end
