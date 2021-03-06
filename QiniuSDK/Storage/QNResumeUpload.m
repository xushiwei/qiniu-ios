//
//  QNResumeUpload.m
//  QiniuSDK
//
//  Created by bailong on 14/10/1.
//  Copyright (c) 2014年 Qiniu. All rights reserved.
//

#import "QNResumeUpload.h"
#import "QNUploadManager.h"
#import "QNUrlSafeBase64.h"
#import "QNConfig.h"
#import "QNResponseInfo.h"
#import "QNHttpManager.h"
#import "QNUploadOption+Private.h"
#import "QNRecorderDelegate.h"

typedef void (^task)(void);

@interface QNResumeUpload ()

@property (nonatomic, strong) NSData *data;
@property (nonatomic, weak) QNHttpManager *httpManager;
@property UInt32 size;
@property (nonatomic) int retryTimes;
@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) NSString *token;
@property (nonatomic, strong) QNUploadOption *option;
@property (nonatomic, strong) QNUpCompletionHandler complete;
@property (nonatomic, strong) NSMutableArray *contexts;
@property (nonatomic, readonly, getter = isCancelled) BOOL cancelled;

@property UInt64 modifyTime;
@property (nonatomic, weak) id <QNRecorderDelegate> recorder;


- (void)makeBlock:(NSString *)uphost
           offset:(UInt32)offset
        blockSize:(UInt32)blockSize
        chunkSize:(UInt32)chunkSize
         progress:(QNInternalProgressBlock)progressBlock
         complete:(QNCompleteBlock)complete;

- (void)putChunk:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
         context:(NSString *)context
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete;

- (void)makeFile:(NSString *)uphost
        complete:(QNCompleteBlock)complete;

@end

@implementation QNResumeUpload

- (instancetype)initWithData:(NSData *)data
                    withSize:(UInt32)size
                     withKey:(NSString *)key
                   withToken:(NSString *)token
       withCompletionHandler:(QNUpCompletionHandler)block
                  withOption:(QNUploadOption *)option
              withModifyTime:(NSDate *)time
                withRecorder:(id <QNRecorderDelegate> )recorder
             withHttpManager:(QNHttpManager *)http {
	if (self = [super init]) {
		_data = data;
		_size = size;
		_key = key;
		_token = [NSString stringWithFormat:@"UpToken %@", token];
		_option = option;
		_complete = block;

		_recorder = recorder;
		_httpManager = http;
		if (time != nil) {
			_modifyTime = [time timeIntervalSince1970];
		}
		_contexts = [[NSMutableArray alloc] initWithCapacity:(size + kQNBlockSize - 1) / kQNBlockSize];
	}
	return self;
}

// save json value
//{
//    "size":filesize,
//    "offset":lastSuccessOffset,
//    "modify_time": lastFileModifyTime,
//    "contexts": contexts
//}

- (void)record:(UInt32)offset {
	if (offset == 0 || _recorder == nil || self.key == nil || [self.key isEqualToString:@""]) {
		return;
	}
	NSNumber *n_size = [NSNumber numberWithUnsignedInt:self.size];
	NSNumber *n_offset = [NSNumber numberWithUnsignedInt:offset];
	NSNumber *n_time = [NSNumber numberWithLongLong:_modifyTime];
	NSMutableDictionary *rec = [NSMutableDictionary dictionaryWithObjectsAndKeys:n_size, @"size", n_offset, @"offset", n_time, @"modify_time", _contexts, @"contexts", nil];

	NSError *error;
	NSData *data = [NSJSONSerialization dataWithJSONObject:rec options:NSJSONWritingPrettyPrinted error:&error];
	if (error != nil) {
		NSLog(@"up record json error %@ %@", self.key, error);
		return;
	}
	error = [_recorder set:self.key data:data];
	if (error != nil) {
		NSLog(@"up record set error %@ %@", self.key, error);
	}
}

- (void)removeRecord {
	if (_recorder == nil) {
		return;
	}
	[_recorder del:self.key];
}

- (UInt32)recoveryFromRecord {
	if (_recorder == nil || self.key == nil || [self.key isEqualToString:@""]) {
		return 0;
	}

	NSData *data = [_recorder get:self.key];
	if (data == nil) {
		return 0;
	}

	NSError *error;
	NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableLeaves error:&error];
	if (error != nil) {
		NSLog(@"recovery error %@ %@", self.key, error);
		[_recorder del:self.key];
		return 0;
	}
	NSNumber *n_offset = info[@"offset"];
	NSNumber *n_size = info[@"size"];
	NSNumber *time = info[@"modify_time"];
	NSArray *contexts = info[@"contexts"];
	if (n_offset == nil || n_size == nil || time == nil || contexts == nil) {
		return 0;
	}

	UInt32 offset = [n_offset unsignedIntValue];
	UInt32 size = [n_size unsignedIntValue];
	if (offset > size || size != self.size) {
		return 0;
	}
	UInt64 t = [time unsignedLongLongValue];
	if (t != _modifyTime) {
		NSLog(@"modify time changed %llu, %llu", t, _modifyTime);
		return 0;
	}
	_contexts = [[NSMutableArray alloc] initWithArray:contexts copyItems:true];
	return offset;
}

- (void)nextTask:(UInt32)offset {
	if (self.isCancelled) {
		self.complete([QNResponseInfo cancel], self.key, nil);
		return;
	}

	if (offset == self.size) {
		QNCompleteBlock completionHandler = ^(QNResponseInfo *info, NSDictionary *resp) {
			if (info.isOK) {
				[self removeRecord];
				if (self.option && self.option.progressHandler) {
					self.option.progressHandler(self.key, 1.0);
				}
			}
			self.complete(info, self.key, resp);
		};
		[self makeFile:kQNUpHost complete:completionHandler];
		return;
	}

	UInt32 chunkSize = [self calcPutSize:offset];
	QNInternalProgressBlock progressBlock = nil;
	if (self.option && self.option.progressHandler) {
		progressBlock = ^(long long totalBytesWritten, long long totalBytesExpectedToWrite) {
			float percent = (float)(offset + totalBytesWritten) / (float)self.size;
			if (percent > 0.95) {
				percent = 0.95;
			}
			self.option.progressHandler(self.key, percent);
		};
	}
	QNCompleteBlock completionHandler = ^(QNResponseInfo *info, NSDictionary *resp) {
		if (info.error != nil) {
			if (info.statusCode == 701) {
				[self nextTask:(offset / kQNBlockSize) * kQNBlockSize];
				return;
			}
			self.complete(info, self.key, resp);
			return;
		}
		_contexts[offset / kQNBlockSize] =  resp[@"ctx"];
		[self record:offset + chunkSize];
		[self nextTask:offset + chunkSize];
	};
	if (offset % kQNBlockSize == 0) {
		UInt32 blockSize = [self calcBlockSize:offset];
		[self makeBlock:kQNUpHost offset:offset blockSize:blockSize chunkSize:chunkSize progress:progressBlock complete:completionHandler];
		return;
	}
	NSString *context = _contexts[offset / kQNBlockSize];
	[self putChunk:kQNUpHost offset:offset size:chunkSize context:context progress:progressBlock complete:completionHandler];
}

- (UInt32)calcPutSize:(UInt32)offset {
	UInt32 left = self.size - offset;
	return left < kQNChunkSize ? left : kQNChunkSize;
}

- (UInt32)calcBlockSize:(UInt32)offset {
	UInt32 left = self.size - offset;
	return left < kQNBlockSize ? left : kQNBlockSize;
}

- (void)makeBlock:(NSString *)uphost
           offset:(UInt32)offset
        blockSize:(UInt32)blockSize
        chunkSize:(UInt32)chunkSize
         progress:(QNInternalProgressBlock)progressBlock
         complete:(QNCompleteBlock)complete {
	NSData *data = [self.data subdataWithRange:NSMakeRange(offset, (unsigned int)chunkSize)];
	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/mkblk/%u", uphost, (unsigned int)blockSize];
	[self post:url withData:data withCompleteBlock:complete withProgressBlock:progressBlock];
}

- (void)putChunk:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
         context:(NSString *)context
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete {
	NSData *data = [self.data subdataWithRange:NSMakeRange(offset, (unsigned int)size)];
	UInt32 chunkOffset = offset % kQNBlockSize;
	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/bput/%@/%u", uphost, context, (unsigned int)chunkOffset];

	// Todo: check crc
	[self post:url withData:data withCompleteBlock:complete withProgressBlock:progressBlock];
}

- (BOOL)isCancelled {
	return self.option && [self.option isCancelled];
}

- (void)makeFile:(NSString *)uphost
        complete:(QNCompleteBlock)complete {
	NSString *mime;

	if (!self.option || !self.option.mimeType) {
		mime = @"";
	}
	else {
		mime = [[NSString alloc] initWithFormat:@"/mimetype/%@", [QNUrlSafeBase64 encodeString:self.option.mimeType]];
	}

	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/mkfile/%u%@", uphost, (unsigned int)self.size, mime];

	if (self.key != nil) {
		NSString *keyStr = [[NSString alloc] initWithFormat:@"/key/%@", [QNUrlSafeBase64 encodeString:self.key]];
		url = [NSString stringWithFormat:@"%@%@", url, keyStr];
	}

	if (self.option && self.option.params) {
		NSEnumerator *e = [self.option.params keyEnumerator];
		for (id key = [e nextObject]; key != nil; key = [e nextObject]) {
			url = [NSString stringWithFormat:@"%@/%@/%@", url, key, [QNUrlSafeBase64 encodeString:(self.option.params)[key]]];
		}
	}

	NSMutableData *postData = [NSMutableData data];
	NSString *bodyStr = [self.contexts componentsJoinedByString:@","];
	[postData appendData:[bodyStr dataUsingEncoding:NSUTF8StringEncoding]];
	[self post:url withData:postData withCompleteBlock:complete withProgressBlock:nil];
}

- (void)         post:(NSString *)url
             withData:(NSData *)data
    withCompleteBlock:(QNCompleteBlock)completeBlock
    withProgressBlock:(QNInternalProgressBlock)progressBlock {
	NSDictionary *headers = @{ @"Authorization":self.token, @"Content-Type":@"application/octet-stream" };
	[_httpManager post:url withData:data withParams:nil withHeaders:headers withCompleteBlock:completeBlock withProgressBlock:progressBlock withCancelBlock:nil];
}

- (void)run {
	@autoreleasepool {
		UInt32 offset = [self recoveryFromRecord];
		[self nextTask:offset];
	}
}

@end
