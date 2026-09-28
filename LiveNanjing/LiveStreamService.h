#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LNLiveStream : NSObject

@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, strong, readonly) NSURL *URL;
@property(nonatomic, readonly) double latitude;
@property(nonatomic, readonly) double longitude;

- (instancetype)initWithName:(NSString *)name
                          URL:(NSURL *)URL
                     latitude:(double)latitude
                    longitude:(double)longitude;

@end

typedef void (^LNLiveStreamCompletion)(LNLiveStream * _Nullable stream, NSError * _Nullable error);

@interface LiveStreamService : NSObject

- (void)fetchRandomStreamExcludingName:(NSString * _Nullable)excludedName
                                   URL:(NSURL * _Nullable)excludedURL
                            completion:(LNLiveStreamCompletion)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
