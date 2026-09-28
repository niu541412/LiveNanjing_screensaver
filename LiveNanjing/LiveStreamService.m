#import "LiveStreamService.h"

#import <CommonCrypto/CommonCryptor.h>
#import <Security/Security.h>

static NSString *const LNBaseURL = @"https://znwg.njdashuju.cn:32376";
static NSString *const LNPageURL = @"https://znwg.njdashuju.cn:32376/othersvideo-h5/";
static NSString *const LNErrorDomain = @"com.jomic.LiveNanjing.StreamService";

@implementation LNLiveStream

- (instancetype)initWithName:(NSString *)name
                          URL:(NSURL *)URL
                     latitude:(double)latitude
                    longitude:(double)longitude
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _URL = URL;
        _latitude = latitude;
        _longitude = longitude;
    }
    return self;
}

@end

@interface LiveStreamService ()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong, nullable) NSUUID *requestID;
@end

@implementation LiveStreamService

- (void)cancel
{
    self.requestID = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
}

- (NSError *)errorWithDescription:(NSString *)description
{
    return [NSError errorWithDomain:LNErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (NSURLSession *)newSession
{
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 8.0;
    configuration.timeoutIntervalForResource = 15.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0",
        @"Accept": @"*/*",
        @"Referer": LNPageURL,
    };
    return [NSURLSession sessionWithConfiguration:configuration];
}

- (BOOL)isCurrentRequest:(NSUUID *)requestID
{
    return [self.requestID isEqual:requestID];
}

- (void)finishRequest:(NSUUID *)requestID
                stream:(LNLiveStream *)stream
                 error:(NSError *)error
            completion:(LNLiveStreamCompletion)completion
{
    if (![self isCurrentRequest:requestID]) return;
    self.requestID = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(stream, error);
    });
}

- (void)getURL:(NSURL *)URL
      requestID:(NSUUID *)requestID
     completion:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:12.0];
    [request setValue:LNPageURL forHTTPHeaderField:@"Referer"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (![self isCurrentRequest:requestID]) return;
        completion(data, response, error);
    }];
    [task resume];
}

- (nullable NSString *)requestToken
{
    uint8_t saltBytes[8];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(saltBytes), saltBytes) != errSecSuccess) return nil;

    NSMutableString *salt = [NSMutableString stringWithCapacity:16];
    for (NSUInteger i = 0; i < sizeof(saltBytes); i++) [salt appendFormat:@"%02x", saltBytes[i]];

    NSDictionary *payload = @{
        @"salt": salt,
        @"timestamp": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
    };
    NSData *plain = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSData *key = [@"1234568890ABCDEF1234567890ABCDEf" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *iv = [@"0123455789ABCDEF" dataUsingEncoding:NSUTF8StringEncoding];
    if (!plain || key.length != kCCKeySizeAES256 || iv.length != kCCBlockSizeAES128) return nil;

    size_t capacity = plain.length + kCCBlockSizeAES128;
    void *buffer = calloc(1, capacity);
    size_t encryptedLength = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding,
                                     key.bytes,
                                     key.length,
                                     iv.bytes,
                                     plain.bytes,
                                     plain.length,
                                     buffer,
                                     capacity,
                                     &encryptedLength);
    if (status != kCCSuccess) {
        free(buffer);
        return nil;
    }

    const uint8_t *bytes = buffer;
    NSMutableString *hex = [NSMutableString stringWithCapacity:encryptedLength * 2];
    for (NSUInteger i = 0; i < encryptedLength; i++) [hex appendFormat:@"%02X", bytes[i]];
    free(buffer);
    return hex;
}

- (void)postPath:(NSString *)path
             body:(nullable NSDictionary *)body
        requestID:(NSUUID *)requestID
       completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion
{
    NSString *token = [self requestToken];
    if (!token) {
        completion(nil, [self errorWithDescription:@"无法生成请求令牌"]);
        return;
    }
    NSString *URLString = [NSString stringWithFormat:@"%@%@?t=%@", LNBaseURL, path, token];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:URLString]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:8.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : NSData.data;
    [request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
    [request setValue:LNBaseURL forHTTPHeaderField:@"Origin"];
    [request setValue:LNPageURL forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (![self isCurrentRequest:requestID]) return;
        if (error) {
            completion(nil, error);
            return;
        }
        NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
        if (HTTPResponse.statusCode < 200 || HTTPResponse.statusCode >= 300 || !data.length) {
            completion(nil, [self errorWithDescription:@"直播接口返回异常"]);
            return;
        }
        NSDictionary *outer = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSString *retData = [outer[@"retData"] isKindOfClass:NSString.class] ? outer[@"retData"] : nil;
        NSDictionary *inner = retData ? [NSJSONSerialization JSONObjectWithData:[retData dataUsingEncoding:NSUTF8StringEncoding]
                                                                          options:0
                                                                            error:&error] : nil;
        completion(inner, error ?: (inner ? nil : [self errorWithDescription:@"无法解析直播接口"]));
    }];
    [task resume];
}

- (NSArray<NSDictionary *> *)channelsFromJavaScript:(NSString *)javaScript
{
    NSRegularExpression *channelPattern = [NSRegularExpression regularExpressionWithPattern:@"\\{[^{}]*showName:\"[^\"]+\"[^{}]*newChanel:[0-9]+[^{}]*chanel:\"[^\"]+\"[^{}]*\\}"
                                                                                       options:0
                                                                                         error:nil];
    NSRegularExpression *fieldPattern = [NSRegularExpression regularExpressionWithPattern:@"(\\w+):(?:\"([^\"]*)\"|([0-9.]+))"
                                                                                    options:0
                                                                                      error:nil];
    NSMutableArray *channels = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSRange wholeRange = NSMakeRange(0, javaScript.length);
    for (NSTextCheckingResult *match in [channelPattern matchesInString:javaScript options:0 range:wholeRange]) {
        NSString *object = [javaScript substringWithRange:match.range];
        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (NSTextCheckingResult *field in [fieldPattern matchesInString:object options:0 range:NSMakeRange(0, object.length)]) {
            NSString *key = [object substringWithRange:[field rangeAtIndex:1]];
            NSRange quotedRange = [field rangeAtIndex:2];
            NSRange numberRange = [field rangeAtIndex:3];
            NSRange valueRange = quotedRange.location != NSNotFound ? quotedRange : numberRange;
            if (valueRange.location != NSNotFound) fields[key] = [object substringWithRange:valueRange];
        }
        NSString *name = fields[@"showName"];
        NSString *channelID = fields[@"newChanel"];
        if (!name.length || !channelID.length || [seen containsObject:channelID]) continue;
        [seen addObject:channelID];
        [channels addObject:@{
            @"name": name,
            @"channelID": channelID,
            @"latitude": @([fields[@"lat"] doubleValue]),
            @"longitude": @([fields[@"lng"] doubleValue]),
        }];
    }
    return channels;
}

- (NSArray<NSDictionary *> *)shuffledChannels:(NSArray<NSDictionary *> *)channels
{
    NSMutableArray *result = [channels mutableCopy];
    for (NSUInteger i = result.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [result exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
    return result;
}

- (NSString *)proxiedURLString:(NSString *)URLString
{
    NSDictionary *replacements = @{
        @"http://49.77.124.93:10010": [LNBaseURL stringByAppendingString:@"/zbjn1"],
        @"http://49.77.124.93:10011": [LNBaseURL stringByAppendingString:@"/zbjn2"],
        @"http://49.77.124.93:10012": [LNBaseURL stringByAppendingString:@"/zbjn3"],
        @"http://49.77.124.93:10013": [LNBaseURL stringByAppendingString:@"/zbjn4"],
        @"http://49.77.124.93:10015": [LNBaseURL stringByAppendingString:@"/zbjn5"],
        @"http://49.77.124.93:554": [LNBaseURL stringByAppendingString:@"/zbjn6"],
        @"http://49.77.124.93:10016": [LNBaseURL stringByAppendingString:@"/zbjn7"],
        @"http://49.77.124.93:10017": [LNBaseURL stringByAppendingString:@"/zbjn8"],
    };
    for (NSString *prefix in replacements) {
        if ([URLString hasPrefix:prefix]) {
            return [URLString stringByReplacingCharactersInRange:NSMakeRange(0, prefix.length)
                                                        withString:replacements[prefix]];
        }
    }
    return URLString;
}

- (void)discoverChannelsWithRequestID:(NSUUID *)requestID
                               attempt:(NSUInteger)attempt
                            completion:(void (^)(NSArray<NSDictionary *> * _Nullable, NSError * _Nullable))completion
{
    [self getURL:[NSURL URLWithString:LNPageURL] requestID:requestID completion:^(NSData *pageData, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *page = pageData.length ? [[NSString alloc] initWithData:pageData encoding:NSUTF8StringEncoding] : nil;
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"<script[^>]+src=(?:\\\"([^\\\"]*static/js/app\\.[^\\\"]+\\.js)\\\"|'([^']*static/js/app\\.[^']+\\.js)'|([^>\\s]*static/js/app\\.[^>\\s]+\\.js))" options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *match = page ? [pattern firstMatchInString:page options:0 range:NSMakeRange(0, page.length)] : nil;
        NSString *source = nil;
        for (NSUInteger i = 1; match && i <= 3; i++) {
            NSRange range = [match rangeAtIndex:i];
            if (range.location != NSNotFound) { source = [page substringWithRange:range]; break; }
        }
        if (error || !source.length) {
            if (attempt < 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    if ([self isCurrentRequest:requestID]) [self discoverChannelsWithRequestID:requestID attempt:attempt + 1 completion:completion];
                });
            } else {
                completion(nil, error ?: [self errorWithDescription:@"无法发现 Live南京 数据接口"]);
            }
            return;
        }

        NSURL *appURL = [NSURL URLWithString:source relativeToURL:[NSURL URLWithString:LNPageURL]].absoluteURL;
        [self getURL:appURL requestID:requestID completion:^(NSData *appData, NSURLResponse *appResponse, NSError *appError) {
            (void)appResponse;
            NSString *javaScript = appData.length ? [[NSString alloc] initWithData:appData encoding:NSUTF8StringEncoding] : nil;
            NSArray *channels = javaScript ? [self shuffledChannels:[self channelsFromJavaScript:javaScript]] : @[];
            if (appError || !channels.count) {
                if (attempt < 2) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        if ([self isCurrentRequest:requestID]) [self discoverChannelsWithRequestID:requestID attempt:attempt + 1 completion:completion];
                    });
                } else {
                    completion(nil, appError ?: [self errorWithDescription:@"没有发现 Live南京 频道"]);
                }
                return;
            }
            completion(channels, nil);
        }];
    }];
}

- (void)preflightChannel:(NSDictionary *)channel
                      URL:(NSURL *)URL
                requestID:(NSUUID *)requestID
               completion:(void (^)(LNLiveStream * _Nullable))completion
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:7.0];
    [request setValue:@"application/vnd.apple.mpegurl, application/x-mpegURL, */*" forHTTPHeaderField:@"Accept"];
    [request setValue:LNPageURL forHTTPHeaderField:@"Referer"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (![self isCurrentRequest:requestID]) return;
        NSHTTPURLResponse *HTTPResponse = (NSHTTPURLResponse *)response;
        NSString *manifest = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        BOOL usable = !error && manifest.length && HTTPResponse.statusCode >= 200 && HTTPResponse.statusCode < 300 &&
                      [manifest rangeOfString:@"#EXTM3U"].location != NSNotFound;
        completion(usable ? [[LNLiveStream alloc] initWithName:channel[@"name"]
                                                            URL:URL
                                                       latitude:[channel[@"latitude"] doubleValue]
                                                      longitude:[channel[@"longitude"] doubleValue]] : nil);
    }];
    [task resume];
}

- (void)tryChannels:(NSArray<NSDictionary *> *)channels
               index:(NSUInteger)index
               token:(NSString *)OAuthToken
        excludedName:(NSString *)excludedName
         excludedURL:(NSURL *)excludedURL
           requestID:(NSUUID *)requestID
          completion:(LNLiveStreamCompletion)completion
{
    if (index >= channels.count) {
        [self finishRequest:requestID stream:nil error:[self errorWithDescription:@"没有找到可播放的直播流"] completion:completion];
        return;
    }
    NSDictionary *channel = channels[index];
    if (excludedName.length && [channel[@"name"] isEqualToString:excludedName]) {
        [self tryChannels:channels index:index + 1 token:OAuthToken excludedName:excludedName excludedURL:excludedURL requestID:requestID completion:completion];
        return;
    }
    NSDictionary *body = @{
        @"channelID": @([channel[@"channelID"] integerValue]),
        @"authorization": [@"Bearer " stringByAppendingString:OAuthToken],
    };
    [self postPath:@"/cloud/videoapi/getVideoscheduleHls" body:body requestID:requestID completion:^(NSDictionary *inner, NSError *error) {
        (void)error;
        NSString *rawURL = [inner[@"data"] isKindOfClass:NSString.class] && [inner[@"code"] integerValue] == 200 ? inner[@"data"] : nil;
        NSString *URLString = rawURL.length ? [self proxiedURLString:rawURL] : nil;
        NSURL *URL = URLString.length ? [NSURL URLWithString:URLString] : nil;
        if (!URL || ![URL.host containsString:@"znwg.njdashuju.cn"] || [URL isEqual:excludedURL]) {
            [self tryChannels:channels index:index + 1 token:OAuthToken excludedName:excludedName excludedURL:excludedURL requestID:requestID completion:completion];
            return;
        }
        [self preflightChannel:channel URL:URL requestID:requestID completion:^(LNLiveStream *stream) {
            if (stream) {
                [self finishRequest:requestID stream:stream error:nil completion:completion];
            } else {
                [self tryChannels:channels index:index + 1 token:OAuthToken excludedName:excludedName excludedURL:excludedURL requestID:requestID completion:completion];
            }
        }];
    }];
}

- (void)fetchRandomStreamExcludingName:(NSString *)excludedName
                                   URL:(NSURL *)excludedURL
                            completion:(LNLiveStreamCompletion)completion
{
    [self cancel];
    self.session = [self newSession];
    NSUUID *requestID = NSUUID.UUID;
    self.requestID = requestID;

    [self discoverChannelsWithRequestID:requestID attempt:0 completion:^(NSArray<NSDictionary *> *channels, NSError *error) {
        if (error || !channels.count) {
            [self finishRequest:requestID stream:nil error:error ?: [self errorWithDescription:@"没有发现 Live南京 频道"] completion:completion];
            return;
        }
        [self postPath:@"/cloud/videoapi/getOauthToken" body:nil requestID:requestID completion:^(NSDictionary *inner, NSError *tokenError) {
            NSString *OAuthToken = [inner[@"data"] isKindOfClass:NSString.class] && [inner[@"code"] integerValue] == 200 ? inner[@"data"] : nil;
            if (tokenError || !OAuthToken.length) {
                [self finishRequest:requestID stream:nil error:tokenError ?: [self errorWithDescription:@"无法获取 Live南京 授权"] completion:completion];
                return;
            }
            [self tryChannels:channels index:0 token:OAuthToken excludedName:excludedName excludedURL:excludedURL requestID:requestID completion:completion];
        }];
    }];
}

@end
